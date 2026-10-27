"""Refreshing without the user's IPA, AltStore-style.

When the app is still on the phone and still signed with the current certificate, a
refresh installs only a new provisioning profile. Anything else re-signs from EZSide's
own copy of the IPA. A certificate re-issue revokes every app the old one signed, so the
whole team is re-signed in the same run.
"""

from __future__ import annotations

import datetime
import io
import json
import plistlib

import pytest

from ipaside_engine import __main__ as cli
from ipaside_engine import apps, ipa as ipa_module, refresh, sideload

BUNDLE = "com.example.app.TEAM000001"
TEAM = "TEAM000001"
EXPIRY = datetime.datetime(2031, 1, 2, 3, 4, 5)


def _profile(uuid: str = "NEW-UUID", team: str = TEAM, app: str = BUNDLE) -> bytes:
    """A .mobileprovision as far as anything here reads it: a plist inside CMS bytes."""
    plist = plistlib.dumps({
        "UUID": uuid,
        "TeamIdentifier": [team],
        "Entitlements": {"application-identifier": f"{team}.{app}"},
        "ExpirationDate": EXPIRY,
    })
    return b"\x30\x82 cms-prefix " + plist + b"\x00signature"


@pytest.fixture
def entry(tmp_path):
    cached = tmp_path / "cache" / "source.ipa"
    cached.parent.mkdir()
    cached.write_bytes(b"PK cached")
    source = tmp_path / "Example.ipa"
    source.write_bytes(b"PK source")
    return {
        "bundle_id": BUNDLE,
        "name": "Example",
        "udid": "UDID",
        "team_id": None,  # no account switching in these tests
        "source_ipa": str(source),
        "cached_ipa": str(cached),
        "cert_serial": "SERIAL1",
        "expires_at": "2030-01-01T00:00:00+00:00",
        "options": {},
        "days_left": 0.5,
        "expired": False,
    }


@pytest.fixture
def device(monkeypatch, tmp_path):
    """Apple, the phone and the full re-sign, all faked and observable."""
    state = {
        "installed": {BUNDLE: {}},
        "serial": "SERIAL1",
        "profile_error": None,
        "profiles": [],
        "provisioned": 0,
        "resigned": [],
    }
    profile_path = tmp_path / "profile.mobileprovision"
    profile_path.write_bytes(_profile())

    def list_installed(_udid):
        return state["installed"]

    def ensure_signing_assets(*_a, **_k):
        state["provisioned"] += 1
        return {"certificate_serial": state["serial"], "profile_path": str(profile_path)}

    def install_profile(data, udid):
        if state["profile_error"]:
            raise state["profile_error"]
        state["profiles"].append((data, udid))
        return "NEW-UUID"

    def run_sideload(ipa_path, udid, **kwargs):
        state["resigned"].append({"ipa": ipa_path, "udid": udid, **kwargs})
        return {"status": "installed", "expires_at": "2031-01-01T00:00:00+00:00",
                "cert_serial": state["serial"]}

    monkeypatch.setattr(sideload.apps, "list_installed", list_installed)
    monkeypatch.setattr(sideload.provision, "ensure_signing_assets", ensure_signing_assets)
    monkeypatch.setattr(sideload.apps, "install_profile", install_profile)
    monkeypatch.setattr(sideload, "run_sideload", run_sideload)
    return state


# --------------------------------------------------------------------------- #
# Which path a refresh takes
# --------------------------------------------------------------------------- #
def test_same_certificate_and_app_installed_installs_only_a_profile(entry, device):
    result = sideload.refresh_record(entry)

    assert result["refresh_mode"] == "profile"
    assert device["resigned"] == [], "the app itself is not touched"
    assert device["profiles"] == [(_profile(), "UDID")]
    stored = refresh.get(BUNDLE)
    assert stored["expires_at"].startswith("2031-01-02"), "expiry comes from the new profile"
    assert "days_left" not in stored and "expired" not in stored, "annotations are not stored"


def test_a_different_certificate_resigns(entry, device):
    device["serial"] = "SERIAL2"

    result = sideload.refresh_record(entry)

    assert result["refresh_mode"] == "resign"
    assert device["profiles"] == []
    assert len(device["resigned"]) == 1


def test_an_app_no_longer_on_the_device_resigns(entry, device):
    device["installed"] = {}

    result = sideload.refresh_record(entry)

    assert result["refresh_mode"] == "resign"
    assert device["provisioned"] == 0, "no Apple round trip for a profile it cannot use"


def test_a_profile_the_device_refuses_falls_back_to_resign(entry, device):
    device["profile_error"] = apps.ProfileInstallError("device said no")

    result = sideload.refresh_record(entry)

    assert result["refresh_mode"] == "resign"
    assert len(device["resigned"]) == 1


def test_resign_flag_forces_the_full_path(entry, device):
    device["installed"] = None  # would blow up if it were consulted

    result = sideload.refresh_record(entry, resign=True)

    assert result["refresh_mode"] == "resign"
    assert device["profiles"] == []


@pytest.mark.parametrize("missing", ["cert_serial", "cached_ipa"])
def test_an_older_record_resigns(entry, device, missing):
    entry[missing] = None

    assert sideload.refresh_record(entry)["refresh_mode"] == "resign"
    assert device["profiles"] == []


def test_the_cached_copy_is_signed_when_the_users_file_is_gone(entry, device, tmp_path):
    (tmp_path / "Example.ipa").unlink()
    device["serial"] = "SERIAL2"

    sideload.refresh_record(entry)

    call = device["resigned"][0]
    assert call["ipa"] == entry["cached_ipa"]
    assert call["source_ipa"] == entry["source_ipa"], "the user's path stays recorded"


def test_the_users_file_is_used_when_the_cached_copy_is_gone(entry, device, tmp_path):
    (tmp_path / "cache" / "source.ipa").unlink()
    device["serial"] = "SERIAL2"

    sideload.refresh_record(entry)

    assert device["resigned"][0]["ipa"] == entry["source_ipa"]


def test_a_profile_only_refresh_needs_no_ipa(entry, device, tmp_path):
    (tmp_path / "cache" / "source.ipa").unlink()
    (tmp_path / "Example.ipa").unlink()

    assert sideload.refresh_record(entry)["refresh_mode"] == "profile"


def test_no_ipa_anywhere_is_a_sentence(entry, device, tmp_path):
    (tmp_path / "cache" / "source.ipa").unlink()
    (tmp_path / "Example.ipa").unlink()
    device["serial"] = "SERIAL2"  # only a re-sign can refresh it

    with pytest.raises(ipa_module.IpaError, match="moved, renamed or deleted"):
        sideload.refresh_record(entry)
    assert device["resigned"] == [] and device["profiles"] == []


def test_a_refresh_that_can_only_resign_fails_on_a_missing_ipa_before_any_round_trip(
    entry, device, tmp_path, monkeypatch
):
    (tmp_path / "cache" / "source.ipa").unlink()
    (tmp_path / "Example.ipa").unlink()
    asked: list[dict] = []
    monkeypatch.setattr(sideload, "_refresh_account", lambda e: asked.append(e))

    with pytest.raises(ipa_module.IpaError):
        sideload.refresh_record(entry, resign=True)
    assert asked == [], "the account (an Apple round trip) is not looked up"


@pytest.mark.parametrize("cause, reason", [
    ("missing", "not on the device"),
    ("serial", "certificate has changed"),
    ("refused", "refused the profile (device said no)"),
])
def test_falling_back_to_resign_says_why(entry, device, cause, reason):
    if cause == "missing":
        device["installed"] = {}
    elif cause == "serial":
        device["serial"] = "SERIAL2"
    else:
        device["profile_error"] = apps.ProfileInstallError("device said no")
    lines: list[str] = []

    sideload.refresh_record(entry, on_progress=lambda _phase, _pct, step: lines.append(step))

    said = [line for line in lines if line.startswith("Re-signing the app")]
    assert len(said) == 1 and reason in said[0]


# --------------------------------------------------------------------------- #
# The profile swap on the device (misagent)
# --------------------------------------------------------------------------- #
class _Misagent:
    def __init__(self, installed, lists_new=True):
        self.installed = list(installed)
        self.removed: list[str] = []
        self.lists_new = lists_new
        self.closed = False
        self.events: list[str] = []

    def __call__(self, lockdown):
        return self

    async def copy_all(self):
        from pymobiledevice3.services.misagent import ProvisioningProfile

        return [ProvisioningProfile(p) for p in self.installed]

    async def remove(self, uuid):
        self.removed.append(uuid)
        self.events.append(f"remove {uuid}")
        self.installed = [p for p in self.installed if plistlib.loads(
            p[p.find(b"<?xml"):p.find(b"</plist>") + 8])["UUID"] != uuid]

    async def install(self, stream: io.BytesIO):
        self.events.append("install")
        if self.lists_new:
            self.installed.append(stream.read())

    async def close(self):
        self.closed = True


@pytest.fixture
def misagent(monkeypatch):
    def _make(installed, lists_new=True):
        fake = _Misagent(installed, lists_new)
        monkeypatch.setattr("pymobiledevice3.services.misagent.MisagentService", fake)

        async def create(_serial):
            return object()

        async def close(_client):
            return None

        monkeypatch.setattr(apps.lockdown, "create", create)
        monkeypatch.setattr(apps.lockdown, "close", close)
        return fake

    return _make


def test_old_profiles_for_the_same_app_are_replaced_and_nothing_else(misagent):
    fake = misagent([
        _profile("OLD-SAME-APP"),
        _profile("OTHER-APP", app="com.other.app"),
        _profile("OTHER-TEAM", team="OTHERTEAM1"),
    ])

    assert apps.install_profile(_profile("NEW-UUID"), "UDID") == "NEW-UUID"

    assert fake.removed == ["OLD-SAME-APP"]
    assert fake.closed


def test_a_profile_the_device_does_not_list_afterwards_is_an_error(misagent):
    misagent([], lists_new=False)

    with pytest.raises(apps.ProfileInstallError, match="NEW-UUID"):
        apps.install_profile(_profile("NEW-UUID"), "UDID")


def test_the_new_profile_is_installed_and_listed_before_old_ones_go(misagent):
    fake = misagent([_profile("OLD-SAME-APP")])

    apps.install_profile(_profile("NEW-UUID"), "UDID")

    assert fake.events == ["install", "remove OLD-SAME-APP"]


def test_a_refused_profile_leaves_the_old_one_installed(misagent):
    """Until the new one is listed, the old one is all that keeps the app launching."""
    fake = misagent([_profile("OLD-SAME-APP")], lists_new=False)

    with pytest.raises(apps.ProfileInstallError):
        apps.install_profile(_profile("NEW-UUID"), "UDID")

    assert fake.removed == []
    assert fake.closed


def test_an_old_profile_the_device_will_not_remove_does_not_fail_the_refresh(misagent, capsys):
    """The new profile is already installed and listed; only tidying up failed."""
    fake = misagent([_profile("OLD-ONE"), _profile("OLD-TWO")])

    async def refuse(uuid):
        fake.events.append(f"remove {uuid}")
        raise RuntimeError("device said no")

    fake.remove = refuse

    assert apps.install_profile(_profile("NEW-UUID"), "UDID") == "NEW-UUID"

    assert fake.events == ["install", "remove OLD-ONE", "remove OLD-TWO"], "each one is tried"
    assert fake.closed
    assert "device said no" in capsys.readouterr().err


def test_bytes_that_are_not_a_profile_are_refused_before_touching_the_device(misagent):
    fake = misagent([_profile("OLD-SAME-APP")])

    with pytest.raises(apps.ProfileInstallError):
        apps.install_profile(b"not a profile", "UDID")
    assert fake.removed == []


# --------------------------------------------------------------------------- #
# The refresh command: certificate re-issue, exit codes
# --------------------------------------------------------------------------- #
def _seed(*records):
    for item in records:
        refresh.record(item)


def _rec(bundle_id, team, serial, days):
    expires = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)
    return {"bundle_id": bundle_id, "team_id": team, "cert_serial": serial,
            "expires_at": expires.isoformat()}


@pytest.fixture
def certs(monkeypatch):
    """team id -> the serial in that team's local certificate cache (its account is the team)."""
    held = {TEAM: "SERIAL1"}
    monkeypatch.setattr(cli.gsa, "account_for_team", lambda team_id: team_id)
    monkeypatch.setattr(cli.provision, "cached_serial", lambda account: held.get(account))
    return held


@pytest.fixture
def refresher(monkeypatch, certs):
    """Fake refresh_record: the team's certificate is now SERIAL2 (issued, then cached).

    An app in ``failing`` fails after the new certificate was issued, as an install that
    fails after provisioning does.
    """
    calls: list[str] = []
    failing: set[str] = set()

    def fake(entry, on_progress=None, **kwargs):
        calls.append(entry["bundle_id"])
        certs[entry["team_id"]] = "SERIAL2"
        if entry["bundle_id"] in failing:
            raise sideload.SideloadError("device not reachable")
        stored = {k: v for k, v in entry.items() if k not in ("days_left", "expired")}
        refresh.record({**stored, "cert_serial": "SERIAL2"})
        return {"expires_at": "x", "cert_serial": "SERIAL2", "refresh_mode": "resign"}

    monkeypatch.setattr(cli.sideload, "refresh_record", fake)
    return calls, failing


def _refresh(capsys, *argv):
    code = cli.dispatch(cli.build_parser().parse_args(["refresh", "--json", *argv]))
    return code, json.loads(capsys.readouterr().out)


def test_a_reissued_certificate_resigns_every_app_of_that_team(refresher, capsys):
    calls, _failing = refresher
    _seed(
        _rec("due", TEAM, "SERIAL1", 1),
        _rec("later", TEAM, "SERIAL1", 6),
        _rec("legacy", TEAM, None, 6),
        _rec("other-team", "OTHERTEAM1", "SERIAL1", 6),
    )

    code, summary = _refresh(capsys)

    assert code == 0
    assert calls[0] == "due"
    assert sorted(calls) == ["due", "later", "legacy"], "same team only, each once"
    assert summary["count"] == 3
    assert all(r["refresh_mode"] == "resign" for r in summary["refreshed"])


def test_a_record_signed_by_an_older_certificate_joins_the_run(refresher, certs, capsys):
    """No change in this run, but a record still names a certificate that is gone."""
    calls, _failing = refresher
    certs[TEAM] = "SERIAL2"
    _seed(_rec("due", TEAM, "SERIAL2", 1), _rec("stale", TEAM, "SERIAL1", 6))

    _refresh(capsys)

    assert sorted(calls) == ["due", "stale"]


def test_an_older_record_is_left_alone_when_nothing_changed(refresher, certs, capsys):
    calls, _failing = refresher
    certs[TEAM] = "SERIAL2"
    _seed(_rec("due", TEAM, "SERIAL2", 1), _rec("legacy", TEAM, None, 6))

    _refresh(capsys)

    assert calls == ["due"], "an unknown serial is not evidence of a revoked certificate"


def test_one_unreachable_app_fails_the_run_and_the_rest_continue(refresher, capsys):
    calls, failing = refresher
    failing.add("later")
    _seed(_rec("due", TEAM, "SERIAL1", 1), _rec("later", TEAM, "SERIAL1", 6),
          _rec("third", TEAM, "SERIAL1", 6))

    code, summary = _refresh(capsys)

    assert code == cli.EXIT_PARTIAL_FAILURE == 2
    by_id = {r["bundle_id"]: r for r in summary["refreshed"]}
    assert by_id["later"]["status"] == "error"
    assert "not reachable" in by_id["later"]["error"]
    assert by_id["third"]["status"] == "installed"


def test_all_succeeding_exits_zero(refresher, certs, capsys):
    certs[TEAM] = "SERIAL2"
    _seed(_rec("due", TEAM, "SERIAL2", 1))

    code, summary = _refresh(capsys)

    assert code == 0
    assert summary["refreshed"][0]["status"] == "installed"


def test_the_server_still_reports_a_partial_failure_as_a_result(refresher, monkeypatch):
    _calls, failing = refresher
    failing.add("due")
    _seed(_rec("due", TEAM, "SERIAL1", 1))
    frames: list[dict] = []

    cli._run_request({"id": 7, "args": ["refresh"]}, frames.append)

    result = frames[-1]
    assert result["ok"] is True, "the app reads the per-app statuses"
    assert result["data"]["refreshed"][0]["status"] == "error"


def test_resign_is_passed_through(monkeypatch, capsys):
    seen = {}

    def fake(entry, on_progress=None, **kwargs):
        seen.update(kwargs)
        return {"expires_at": "x"}

    monkeypatch.setattr(cli.sideload, "refresh_record", fake)
    _seed(_rec("due", TEAM, "SERIAL1", 1))

    _refresh(capsys, "--resign")

    assert seen["resign"] is True


def test_a_stale_record_is_resigned_when_nothing_is_due(refresher, certs, capsys):
    """The scheduled run: nothing due, but an app still names a replaced certificate."""
    calls, _failing = refresher
    certs[TEAM] = "SERIAL2"  # issued by a sideload, or a run whose cascade failed
    _seed(_rec("stale", TEAM, "SERIAL1", 5), _rec("current", TEAM, "SERIAL2", 5))

    code, summary = _refresh(capsys)

    assert code == 0
    assert calls == ["stale"], "the app the current certificate signed is left alone"
    assert summary["refreshed"][0]["refresh_mode"] == "resign"


def test_a_signed_out_teams_records_are_left_alone(refresher, certs, capsys):
    calls, _failing = refresher
    certs.clear()  # no account, or no certificate cache, for the team
    _seed(_rec("stale", TEAM, "SERIAL1", 5))

    _refresh(capsys)

    assert calls == []


def test_a_reissue_whose_own_install_then_fails_still_resigns_the_team(refresher, capsys):
    calls, failing = refresher
    failing.add("due")
    _seed(_rec("due", TEAM, "SERIAL1", 1), _rec("later", TEAM, "SERIAL1", 6))

    code, summary = _refresh(capsys)

    assert code == cli.EXIT_PARTIAL_FAILURE
    assert calls == ["due", "later"], "the failed app is not retried in the same run"
    by_id = {r["bundle_id"]: r for r in summary["refreshed"]}
    assert by_id["due"]["status"] == "error" and by_id["later"]["status"] == "installed"


def test_an_app_done_earlier_on_the_old_certificate_is_resigned_again(
    monkeypatch, certs, capsys
):
    """A got a profile on SERIAL1, then B's refresh issued SERIAL2: A is re-signed too."""
    calls: list[tuple[str, bool]] = []

    def fake(entry, on_progress=None, **kwargs):
        calls.append((entry["bundle_id"], kwargs["resign"]))
        serial = "SERIAL2" if entry["bundle_id"] == "b" or kwargs["resign"] else certs[TEAM]
        certs[TEAM] = serial
        stored = {k: v for k, v in entry.items() if k not in ("days_left", "expired")}
        refresh.record({**stored, "cert_serial": serial})
        return {"expires_at": "x", "cert_serial": serial, "refresh_mode": "profile"}

    monkeypatch.setattr(cli.sideload, "refresh_record", fake)
    _seed(_rec("a", TEAM, "SERIAL1", 1), _rec("b", TEAM, "SERIAL1", 1.5))

    code, summary = _refresh(capsys)

    assert code == 0
    assert calls == [("a", False), ("b", False), ("a", True)]
    assert [r["bundle_id"] for r in summary["refreshed"]] == ["a", "b"], "one entry per app"
    assert refresh.get("a")["cert_serial"] == "SERIAL2"


def test_a_single_app_run_looks_only_at_its_own_team(refresher, certs, capsys):
    calls, _failing = refresher
    certs["OTHERTEAM1"] = "SERIAL9"
    _seed(_rec("mine", TEAM, "SERIAL1", 5), _rec("theirs", "OTHERTEAM1", "SERIAL1", 5))

    _code, summary = _refresh(capsys, "--bundle-id", "mine")

    assert calls == ["mine"]
    assert all(set(r) >= {"bundle_id", "status", "refresh_mode", "error"}
               for r in summary["refreshed"])


def test_the_server_reports_exit_2_of_another_command_as_a_failure(monkeypatch):
    monkeypatch.setattr(cli, "dispatch", lambda _ns: 2)
    frames: list[dict] = []

    cli._run_request({"id": 8, "args": ["installs"]}, frames.append)

    assert frames[-1]["ok"] is False


def test_sign_reads_the_bundle_and_signs_under_the_engine_lock(monkeypatch, tmp_path, capsys):
    """So its password and the .p12 it names are read as a pair while another process provisions."""
    depth: dict[str, int] = {}
    bundle = {"p12_path": "p.p12", "p12_password": "pw", "profile_path": "x.mobileprovision",
              "bundle_id": "com.a"}

    def load_bundle():
        depth["load"] = refresh._lock_depth
        return bundle

    def sign_ipa(*_a, **_k):
        depth["sign"] = refresh._lock_depth
        return {"output": str(tmp_path / "out.ipa")}

    monkeypatch.setattr(cli.provision, "load_bundle", load_bundle)
    monkeypatch.setattr(cli.signing, "sign_ipa", sign_ipa)

    code = cli.dispatch(cli.build_parser().parse_args(
        ["sign", "in.ipa", "-o", str(tmp_path / "out.ipa"), "--json"]))

    assert code == 0
    assert depth == {"load": 1, "sign": 1}
    assert refresh._lock_depth == 0


def test_uninstall_holds_the_engine_lock(monkeypatch, capsys):
    """So a refresh in the other process cannot find the app gone and reinstall it."""
    depth: list[int] = []
    monkeypatch.setattr(cli.apps, "uninstall", lambda *_a: depth.append(refresh._lock_depth))

    cli.dispatch(cli.build_parser().parse_args(["uninstall", "com.example.app", "--json"]))

    assert depth == [1]
    assert refresh._lock_depth == 0
