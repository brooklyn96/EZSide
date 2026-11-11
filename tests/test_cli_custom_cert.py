"""The command-line surface for the imported certificate: cert-import / cert-status /
cert-remove / cert-resign, `sideload --signer`, and `custom_expiring` in the refresh JSON.

The commands are driven the way the desktop app drives them (JSON, and through the
persistent ``serve`` request loop with the password in the per-request env), with
custom_cert / sideload.resign_custom / refresh.custom_expiring stubbed: they have their
own tests.
"""

import json
import os
import threading

import pytest

from ipaside_engine import __main__ as cli

SECRET = "s3cret-Pa55 word"
INFO = {"name": "Seller Cert", "team_id": "TEAM123456", "team_name": "Seller Ltd",
        "expires": "2030-01-01T00:00:00Z"}


def _parse(argv):
    return cli.build_parser().parse_args(argv)


def _out(capsys):
    return json.loads(capsys.readouterr().out)


# --- parser ---------------------------------------------------------------------

def test_sideload_signer_defaults_to_auto_and_takes_the_three_values():
    assert _parse(["sideload", "app.ipa"]).signer == "auto"
    for value in ("auto", "apple", "custom"):
        assert _parse(["sideload", "app.ipa", "--signer", value]).signer == value
    with pytest.raises(SystemExit):
        _parse(["sideload", "app.ipa", "--signer", "other"])


def test_sideload_forwards_the_signer(monkeypatch):
    seen = {}

    def fake_run_sideload(ipa, _udid, **kwargs):
        seen.update(kwargs)
        return {"name": "Example", "bundle_id": "com.example.app"}

    monkeypatch.setattr(cli.sideload, "run_sideload", fake_run_sideload)
    assert cli.dispatch(_parse(["sideload", "app.ipa", "--signer", "custom", "--json"])) == 0
    assert seen["signer"] == "custom"
    cli.dispatch(_parse(["sideload", "app.ipa", "--json"]))
    assert seen["signer"] == "auto"


def test_cert_import_has_no_password_option():
    args = _parse(["cert-import", "--p12", "a.p12", "--profile", "a.mobileprovision"])
    assert (args.p12, args.profile) == ("a.p12", "a.mobileprovision")
    with pytest.raises(SystemExit):
        _parse(["cert-import", "--p12", "a.p12", "--profile", "b", "--password", SECRET])
    with pytest.raises(SystemExit):
        _parse(["cert-import", "--p12", "a.p12"])


# --- cert-import ---------------------------------------------------------------

def test_cert_import_reads_the_password_from_the_environment_only(monkeypatch, capsys):
    seen = {}

    def fake_import(p12, password, profile):
        seen.update(p12=p12, password=password, profile=profile)
        return INFO

    monkeypatch.setattr(cli.custom_cert, "import_certificate", fake_import)
    monkeypatch.setenv("IPASIDE_CERT_PASSWORD", SECRET)
    argv = ["cert-import", "--p12", "a.p12", "--profile", "a.mobileprovision", "--json"]
    assert SECRET not in " ".join(argv)

    assert cli.dispatch(_parse(argv)) == 0
    assert seen["password"] == SECRET
    assert str(seen["p12"]) == "a.p12" and str(seen["profile"]) == "a.mobileprovision"
    captured = capsys.readouterr()
    assert json.loads(captured.out) == {"status": "ok", "certificate": INFO}
    assert SECRET not in captured.out + captured.err

    assert cli.dispatch(_parse(argv[:-1])) == 0  # human output too
    captured = capsys.readouterr()
    assert SECRET not in captured.out + captured.err


def test_cert_import_without_the_env_is_a_clear_error_and_never_prompts(monkeypatch, capsys):
    monkeypatch.delenv("IPASIDE_CERT_PASSWORD", raising=False)
    monkeypatch.setattr(cli.custom_cert, "import_certificate",
                        lambda *a: pytest.fail("must not be called without a password"))
    monkeypatch.setattr(cli.getpass, "getpass", lambda *a: pytest.fail("must not prompt"))
    argv = ["cert-import", "--p12", "a.p12", "--profile", "b.mobileprovision", "--json"]

    assert cli.main(argv) == 1
    payload = _out(capsys)
    assert payload["status"] == "error"
    assert "IPASIDE_CERT_PASSWORD" in payload["error"]


def test_cert_import_errors_do_not_echo_the_password(monkeypatch, capsys):
    def fail(*_a):
        raise cli.custom_cert.CustomCertError("The password is wrong or the .p12 is unreadable.")

    monkeypatch.setattr(cli.custom_cert, "import_certificate", fail)
    monkeypatch.setenv("IPASIDE_CERT_PASSWORD", SECRET)
    assert cli.main(["cert-import", "--p12", "a", "--profile", "b"]) == 1
    captured = capsys.readouterr()
    assert "unreadable" in captured.err
    assert SECRET not in captured.out + captured.err


# --- cert-status / cert-remove ----------------------------------------------------

def test_cert_status_reports_the_certificate_or_null(monkeypatch, capsys):
    seen = []
    monkeypatch.setattr(cli.custom_cert, "status", lambda udid=None: seen.append(udid) or INFO)
    assert cli.dispatch(_parse(["cert-status", "--udid", "U1", "--json"])) == 0
    assert _out(capsys) == {"status": "ok", "certificate": INFO}
    assert seen == ["U1"]

    monkeypatch.setattr(cli.custom_cert, "status", lambda udid=None: None)
    assert cli.dispatch(_parse(["cert-status", "--json"])) == 0
    assert _out(capsys) == {"status": "ok", "certificate": None}
    assert cli.dispatch(_parse(["cert-status"])) == 0
    assert "No certificate" in capsys.readouterr().out


def test_cert_remove_reports_whether_one_was_removed(monkeypatch, capsys):
    for removed in (True, False):
        monkeypatch.setattr(cli.custom_cert, "remove", lambda removed=removed: removed)
        assert cli.dispatch(_parse(["cert-remove", "--json"])) == 0
        assert _out(capsys) == {"status": "ok", "removed": removed}


# --- cert-resign ------------------------------------------------------------------

def test_cert_resign_returns_every_result_and_exits_1_when_one_failed(monkeypatch, capsys):
    seen = {}
    ok = {"bundle_id": "com.a", "name": "A", "ok": True, "error": None}
    bad = {"bundle_id": "com.b", "name": "B", "ok": False, "error": "no IPA copy"}

    def fake_resign(udid=None, on_progress=None):
        seen["udid"] = udid
        return [ok, bad]

    monkeypatch.setattr(cli.sideload, "resign_custom", fake_resign)

    assert cli.dispatch(_parse(["cert-resign", "--udid", "U1", "--json"])) == 1
    payload = _out(capsys)
    assert seen["udid"] == "U1"
    assert payload["status"] == "ok" and payload["results"] == [ok, bad]

    monkeypatch.setattr(cli.sideload, "resign_custom", lambda udid=None, on_progress=None: [ok])
    assert cli.dispatch(_parse(["cert-resign", "--json"])) == 0
    assert _out(capsys) == {"status": "ok", "results": [ok]}


def test_cert_resign_answers_a_busy_lock_at_once_without_touching_any_app(monkeypatch, capsys):
    held, release = threading.Event(), threading.Event()

    def hold():
        with cli.refresh.operation_lock():
            held.set()
            release.wait(10)

    holder = threading.Thread(target=hold)
    holder.start()
    assert held.wait(10)
    called = []
    monkeypatch.setattr(cli.sideload, "resign_custom", lambda *a, **k: called.append(a) or [])
    try:
        with pytest.raises(cli.refresh.OperationBusy, match="Another EZSide operation is running"):
            cli.dispatch(_parse(["cert-resign", "--json"]))
        assert cli.main(["cert-resign", "--json"]) == 1
        assert _out(capsys)["status"] == "error"
    finally:
        release.set()
        holder.join()
    assert called == []


def test_cert_resign_progress_carries_the_bundle_id(monkeypatch, capsys):
    def fake_resign(udid=None, on_progress=None):
        on_progress("com.a", "sign", 40, "Signing A")
        return []

    monkeypatch.setattr(cli.sideload, "resign_custom", fake_resign)
    assert cli.dispatch(_parse(["cert-resign", "--json"])) == 0
    event = json.loads(capsys.readouterr().err.strip())
    assert event == {"event": "progress", "phase": "sign", "percent": 40,
                     "step": "Signing A", "bundle_id": "com.a"}


# --- refresh ----------------------------------------------------------------------

def _refresh_stubs(monkeypatch, expiring):
    monkeypatch.setattr(cli.refresh, "records", lambda: [{"bundle_id": "com.apple.one"}])
    monkeypatch.setattr(cli.refresh, "due", lambda _within=2.0: [])
    monkeypatch.setattr(cli.refresh, "custom_expiring", lambda within_days=14.0: expiring)
    monkeypatch.setattr(cli.sideload, "refresh_record", lambda *_a, **_k: {"expires_at": None})


EXPIRING = [{"bundle_id": "com.c", "name": "C", "days_left": 3.5, "udid": "U", "extra": 1}]


@pytest.mark.parametrize("flags", [[], ["--unattended"], ["--all"]])
def test_refresh_json_carries_custom_expiring(monkeypatch, capsys, flags):
    _refresh_stubs(monkeypatch, EXPIRING)
    assert cli.dispatch(_parse(["refresh", *flags, "--json"])) == 0
    payload = _out(capsys)
    assert payload["custom_expiring"] == [{"bundle_id": "com.c", "name": "C", "days_left": 3.5}]
    assert payload["status"] == "done"


def test_refresh_custom_expiring_is_empty_list_when_none(monkeypatch, capsys):
    _refresh_stubs(monkeypatch, [])
    assert cli.dispatch(_parse(["refresh", "--unattended", "--json"])) == 0
    assert _out(capsys)["custom_expiring"] == []


def test_refresh_custom_expiring_does_not_change_the_exit_code(monkeypatch, capsys):
    _refresh_stubs(monkeypatch, EXPIRING)

    def boom(*_a, **_k):
        raise RuntimeError("phone said no")

    monkeypatch.setattr(cli.sideload, "refresh_record", boom)
    assert cli.dispatch(_parse(["refresh", "--all", "--json"])) == cli.EXIT_PARTIAL_FAILURE
    assert _out(capsys)["custom_expiring"][0]["bundle_id"] == "com.c"


def test_refresh_busy_unattended_run_still_reports_custom_expiring(monkeypatch, capsys):
    _refresh_stubs(monkeypatch, EXPIRING)

    def busy(wait=True):
        raise cli.refresh.OperationBusy("Another EZSide operation is running.")

    monkeypatch.setattr(cli.refresh, "operation_lock", busy)
    assert cli.dispatch(_parse(["refresh", "--unattended", "--json"])) == 0
    payload = _out(capsys)
    assert payload["count"] == 0
    assert payload["custom_expiring"][0]["bundle_id"] == "com.c"


# --- serve mode -------------------------------------------------------------------

def _serve_request(args, env=None):
    frames = []
    cli._run_request({"id": 7, "args": args, "env": env or {}}, frames.append)
    return frames[-1], frames


def test_serve_passes_the_cert_password_per_request_and_restores_the_env(monkeypatch):
    seen = {}

    def fake_import(p12, password, profile):
        seen["password"] = password
        return INFO

    monkeypatch.setattr(cli.custom_cert, "import_certificate", fake_import)
    monkeypatch.delenv("IPASIDE_CERT_PASSWORD", raising=False)

    result, frames = _serve_request(
        ["cert-import", "--p12", "a.p12", "--profile", "b.mobileprovision"],
        {"IPASIDE_CERT_PASSWORD": SECRET},
    )
    assert result["ok"] is True
    assert result["data"] == {"status": "ok", "certificate": INFO}
    assert seen["password"] == SECRET
    assert SECRET not in json.dumps(frames)
    assert "IPASIDE_CERT_PASSWORD" not in os.environ  # restored after the request

    # No env on the next request: the earlier password is gone, so it is the clear error.
    result, _ = _serve_request(["cert-import", "--p12", "a.p12", "--profile", "b"])
    assert result["ok"] is False
    assert "IPASIDE_CERT_PASSWORD" in result["error"]


def test_serve_runs_the_other_cert_commands(monkeypatch):
    monkeypatch.setattr(cli.custom_cert, "status", lambda udid=None: INFO)
    monkeypatch.setattr(cli.custom_cert, "remove", lambda: True)
    bad = {"bundle_id": "com.b", "name": "B", "ok": False, "error": "x"}
    monkeypatch.setattr(cli.sideload, "resign_custom", lambda udid=None, on_progress=None: [bad])

    result, _ = _serve_request(["cert-status", "--udid", "U1"])
    assert result["ok"] and result["data"]["certificate"] == INFO
    result, _ = _serve_request(["cert-remove"])
    assert result["ok"] and result["data"]["removed"] is True
    result, _ = _serve_request(["cert-resign"])
    assert result["ok"] is False  # exit 1: one app failed
    assert result["data"]["results"] == [bad]
    assert "1 of 1" in result["error"]


def test_refresh_never_treats_a_custom_record_as_stale(monkeypatch, capsys):
    # A signed-in Apple ID of the seller's team with another cached serial must not make
    # the imported-certificate app look stale: auto-refresh never touches it.
    custom = {"bundle_id": "com.custom", "signer": "custom", "team_id": "SELLER",
              "cert_serial": "OLD"}
    monkeypatch.setattr(cli.refresh, "records", lambda: [custom])
    monkeypatch.setattr(cli.refresh, "due", lambda _within=2.0: [])
    monkeypatch.setattr(cli.refresh, "custom_expiring", lambda within_days=14.0: [])
    monkeypatch.setattr(cli.gsa, "account_for_team", lambda _team: "someone@example.com")
    monkeypatch.setattr(cli.provision, "cached_serial", lambda _account: "NEW")
    monkeypatch.setattr(cli.sideload, "refresh_record",
                        lambda *_a, **_k: pytest.fail("a custom record must not be refreshed"))

    assert cli._team_serials() == {}
    assert cli._stale_records(None, {}) == []
    assert cli.dispatch(_parse(["refresh", "--unattended", "--json"])) == 0
    assert _out(capsys)["refreshed"] == []


def test_refresh_busy_answer_survives_an_unreadable_registry(monkeypatch, capsys):
    def busy(wait=True):
        raise cli.refresh.OperationBusy("Another EZSide operation is running.")

    def unreadable(within_days=14.0):
        raise cli.refresh.RegistryError("Cannot read the sideload registry.")

    monkeypatch.setattr(cli.refresh, "operation_lock", busy)
    monkeypatch.setattr(cli.refresh, "custom_expiring", unreadable)
    assert cli.dispatch(_parse(["refresh", "--unattended", "--json"])) == 0
    payload = _out(capsys)
    assert payload["count"] == 0 and payload["custom_expiring"] == []


# --- refresh never selects a custom record ----------------------------------------

CUSTOM = {"bundle_id": "com.custom", "name": "Custom App", "signer": "custom", "days_left": 1.0}
APPLE = {"bundle_id": "com.apple.one", "name": "Apple App", "days_left": 1.0}


def _selection_stubs(monkeypatch):
    refreshed = []
    monkeypatch.setattr(cli.refresh, "records", lambda: [CUSTOM, APPLE])
    monkeypatch.setattr(cli.refresh, "due", lambda _within=2.0: [CUSTOM, APPLE])
    monkeypatch.setattr(cli.refresh, "custom_expiring", lambda within_days=14.0: [])
    monkeypatch.setattr(cli.sideload, "refresh_record",
                        lambda entry, **_k: refreshed.append(entry["bundle_id"]) or {})
    return refreshed


@pytest.mark.parametrize("flags", [
    ["--all"], ["--all", "--unattended"], [], ["--unattended"],
    ["--bundle-id", "com.apple.one"], ["--bundle-id", "com.apple.one", "--unattended"],
])
def test_refresh_selection_skips_custom_records_but_still_refreshes_apple_ones(
        monkeypatch, capsys, flags):
    refreshed = _selection_stubs(monkeypatch)
    assert cli.dispatch(_parse(["refresh", *flags, "--json"])) == 0
    assert refreshed == ["com.apple.one"]
    assert [r["bundle_id"] for r in _out(capsys)["refreshed"]] == ["com.apple.one"]


@pytest.mark.parametrize("flags", [[], ["--unattended"]])
def test_refresh_of_a_named_custom_record_is_a_clear_error(monkeypatch, capsys, flags):
    refreshed = _selection_stubs(monkeypatch)
    argv = ["refresh", "--bundle-id", "com.custom", *flags]

    assert cli.dispatch(_parse([*argv, "--json"])) == 1
    assert _out(capsys) == {"status": "error", "error": "Custom App is signed with your "
                            "imported certificate; use Re-sign on the Account page."}
    assert cli.dispatch(_parse(argv)) == 1
    assert "use Re-sign on the Account page." in capsys.readouterr().out
    assert refreshed == []
