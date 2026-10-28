"""`refresh` checks the phone is reachable before any Apple call.

An app whose phone does not answer costs one connection attempt, not a trip through
Apple's servers. With ``--unattended`` (the hourly background run) the app is deferred,
not failed, while it still has a day or more left.
"""

from __future__ import annotations

import datetime
import json
import time

import pytest

from ipaside_engine import __main__ as cli
from ipaside_engine import device, lockdown, paths, provision, refresh, sideload
from ipaside_engine.errors import EngineError

UDID = "935cbbb9b82d25d15566e5939bcea5677b1c44ae"
OTHER_UDID = "00008110-000A1B2C3D4E5F60"
GONE = "Could not reach device " + UDID + ": nope. Check it is plugged in, unlocked, and trusted."


def _rec(bundle_id, days, udid=UDID, cert_serial="S1"):
    expires = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)
    # source_ipa is any file that exists (this one): a refresh re-signs from it, and only
    # checks it is there before handing it to the (stubbed) signing step.
    item = {"bundle_id": bundle_id, "team_id": "TEAM000001", "cert_serial": cert_serial,
            "expires_at": expires.isoformat(), "source_ipa": __file__}
    if udid:
        item["udid"] = udid
    return item


def _seed(*records):
    for item in records:
        refresh.record(item)


@pytest.fixture
def run_refresh(monkeypatch, capsys):
    """Run `refresh --json` through the real ``refresh_record``, stubbing only its leaves.

    The phone probe and the three steps that talk to Apple or sign (the account lookup,
    ``ensure_signing_assets`` and ``run_sideload``) are spies: ``spies["apple"]`` lists
    each one that ran, so "no Apple call" is checked against spies that do fire when the
    phone answers.
    """
    spies: dict[str, list] = {"probed": [], "apple": []}
    reachable: dict[str, bool] = {UDID: False, OTHER_UDID: True}

    async def probe(serial):
        spies["probed"].append(serial)
        if not reachable[serial]:
            raise device.DeviceError(GONE)

    def leaf(name, result=None):
        def spy(*_args, **_kwargs):
            spies["apple"].append(name)
            return result
        return spy

    monkeypatch.setattr(cli.lockdown, "probe", probe)
    monkeypatch.setattr(sideload, "_refresh_account", leaf("account"))
    monkeypatch.setattr(provision, "ensure_signing_assets", leaf("assets"))
    monkeypatch.setattr(sideload, "run_sideload",
                        leaf("sign", {"status": "installed", "expires_at": "x"}))
    monkeypatch.setattr(cli.gsa, "account_for_team", lambda _team: None)

    def go(*argv):
        code = cli.dispatch(cli.build_parser().parse_args(["refresh", "--json", *argv]))
        return code, json.loads(capsys.readouterr().out), spies

    go.reachable = reachable
    return go


def _team_certificate(monkeypatch, serial):
    """Make the team's current certificate ``serial``, as the local cache would say."""
    monkeypatch.setattr(cli.gsa, "account_for_team", lambda _team: "me@example.com")
    monkeypatch.setattr(cli.provision, "cached_serial", lambda _account: serial)


def test_the_flag_is_accepted_and_off_by_default():
    parser = cli.build_parser()
    assert parser.parse_args(["refresh"]).unattended is False
    assert parser.parse_args(["refresh", "--unattended"]).unattended is True


def test_an_unreachable_phone_gets_no_apple_call(run_refresh):
    _seed(_rec("a", 0.5))

    code, summary, spies = run_refresh()

    assert code == cli.EXIT_PARTIAL_FAILURE
    assert spies["apple"] == []
    assert summary["refreshed"] == [
        {"bundle_id": "a", "status": "error", "refresh_mode": None, "error": GONE}
    ]


def test_unattended_defers_an_app_with_a_day_or_more_left(run_refresh):
    _seed(_rec("later", 1.5))

    code, summary, spies = run_refresh("--within", "3", "--unattended")

    assert code == 0, "a deferred app is not a failure"
    assert spies["apple"] == []
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
    assert spies["apple"] == ["account", "sign"], "only the reachable phone's app"
    by_id = {r["bundle_id"]: r["status"] for r in summary["refreshed"]}
    assert by_id == {"gone": "error", "here": "installed", "gone2": "error"}
    assert code == cli.EXIT_PARTIAL_FAILURE


def test_a_reachable_phone_refreshes_as_before(run_refresh):
    run_refresh.reachable[UDID] = True
    _seed(_rec("a", 0.5))

    code, summary, spies = run_refresh("--unattended")

    assert code == 0
    assert spies["apple"] == ["account", "sign"]
    assert summary["refreshed"][0]["status"] == "installed"


def test_a_record_without_a_udid_is_not_probed(run_refresh):
    _seed(_rec("old", 0.5, udid=None))

    code, summary, spies = run_refresh("--unattended")

    assert code == 0
    assert spies["probed"] == []
    assert spies["apple"] == ["account", "sign"]


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
    monkeypatch.setattr(sideload, "_refresh_account", lambda entry: None)
    monkeypatch.setattr(sideload, "run_sideload",
                        lambda source, udid, **kw: seen.append(kw["bundle_id"])
                        or {"status": "installed", "expires_at": "x"})
    monkeypatch.setattr(cli.gsa, "account_for_team", lambda _team: None)
    _seed(_rec("a", 0.5))

    code = cli.dispatch(cli.build_parser().parse_args(["refresh", "--json", "--unattended"]))

    assert code == 0
    assert seen == ["a"]
    assert client.closed


# --------------------------------------------------------------------------- #
# A revoked certificate is never waited for
# --------------------------------------------------------------------------- #
def test_a_stale_record_on_an_unreachable_phone_is_an_error_even_unattended(
    monkeypatch, run_refresh
):
    """Its certificate is gone, so the app does not launch whatever days its profile has."""
    _team_certificate(monkeypatch, "S2")
    _seed(_rec("dead", 0.5, cert_serial="S1"))

    code, summary, spies = run_refresh("--unattended")

    assert code == cli.EXIT_PARTIAL_FAILURE
    assert spies["apple"] == []
    assert summary["refreshed"] == [
        {"bundle_id": "dead", "status": "error", "refresh_mode": None, "error": GONE}
    ]


def test_a_stale_record_with_days_left_is_not_deferred(monkeypatch, run_refresh):
    _team_certificate(monkeypatch, "S2")
    _seed(_rec("dead", 5, cert_serial="S1"))

    code, summary, spies = run_refresh("--all", "--unattended")

    assert code == cli.EXIT_PARTIAL_FAILURE
    assert spies["apple"] == []
    assert summary["refreshed"][0]["status"] == "error"
    assert summary["refreshed"][0]["error"] == GONE


def test_a_stale_record_found_by_the_stale_loop_is_not_deferred(monkeypatch, run_refresh):
    """Not due itself, so only the look for records the current certificate did not sign finds it."""
    _team_certificate(monkeypatch, "S2")
    _seed(_rec("due", 0.5, udid=OTHER_UDID, cert_serial="S2"),
          _rec("dead", 5, cert_serial="S1"))

    code, summary, spies = run_refresh("--unattended")

    assert code == cli.EXIT_PARTIAL_FAILURE
    assert {r["bundle_id"]: r["status"] for r in summary["refreshed"]} == {
        "due": "installed", "dead": "error",
    }
    assert spies["apple"] == ["account", "sign"], "only the reachable phone's app"


def test_a_current_record_with_days_left_is_still_deferred(monkeypatch, run_refresh):
    _team_certificate(monkeypatch, "S1")
    _seed(_rec("later", 1.5, cert_serial="S1"))

    code, summary, _spies = run_refresh("--within", "3", "--unattended")

    assert code == 0
    assert summary["refreshed"][0]["status"] == "deferred"


# --------------------------------------------------------------------------- #
# The unattended run does not wait for another operation
# --------------------------------------------------------------------------- #
@pytest.fixture
def other_operation(monkeypatch):
    """Start another process holding engine.lock, as a GUI sideload would; call it last.

    Records are seeded first because writing one takes the same lock.
    """
    handles = []

    def hold(timeout):
        monkeypatch.setattr(refresh, "LOCK_TIMEOUT_SECONDS", timeout)
        monkeypatch.setattr(refresh, "_LOCK_POLL_SECONDS", 0.05)
        handle = open(paths.data_dir() / refresh.LOCK_FILE, "a+b")
        refresh._try_lock(handle)
        handles.append(handle)

    yield hold
    for handle in handles:
        refresh._unlock(handle)


def test_unattended_gives_up_at_once_when_another_operation_runs(other_operation, run_refresh):
    _seed(_rec("a", 0.5))
    other_operation(30.0)
    started = time.monotonic()

    code, summary, spies = run_refresh("--unattended")

    assert time.monotonic() - started < 5, "it must not wait out the 30 s lock timeout"
    assert code == 0, "the hourly run just tries again next hour"
    assert summary["refreshed"] == [] and summary["count"] == 0
    assert "Another EZSide operation is running" in summary["message"]
    assert spies["probed"] == [] and spies["apple"] == []


def test_manual_refresh_still_waits_then_fails_when_another_operation_runs(
    other_operation, run_refresh
):
    _seed(_rec("a", 0.5))
    other_operation(0.3)

    with pytest.raises(refresh.RegistryError, match="Another EZSide operation is running"):
        run_refresh()
