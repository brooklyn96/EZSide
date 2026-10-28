"""`refresh` checks the phone is reachable before any Apple call.

An app whose phone does not answer costs one connection attempt, not a trip through
Apple's servers. With ``--unattended`` (the hourly background run) the app is deferred,
not failed, while it still has a day or more left.
"""

from __future__ import annotations

import datetime
import json

import pytest

from ipaside_engine import __main__ as cli
from ipaside_engine import device, lockdown, provision, refresh, sideload
from ipaside_engine.errors import EngineError

UDID = "935cbbb9b82d25d15566e5939bcea5677b1c44ae"
OTHER_UDID = "00008110-000A1B2C3D4E5F60"
GONE = "Could not reach device " + UDID + ": nope. Check it is plugged in, unlocked, and trusted."


def _rec(bundle_id, days, udid=UDID):
    expires = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)
    item = {"bundle_id": bundle_id, "team_id": "TEAM000001", "cert_serial": "S1",
            "expires_at": expires.isoformat()}
    if udid:
        item["udid"] = udid
    return item


def _seed(*records):
    for item in records:
        refresh.record(item)


@pytest.fixture
def run_refresh(monkeypatch, capsys):
    """Run `refresh --json` with spies on every step that talks to Apple or signs."""
    spies: dict[str, list] = {"probed": [], "refreshed": [], "apple": []}
    reachable: dict[str, bool] = {UDID: False, OTHER_UDID: True}

    async def probe(serial):
        spies["probed"].append(serial)
        if not reachable[serial]:
            raise device.DeviceError(GONE)

    def refresh_record(entry, on_progress=None, **kwargs):
        spies["refreshed"].append(entry["bundle_id"])
        return {"expires_at": "x", "refresh_mode": "resign"}

    def apple(*_args, **_kwargs):
        spies["apple"].append(1)
        raise AssertionError("an Apple call was made for an unreachable phone")

    monkeypatch.setattr(cli.lockdown, "probe", probe)
    monkeypatch.setattr(cli.sideload, "refresh_record", refresh_record)
    monkeypatch.setattr(sideload, "_refresh_account", apple)
    monkeypatch.setattr(provision, "ensure_signing_assets", apple)
    monkeypatch.setattr(cli.gsa, "account_for_team", lambda _team: None)

    def go(*argv):
        code = cli.dispatch(cli.build_parser().parse_args(["refresh", "--json", *argv]))
        return code, json.loads(capsys.readouterr().out), spies

    go.reachable = reachable
    return go


def test_the_flag_is_accepted_and_off_by_default():
    parser = cli.build_parser()
    assert parser.parse_args(["refresh"]).unattended is False
    assert parser.parse_args(["refresh", "--unattended"]).unattended is True


def test_an_unreachable_phone_gets_no_apple_call(run_refresh):
    _seed(_rec("a", 0.5))

    code, summary, spies = run_refresh()

    assert code == cli.EXIT_PARTIAL_FAILURE
    assert spies["refreshed"] == [] and spies["apple"] == []
    assert summary["refreshed"] == [
        {"bundle_id": "a", "status": "error", "refresh_mode": None, "error": GONE}
    ]


def test_unattended_defers_an_app_with_a_day_or_more_left(run_refresh):
    _seed(_rec("later", 1.5))

    code, summary, spies = run_refresh("--within", "3", "--unattended")

    assert code == 0, "a deferred app is not a failure"
    assert spies["refreshed"] == []
    assert summary["refreshed"] == [
        {"bundle_id": "later", "status": "deferred", "refresh_mode": None, "error": GONE}
    ]


def test_unattended_reports_an_app_with_less_than_a_day_left(run_refresh):
    _seed(_rec("close", 0.5))

    code, summary, _spies = run_refresh("--unattended")

    assert code == cli.EXIT_PARTIAL_FAILURE
    assert summary["refreshed"][0]["status"] == "error"
    assert summary["refreshed"][0]["error"] == GONE


def test_an_unknown_expiry_is_treated_as_close(monkeypatch, run_refresh):
    entry = {**_rec("odd", 5), "days_left": None}
    monkeypatch.setattr(cli.refresh, "records", lambda: [entry])

    code, summary, _spies = run_refresh("--all", "--unattended")

    assert code == cli.EXIT_PARTIAL_FAILURE
    assert summary["refreshed"][0]["status"] == "error"


def test_manual_refresh_fails_an_unreachable_phone_even_with_time_left(run_refresh):
    _seed(_rec("later", 1.5))

    code, summary, _spies = run_refresh("--within", "3")

    assert code == cli.EXIT_PARTIAL_FAILURE
    assert summary["refreshed"][0]["status"] == "error"
    assert summary["refreshed"][0]["error"] == GONE


def test_a_deferred_app_does_not_hide_a_failure_beside_it(run_refresh):
    _seed(_rec("later", 1.5), _rec("close", 0.5))

    code, summary, _spies = run_refresh("--within", "3", "--unattended")

    assert code == cli.EXIT_PARTIAL_FAILURE
    assert {r["bundle_id"]: r["status"] for r in summary["refreshed"]} == {
        "later": "deferred", "close": "error",
    }


def test_two_apps_on_one_phone_cost_one_probe(run_refresh):
    _seed(_rec("a", 0.5), _rec("b", 0.6))

    _code, summary, spies = run_refresh()

    assert spies["probed"] == [UDID]
    assert [r["status"] for r in summary["refreshed"]] == ["error", "error"]


def test_each_phone_is_probed_once_and_a_reachable_one_refreshes_as_before(run_refresh):
    _seed(_rec("gone", 0.5), _rec("here", 0.6, udid=OTHER_UDID), _rec("gone2", 0.7))

    code, summary, spies = run_refresh()

    assert sorted(spies["probed"]) == sorted([UDID, OTHER_UDID])
    assert spies["refreshed"] == ["here"]
    by_id = {r["bundle_id"]: r["status"] for r in summary["refreshed"]}
    assert by_id == {"gone": "error", "here": "installed", "gone2": "error"}
    assert code == cli.EXIT_PARTIAL_FAILURE


def test_a_reachable_phone_refreshes_as_before(run_refresh):
    run_refresh.reachable[UDID] = True
    _seed(_rec("a", 0.5))

    code, summary, spies = run_refresh("--unattended")

    assert code == 0
    assert spies["refreshed"] == ["a"]
    assert summary["refreshed"][0]["status"] == "installed"


def test_a_record_without_a_udid_is_not_probed(run_refresh):
    _seed(_rec("old", 0.5, udid=None))

    code, summary, spies = run_refresh("--unattended")

    assert code == 0
    assert spies["probed"] == []
    assert spies["refreshed"] == ["old"]


def test_a_setting_the_engine_cannot_read_is_an_error_not_a_deferral(monkeypatch, run_refresh):
    async def bad_setting(_serial):
        raise EngineError("IPASIDE_CONNECTION='x' is not a transport; use usb, wifi, or auto.")

    monkeypatch.setattr(cli.lockdown, "probe", bad_setting)
    _seed(_rec("later", 1.5))

    code, summary, _spies = run_refresh("--within", "3", "--unattended")

    assert code == cli.EXIT_PARTIAL_FAILURE
    assert summary["refreshed"][0]["status"] == "error"


# --------------------------------------------------------------------------- #
# The probe itself
# --------------------------------------------------------------------------- #
class _Client:
    closed = False

    async def close(self):
        self.closed = True


def _usbmux(monkeypatch, answers):
    """Make ``create_using_usbmux`` answer per transport: a client, or an exception."""
    import pymobiledevice3.lockdown as pml

    attempted: list[str | None] = []

    def connect(serial=None, connection_type=None, **kwargs):
        attempted.append(connection_type)
        answer = answers[connection_type]
        if isinstance(answer, Exception):
            raise answer
        return answer

    monkeypatch.setattr(pml, "create_using_usbmux", connect)
    return attempted


def test_a_phone_reachable_only_on_any_transport_counts_as_reachable(monkeypatch):
    monkeypatch.delenv(lockdown.CONNECTION_ENV, raising=False)
    client = _Client()
    attempted = _usbmux(monkeypatch, {"USB": OSError("no cable"), None: client})

    cli.run(lockdown.probe(UDID))  # no exception

    assert attempted == ["USB", None], "the normal policy: USB first, then any transport"
    assert client.closed, "the probe must not leave the connection open"


def test_the_probe_reports_a_phone_that_answers_on_no_transport(monkeypatch):
    monkeypatch.delenv(lockdown.CONNECTION_ENV, raising=False)
    _usbmux(monkeypatch, {"USB": OSError("no cable"), None: OSError("asleep")})

    with pytest.raises(device.DeviceError, match="asleep"):
        cli.run(lockdown.probe(UDID))


def test_a_wifi_only_phone_passes_end_to_end(monkeypatch, capsys):
    """The whole path with only usbmux faked: USB fails, any-transport answers, refresh goes on."""
    monkeypatch.delenv(lockdown.CONNECTION_ENV, raising=False)
    client = _Client()
    _usbmux(monkeypatch, {"USB": OSError("no cable"), None: client})
    seen = []
    monkeypatch.setattr(cli.sideload, "refresh_record",
                        lambda entry, on_progress=None, **kw: seen.append(entry["bundle_id"])
                        or {"expires_at": "x", "refresh_mode": "resign"})
    monkeypatch.setattr(cli.gsa, "account_for_team", lambda _team: None)
    _seed(_rec("a", 0.5))

    code = cli.dispatch(cli.build_parser().parse_args(["refresh", "--json", "--unattended"]))

    assert code == 0
    assert seen == ["a"]
    assert client.closed
