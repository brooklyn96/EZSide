"""Re-issuing a certificate must not touch certificates that are not ours.

Apple's development-certificate limit is scoped per machine, not per account, so one free
team routinely holds several at once - verified on hardware holding three: iPASide's, one
registered by SideStore on the phone, and one by Xcode on a Mac. Revoking any of those
stops every app it signed from launching, in tools iPASide has no part in.

iPASide used to revoke every certificate on the team whenever it needed a new one, which
fires on a fresh install, a lost cache, or an expired certificate.
"""

from __future__ import annotations

import base64
import json

import pytest

from ipaside_engine import developer, gsa, paths, provision, secure_store, signing

TEAM = "ASK9QR9SBC"

OURS = {
    "serialNumber": "29C8EC73C890EBCA0EE74E017975D97B",
    "machineName": provision.CERTIFICATE_MACHINE_NAME,
    "name": "iOS Development: Someone",
}
SIDESTORE = {
    "serialNumber": "6739B3069372332966091DE3341C96BE",
    "machineName": "SideStore - Someone's iPhone",
    "name": "iOS Development: Someone",
}
XCODE = {
    "serialNumber": "63EDA768F91B8C905FC6877994086D66",
    "machineName": "Someone's MacBook Pro",
    "name": "Apple Development: Someone",
}


class _Portal:
    """Records revocations and hands back a freshly issued certificate."""

    def __init__(self, certs, revoke_error=None, csr_error=None):
        self.certs = list(certs)
        self.revoked: list[str] = []
        self.machine_names: list[str] = []
        self.revoke_error = revoke_error
        self.csr_error = csr_error
        self.issued: dict | None = None

    def list_certificates(self, _team_id):
        return list(self.certs) + ([self.issued] if self.issued else [])

    def revoke_certificate(self, _team_id, serial):
        if self.revoke_error is not None:
            raise self.revoke_error
        self.revoked.append(serial)
        self.certs = [c for c in self.certs if c.get("serialNumber") != serial]

    def submit_csr(self, _team_id, _csr_pem, machine_name="EZSide"):
        self.machine_names.append(machine_name)
        if self.csr_error is not None:
            raise self.csr_error
        self.issued = {
            "serialNumber": "NEWLYISSUED0001",
            "machineName": machine_name,
            "certContent": b"der-bytes",
        }
        return {}


@pytest.fixture
def portal(monkeypatch, tmp_path):
    """A fake developer portal, with signing stubbed and the cache in tmp_path."""

    def _make(certs, revoke_error=None, csr_error=None):
        fake = _Portal(certs, revoke_error, csr_error)
        monkeypatch.setattr(developer, "list_certificates", fake.list_certificates)
        monkeypatch.setattr(developer, "revoke_certificate", fake.revoke_certificate)
        monkeypatch.setattr(developer, "submit_csr", fake.submit_csr)
        monkeypatch.setattr(paths, "signing_dir", lambda _slug=None: tmp_path)
        monkeypatch.setattr(
            signing, "generate_key_and_csr", lambda *a, **k: (b"key-pem", "csr-pem")
        )
        # Matching the issued certificate to our key is a crypto detail tested elsewhere.
        monkeypatch.setattr(
            provision,
            "_find_cert_for_key",
            lambda certs, _key: (b"der-bytes", "NEWLYISSUED0001"),
        )
        return fake

    return _make


# --------------------------------------------------------------------------- #
# What may and may not be revoked
# --------------------------------------------------------------------------- #
def test_only_our_own_certificate_is_revoked(portal):
    fake = portal([OURS, SIDESTORE, XCODE])

    provision._ensure_certificate(TEAM, None)

    assert fake.revoked == [OURS["serialNumber"]]


@pytest.mark.parametrize("other", [SIDESTORE, XCODE], ids=["sidestore", "xcode"])
def test_another_tools_certificate_is_left_alone(portal, other):
    """Revoking it would stop every app that tool signed from launching."""
    fake = portal([OURS, other])

    provision._ensure_certificate(TEAM, None)

    assert other["serialNumber"] not in fake.revoked


def test_nothing_is_revoked_when_we_have_no_certificate_yet(portal):
    """A first run on an account already used by Xcode must take nothing away."""
    fake = portal([SIDESTORE, XCODE])

    provision._ensure_certificate(TEAM, None)

    assert fake.revoked == []


def test_a_certificate_without_a_machine_name_is_not_assumed_to_be_ours(portal):
    fake = portal([{"serialNumber": "UNKNOWN01"}])

    provision._ensure_certificate(TEAM, None)

    assert fake.revoked == []


# --------------------------------------------------------------------------- #
# What gets issued
# --------------------------------------------------------------------------- #
def test_the_new_certificate_is_registered_under_our_machine_name(portal):
    """The name is how the next re-issue recognises it; a drifting one orphans it."""
    fake = portal([])

    provision._ensure_certificate(TEAM, None)

    assert fake.machine_names == [provision.CERTIFICATE_MACHINE_NAME]


def test_a_cached_certificate_that_apple_still_lists_is_reused(portal, tmp_path):
    """No revocation, no re-issue: the common path must touch nothing."""
    (tmp_path / "certificate.json").write_text(
        json.dumps(
            {
                "serial": OURS["serialNumber"],
                "key_pem": base64.b64encode(b"key-pem").decode(),
                "cert_der": base64.b64encode(b"der-bytes").decode(),
            }
        ),
        encoding="utf-8",
    )
    fake = portal([OURS, SIDESTORE, XCODE])

    _key, _der, serial = provision._ensure_certificate(TEAM, None)

    assert serial == OURS["serialNumber"]
    assert fake.revoked == []
    assert fake.machine_names == []
    raw = (tmp_path / "certificate.json").read_bytes()
    assert raw.startswith(secure_store.MAGIC), "a plaintext cache is rewritten protected"


# --------------------------------------------------------------------------- #
# When it goes wrong
# --------------------------------------------------------------------------- #
def test_a_failed_revocation_explains_a_failed_request(portal):
    """The two failures together are the diagnosis; neither alone says much."""
    fake = portal(
        [OURS],
        revoke_error=developer.DeveloperServicesError("7460: cannot revoke"),
        csr_error=developer.DeveloperServicesError("7460: maximum certificates reached"),
    )

    with pytest.raises(gsa.GsaError) as excinfo:
        provision._ensure_certificate(TEAM, None)

    message = str(excinfo.value)
    assert "maximum certificates reached" in message
    assert "cannot revoke" in message
    assert "Apple Developer portal" in message, "say how to get out of it"
    assert fake.machine_names, "the request should still have been attempted"


def test_a_failed_request_alone_is_reported_as_apple_put_it(portal):
    """With nothing else to add, Apple's own message is the most useful one."""
    portal([], csr_error=developer.DeveloperServicesError("7460: something else"))

    with pytest.raises(developer.DeveloperServicesError, match="something else"):
        provision._ensure_certificate(TEAM, None)


def test_a_failed_revocation_alone_does_not_stop_a_working_request(portal):
    """The certificate may simply already be gone; the request is the real test."""
    fake = portal([OURS], revoke_error=developer.DeveloperServicesError("already revoked"))

    _key, _der, serial = provision._ensure_certificate(TEAM, None)

    assert serial == "NEWLYISSUED0001"
    assert fake.machine_names == [provision.CERTIFICATE_MACHINE_NAME]


# --------------------------------------------------------------------------- #
# Secrets at rest
# --------------------------------------------------------------------------- #
def test_a_new_certificate_is_cached_protected(portal, tmp_path):
    portal([])

    provision._ensure_certificate(TEAM, None)

    path = tmp_path / "certificate.json"
    assert path.read_bytes().startswith(secure_store.MAGIC)
    assert secure_store.read_json(path)["serial"] == "NEWLYISSUED0001"


@pytest.fixture
def provisioning(monkeypatch, tmp_path):
    """ensure_signing_assets with Apple stubbed; returns the passwords build_p12 saw."""
    seen: list[str] = []
    monkeypatch.setattr(paths, "signing_dir", lambda _slug=None: tmp_path)
    monkeypatch.setattr(gsa, "load_session", lambda *a, **k: {"email": None})
    monkeypatch.setattr(developer, "list_teams", lambda: [{"teamId": TEAM, "name": "T"}])
    monkeypatch.setattr(provision, "_ensure_certificate", lambda *_a: (b"key", b"der", "S1"))
    monkeypatch.setattr(provision, "_ensure_device", lambda *_a: None)
    monkeypatch.setattr(provision, "_ensure_app_id", lambda *_a: {"appIdId": "APPID"})
    monkeypatch.setattr(
        developer, "download_profile", lambda *_a: {"encodedProfile": b"profile"}
    )
    monkeypatch.setattr(
        signing, "build_p12", lambda _der, _key, password: seen.append(password) or b"p12"
    )
    return seen


def test_each_identity_gets_a_random_password_kept_only_in_the_protected_bundle(
    provisioning, tmp_path
):
    first = provision.ensure_signing_assets("com.a", "UDID")
    second = provision.ensure_signing_assets("com.a", "UDID")

    assert provisioning == [first["p12_password"], second["p12_password"]]
    assert first["p12_password"] != second["p12_password"]
    assert len(first["p12_password"]) >= 32
    assert first["p12_password"] != signing.P12_PASSWORD, "not the public constant"
    raw = (tmp_path / "bundle.json").read_bytes()
    assert raw.startswith(secure_store.MAGIC)
    assert secure_store.read_json(tmp_path / "bundle.json") == second
    assert provision.load_bundle() == second


def test_a_legacy_plaintext_bundle_is_read_and_rewritten_protected(monkeypatch, tmp_path):
    monkeypatch.setattr(paths, "signing_dir", lambda _slug=None: tmp_path)
    monkeypatch.setattr(gsa, "load_session", lambda *a, **k: {"email": None})
    legacy = {"team_id": TEAM, "p12_password": "iPASide"}
    (tmp_path / "bundle.json").write_text(json.dumps(legacy), encoding="utf-8")

    assert provision.load_bundle() == legacy
    assert (tmp_path / "bundle.json").read_bytes().startswith(secure_store.MAGIC)
    assert provision.load_bundle() == legacy
