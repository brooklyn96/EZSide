"""Tests for signing with an imported certificate: which signer a sideload picks, that
the custom path never talks to Apple, the record marker it leaves, how a refresh
re-signs such a record, and re-signing them all after a replacement certificate.

The certificate itself is custom_cert's business; here it is stubbed by its contract
(``active()`` and ``signing_bundle()``), so these tests hold whatever store sits behind it.
"""

import sys
import types
from pathlib import Path

import pytest

import ipaside_engine
from ipaside_engine import sideload

UDID = "UDID"
FINGERPRINT = "a" * 40


class _Forbidden:
    """Stands in for a module the custom path must not touch: any attribute is a failure."""

    def __init__(self, name):
        self._name = name

    def __getattr__(self, attr):
        raise AssertionError(f"custom signing called {self._name}.{attr}")


@pytest.fixture
def cert(monkeypatch, tmp_path):
    """The custom_cert module with ``active``/``signing_bundle`` faked and observable.

    A stub module stands in when custom_cert.py is not there yet (it is written in
    parallel), so these tests depend only on its contract.
    """
    try:
        from ipaside_engine import custom_cert
    except ImportError:
        custom_cert = types.ModuleType("ipaside_engine.custom_cert")

        class CustomCertError(sideload.EngineError):
            pass

        custom_cert.CustomCertError = CustomCertError
        monkeypatch.setitem(sys.modules, "ipaside_engine.custom_cert", custom_cert)
        monkeypatch.setattr(ipaside_engine, "custom_cert", custom_cert, raising=False)

    state = {"active": True, "fingerprint": FINGERPRINT, "calls": [], "fail": set(),
             "team": "SELLERTEAM", "app_id": "SELLERTEAM.*", "device_ok": True}
    profile = tmp_path / "custom.mobileprovision"
    profile.write_bytes(b"not read on the custom path")

    def signing_bundle(source_bundle_id, udid, bundle_id=None):
        state["calls"].append((source_bundle_id, udid, bundle_id))
        if not state["active"]:
            raise custom_cert.CustomCertError("No imported certificate is active.")
        if not state["device_ok"]:
            raise custom_cert.CustomCertError(f"This iPhone (UDID {udid}) is not in the profile.")
        target = bundle_id or source_bundle_id
        if target in state["fail"]:
            raise custom_cert.CustomCertError(f"{target} does not fit the profile.")
        return {
            "p12_path": "custom.p12", "p12_password": "re-export", "profile_path": str(profile),
            "team_id": state["team"], "team_name": "Seller Ltd", "bundle_id": target,
            "certificate_serial": "C0FFEE", "fingerprint": state["fingerprint"],
            "expires_at": "2027-11-01T00:00:00Z",
        }

    def status(udid=None):
        return {"team_id": state["team"], "app_id": state["app_id"],
                "wildcard": state["app_id"].endswith("*"),
                "device_ok": None if udid is None else state["device_ok"]}

    monkeypatch.setattr(custom_cert, "active", lambda: state["active"], raising=False)
    monkeypatch.setattr(custom_cert, "status", status, raising=False)
    monkeypatch.setattr(custom_cert, "signing_bundle", signing_bundle, raising=False)
    state["module"] = custom_cert
    return state


@pytest.fixture
def harness(tmp_path, monkeypatch):
    """run_sideload with zsign and the device stubbed; Apple provisioning is observable."""
    source = tmp_path / "app.ipa"
    source.write_bytes(b"PK\x03\x04")
    signed_dir = tmp_path / "signed"
    state = {"signed": [], "provisioned": 0, "installed": [], "source": source}

    def sign_ipa(_ipa, output, **kwargs):
        state["signed"].append(kwargs)
        Path(output).write_bytes(b"\0")

    def ensure_signing_assets(*_a, **_k):
        state["provisioned"] += 1
        return {"p12_path": "apple.p12", "p12_password": "pw",
                "profile_path": str(tmp_path / "apple.mobileprovision"),
                "team_id": "APPLETEAM", "certificate_serial": "APPLESERIAL"}

    monkeypatch.setattr(sideload, "resolve_udid", lambda udid: udid or UDID)
    monkeypatch.setattr(sideload.device, "get_device_info", lambda _u: {})
    monkeypatch.setattr(sideload.ipa_module, "inspect",
                        lambda _p: {"bundle_id": "com.example.app", "display_name": "Example"})
    monkeypatch.setattr(sideload.ipa_module, "app_group_identifiers", lambda _p: [])
    monkeypatch.setattr(sideload.paths, "signed_dir", lambda: signed_dir)
    monkeypatch.setattr(sideload.provision, "team_scoped_bundle_id", lambda b: f"{b}.APPLETEAM")
    monkeypatch.setattr(sideload.provision, "ensure_signing_assets", ensure_signing_assets)
    monkeypatch.setattr(sideload.signing, "sign_ipa", sign_ipa)
    monkeypatch.setattr(sideload.apps, "install",
                        lambda output, udid, **_k: state["installed"].append(udid))
    return state


def _no_apple(monkeypatch):
    for name in ("gsa", "developer", "provision"):
        monkeypatch.setattr(sideload, name, _Forbidden(name))


# --------------------------------------------------------------------------- #
# Which signer a sideload uses
# --------------------------------------------------------------------------- #
def test_auto_with_an_active_certificate_signs_without_apple(harness, cert, monkeypatch):
    _no_apple(monkeypatch)
    steps = []

    result = sideload.run_sideload(
        str(harness["source"]), UDID, record=True,
        on_progress=lambda phase, _pct, step: steps.append((phase, step)),
    )

    assert cert["calls"] == [("com.example.app", UDID, None)]
    signed = harness["signed"][0]
    assert (signed["p12_path"], signed["p12_password"]) == ("custom.p12", "re-export")
    assert signed["bundle_id"] == "com.example.app", "the profile decides the id, not a team suffix"
    assert signed["entitlements"] is None, "zsign uses the profile's own entitlements"
    assert ("provision", "Using your imported certificate…") in steps
    assert result["signer"] == "custom"

    stored = sideload.refresh.get("com.example.app")
    assert stored["signer"] == "custom"
    assert stored["cert_fingerprint"] == FINGERPRINT
    assert stored["team_id"] == "SELLERTEAM"
    assert stored["cert_serial"] == "C0FFEE"
    assert stored["expires_at"] == "2027-11-01T00:00:00Z"
    assert stored["cached_ipa"]


def test_auto_without_an_active_certificate_stays_with_apple(harness, cert):
    cert["active"] = False

    sideload.run_sideload(str(harness["source"]), UDID, record=True)

    assert harness["provisioned"] == 1
    assert cert["calls"] == []
    stored = sideload.refresh.get("com.example.app.APPLETEAM")
    assert "signer" not in stored and "cert_fingerprint" not in stored
    assert stored["cert_serial"] == "APPLESERIAL"


def test_apple_ignores_an_active_certificate(harness, cert):
    sideload.run_sideload(str(harness["source"]), UDID, record=False, signer="apple")

    assert harness["provisioned"] == 1
    assert cert["calls"] == []


def test_custom_without_an_active_certificate_is_an_error(harness, cert):
    cert["active"] = False

    with pytest.raises(cert["module"].CustomCertError):
        sideload.run_sideload(str(harness["source"]), UDID, record=False, signer="custom")

    assert harness["provisioned"] == 0
    assert harness["installed"] == []


def test_auto_falls_back_to_apple_when_the_iphone_is_not_in_the_profile(harness, cert):
    cert["device_ok"] = False
    steps = []

    sideload.run_sideload(
        str(harness["source"]), UDID, record=False,
        on_progress=lambda phase, _pct, step: steps.append((phase, step)),
    )

    assert harness["provisioned"] == 1
    assert cert["calls"] == []
    assert ("provision", "Your imported certificate does not include this iPhone; "
            "using your Apple ID.") in steps


def test_custom_still_refuses_an_iphone_that_is_not_in_the_profile(harness, cert):
    cert["device_ok"] = False

    with pytest.raises(cert["module"].CustomCertError, match="not in the profile"):
        sideload.run_sideload(str(harness["source"]), UDID, record=False, signer="custom")

    assert harness["provisioned"] == 0
    assert harness["installed"] == []


def test_custom_passes_an_explicit_bundle_id_to_the_certificate(harness, cert, monkeypatch):
    _no_apple(monkeypatch)

    result = sideload.run_sideload(
        str(harness["source"]), UDID, record=False, signer="custom", bundle_id="com.seller.x"
    )

    assert cert["calls"] == [("com.example.app", UDID, "com.seller.x")]
    assert result["bundle_id"] == "com.seller.x"


@pytest.mark.parametrize("signer", ["auto", "custom"])
def test_a_named_profile_always_signs_with_apple(harness, cert, monkeypatch, signer):
    monkeypatch.setattr(sideload, "_signing_profile", lambda *_a: ([], {"k": True}, []))
    monkeypatch.setattr(sideload, "_profile_post_install", lambda *_a: None)
    monkeypatch.setattr(sideload.developer, "list_teams", lambda: [{"teamId": "APPLETEAM"}])

    sideload.run_sideload(
        str(harness["source"]), UDID, record=False, profile="livecontainer", signer=signer
    )

    assert harness["provisioned"] == 1
    assert cert["calls"] == []


def test_an_unknown_signer_is_refused(harness, cert):
    with pytest.raises(sideload.SideloadError, match="Unknown signer"):
        sideload.run_sideload(str(harness["source"]), UDID, record=False, signer="other")


# --------------------------------------------------------------------------- #
# Refreshing a custom record
# --------------------------------------------------------------------------- #
def _sideload_custom(harness):
    sideload.run_sideload(str(harness["source"]), UDID, record=True)
    return sideload.refresh.get("com.example.app")


def test_refresh_resigns_a_custom_record_from_the_cache_without_an_account(
    harness, cert, monkeypatch
):
    entry = _sideload_custom(harness)
    harness["source"].unlink()  # the user's file is gone; EZSide's copy is not
    _no_apple(monkeypatch)
    monkeypatch.setattr(sideload, "_refresh_account", _Forbidden("_refresh_account"))
    monkeypatch.setattr(sideload, "_refresh_profile_only", _Forbidden("_refresh_profile_only"))

    result = sideload.refresh_record(entry)

    assert result["refresh_mode"] == "resign"
    assert result["signer"] == "custom"
    assert len(harness["installed"]) == 2
    assert cert["calls"][-1] == ("com.example.app", UDID, "com.example.app")


def test_refresh_after_a_replacement_certificate_takes_the_new_fingerprint(harness, cert):
    entry = _sideload_custom(harness)
    cert["fingerprint"] = "b" * 40

    sideload.refresh_record(entry)

    assert sideload.refresh.get("com.example.app")["cert_fingerprint"] == "b" * 40


def test_refresh_of_an_apple_record_stays_with_apple(harness, cert, monkeypatch):
    calls = []
    monkeypatch.setattr(
        sideload, "run_sideload",
        lambda ipa, udid, **kwargs: calls.append(kwargs) or {"status": "installed"},
    )
    entry = {"bundle_id": "com.example.app.APPLETEAM", "name": "Example", "udid": UDID,
             "source_ipa": str(harness["source"]), "options": {}}

    sideload.refresh_record(entry)

    assert calls[0]["signer"] == "apple"


# --------------------------------------------------------------------------- #
# Re-signing every custom app
# --------------------------------------------------------------------------- #
def test_resign_custom_reports_each_app_and_survives_a_failure(harness, cert, monkeypatch, tmp_path):
    for bundle_id in ("com.example.one", "com.example.two"):
        sideload.run_sideload(str(harness["source"]), UDID, record=True, bundle_id=bundle_id)
    other = dict(sideload.refresh.get("com.example.two"), bundle_id="com.example.other",
                 udid="OTHER")
    sideload.refresh.record(other)
    cert["active"] = False
    sideload.run_sideload(str(harness["source"]), UDID, record=True)  # an Apple record
    cert["active"] = True
    cert["fail"] = {"com.example.one"}
    _no_apple(monkeypatch)
    installed_before = len(harness["installed"])

    results = sorted(sideload.resign_custom(UDID), key=lambda r: r["bundle_id"])

    assert [(r["bundle_id"], r["ok"]) for r in results] == [
        ("com.example.one", False), ("com.example.two", True),
    ]
    assert "does not fit" in results[0]["error"]
    assert results[1]["error"] is None
    assert results[1]["name"] == "Example"
    assert len(harness["installed"]) == installed_before + 1


def test_resign_custom_without_a_udid_takes_every_device(harness, cert):
    sideload.run_sideload(str(harness["source"]), UDID, record=True)
    sideload.refresh.record(dict(sideload.refresh.get("com.example.app"),
                                 bundle_id="com.example.other", udid="OTHER"))

    results = sideload.resign_custom()

    assert sorted(r["bundle_id"] for r in results) == ["com.example.app", "com.example.other"]
    assert all(r["ok"] for r in results)


def test_resign_after_a_team_change_asks_to_delete_the_app_first(harness, cert, monkeypatch):
    _sideload_custom(harness)
    cert["team"] = "NEWTEAM"
    monkeypatch.setattr(sideload.apps, "list_installed", lambda _u: {"com.example.app": {}})
    signed, installed = len(harness["signed"]), len(harness["installed"])

    results = sideload.resign_custom(UDID)

    assert results == [{
        "bundle_id": "com.example.app", "name": "Example", "ok": False,
        "error": "Example was signed by team SELLERTEAM and the new certificate is team "
                 "NEWTEAM, so iOS will not update it in place. Delete Example from the "
                 "iPhone (its data will be lost), then press Re-sign again.",
    }]
    assert len(harness["signed"]) == signed and len(harness["installed"]) == installed
    assert sideload.refresh.get("com.example.app")["team_id"] == "SELLERTEAM"


def test_resign_after_a_team_change_installs_fresh_once_the_app_is_deleted(
    harness, cert, monkeypatch
):
    _sideload_custom(harness)
    cert["team"] = "NEWTEAM"
    monkeypatch.setattr(sideload.apps, "list_installed", lambda _u: {})
    installed = len(harness["installed"])

    results = sideload.resign_custom(UDID)

    assert [r["ok"] for r in results] == [True]
    assert len(harness["installed"]) == installed + 1
    assert sideload.refresh.get("com.example.app")["team_id"] == "NEWTEAM"


def test_resign_with_an_explicit_app_id_that_no_longer_covers_the_app(harness, cert, monkeypatch):
    _sideload_custom(harness)
    cert["app_id"] = "SELLERTEAM.com.other"
    monkeypatch.setattr(sideload.apps, "list_installed", _Forbidden("apps.list_installed"))
    installed = len(harness["installed"])

    results = sideload.resign_custom(UDID)

    assert results[0]["ok"] is False
    assert "only covers com.other" in results[0]["error"]
    assert "Leave the bundle id empty" not in results[0]["error"]
    assert len(harness["installed"]) == installed


@pytest.mark.parametrize("change, reason", [
    ({"active": False}, "expired on"),
    ({"device_ok": False}, "(UDID UDID) is not in the new provisioning profile"),
    ({"app_id": "NEWTEAM.com.other"}, "only covers com.other,"),
    ({"app_id": "NEWTEAM.p.*"}, "only covers ids starting with p., so it cannot re-sign "
                                "Example (com.example.app)"),
])
def test_resign_that_cannot_sign_gives_its_reason_not_delete_advice(
    harness, cert, monkeypatch, change, reason
):
    _sideload_custom(harness)
    cert.update(team="NEWTEAM", **change)  # a team change too: its advice must not win
    monkeypatch.setattr(sideload.apps, "list_installed", _Forbidden("apps.list_installed"))
    monkeypatch.setattr(sideload.apps, "install", _Forbidden("apps.install"))
    signed = len(harness["signed"])

    results = sideload.resign_custom(UDID)

    assert results[0]["ok"] is False
    assert reason in results[0]["error"]
    assert "Delete" not in results[0]["error"]
    assert len(harness["signed"]) == signed


def test_resign_custom_progress_names_the_app(harness, cert):
    _sideload_custom(harness)
    seen = []

    sideload.resign_custom(UDID, on_progress=lambda *args: seen.append(args))

    assert seen and all(args[0] == "com.example.app" for args in seen)
    assert ("com.example.app", "provision", None, "Using your imported certificate…") in seen
