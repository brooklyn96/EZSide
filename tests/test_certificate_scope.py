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
from pathlib import Path

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

    _key, _der, serial, password = provision._ensure_certificate(TEAM, None)

    assert serial == OURS["serialNumber"]
    assert fake.revoked == []
    assert fake.machine_names == []
    raw = (tmp_path / "certificate.json").read_bytes()
    assert raw.startswith(secure_store.MAGIC), "a plaintext cache is rewritten protected"
    assert len(password) >= 32, "a legacy cache gets the certificate's own password"
    assert secure_store.read_json(tmp_path / "certificate.json")["p12_password"] == password
    assert provision._ensure_certificate(TEAM, None)[3] == password, "and keeps it"


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


# Apple's own sentence for the limit says "you already have a current certificate", which reads
# as if EZSide had made one. On a free account holding two other tools' certificates it had not
# (iPASide GitHub issue #14): the message must name them and say how to get out.
LIMIT_TEXT = "You already have a current iOS Development certificate or a pending certificate request."
ILOADER = {"serialNumber": "AAAA01", "machineName": "iloader", "name": "iOS Development: Someone"}
CUSTOM = {"serialNumber": "BBBB02", "machineName": "Work laptop", "name": "iOS Development: Someone"}
IPASIDE = {"serialNumber": "CCCC03", "machineName": "iPASide", "name": "iOS Development: Someone"}


def test_the_certificate_limit_names_the_other_tools_and_says_how_to_continue(portal):
    fake = portal([ILOADER, CUSTOM], csr_error=developer.DeveloperServicesError(f"7460: {LIMIT_TEXT}"))

    with pytest.raises(gsa.GsaError) as excinfo:
        provision._ensure_certificate(TEAM, None)

    message = str(excinfo.value)
    assert "iloader" in message and "Work laptop" in message
    assert "Account page" in message and "revoke one of them" in message
    assert "never revokes a certificate it did not create" in message
    assert "stop opening" in message, "say what revoking costs"
    assert LIMIT_TEXT in message, "Apple's own words stay in it"
    assert fake.revoked == [], "another tool's certificate must still be left alone"


def test_the_limit_is_recognised_by_apples_words_when_the_code_is_missing(portal):
    portal([ILOADER], csr_error=developer.DeveloperServicesError(LIMIT_TEXT))

    with pytest.raises(gsa.GsaError, match="revoke one of them"):
        provision._ensure_certificate(TEAM, None)


def test_the_limit_after_our_own_certificate_was_revoked_still_names_the_others(portal):
    fake = portal([OURS, ILOADER], csr_error=developer.DeveloperServicesError(f"7460: {LIMIT_TEXT}"))

    with pytest.raises(gsa.GsaError) as excinfo:
        provision._ensure_certificate(TEAM, None)

    message = str(excinfo.value)
    assert "(iloader)" in message, "only the other tool is listed; our own certificate is not 'another tool'"
    assert fake.revoked == [OURS["serialNumber"]]


def test_an_iPASide_certificate_is_another_tools_certificate(portal):
    """Upstream iPASide next to EZSide: a different machine name, so it is listed, not ours."""
    fake = portal([OURS, IPASIDE], csr_error=developer.DeveloperServicesError(f"7460: {LIMIT_TEXT}"))

    with pytest.raises(gsa.GsaError) as excinfo:
        provision._ensure_certificate(TEAM, None)

    assert "(iPASide)" in str(excinfo.value)
    assert fake.revoked == [OURS["serialNumber"]], "the iPASide certificate is left alone"


def test_an_unnamed_certificate_is_still_reported(portal):
    portal([{"serialNumber": "NONAME01"}], csr_error=developer.DeveloperServicesError("7460: limit"))

    with pytest.raises(gsa.GsaError, match="an unnamed certificate"):
        provision._ensure_certificate(TEAM, None)


def test_each_other_tool_is_named_once(portal):
    twin = dict(ILOADER, serialNumber="AAAA02")
    portal([ILOADER, twin], csr_error=developer.DeveloperServicesError("7460: limit"))

    with pytest.raises(gsa.GsaError) as excinfo:
        provision._ensure_certificate(TEAM, None)

    assert str(excinfo.value).count("iloader") == 1


def test_the_limit_with_nothing_else_on_the_account_is_reported_as_apple_put_it(portal):
    portal([], csr_error=developer.DeveloperServicesError(f"7460: {LIMIT_TEXT}"))

    with pytest.raises(developer.DeveloperServicesError, match="already have a current"):
        provision._ensure_certificate(TEAM, None)


def test_another_refusal_is_not_blamed_on_other_tools_certificates(portal):
    portal([ILOADER], csr_error=developer.DeveloperServicesError("3004: something else entirely"))

    with pytest.raises(developer.DeveloperServicesError, match="something else entirely"):
        provision._ensure_certificate(TEAM, None)


def test_a_failed_request_alone_is_reported_as_apple_put_it(portal):
    """With nothing else to add, Apple's own message is the most useful one."""
    portal([], csr_error=developer.DeveloperServicesError("7460: something else"))

    with pytest.raises(developer.DeveloperServicesError, match="something else"):
        provision._ensure_certificate(TEAM, None)


def test_a_failed_revocation_alone_does_not_stop_a_working_request(portal):
    """The certificate may simply already be gone; the request is the real test."""
    fake = portal([OURS], revoke_error=developer.DeveloperServicesError("already revoked"))

    _key, _der, serial, _password = provision._ensure_certificate(TEAM, None)

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


def test_a_new_certificate_gets_its_own_password(portal, tmp_path):
    portal([])

    *_rest, first = provision._ensure_certificate(TEAM, None)
    *_rest, again = provision._ensure_certificate(TEAM, None)

    assert len(first) >= 32 and first != signing.P12_PASSWORD
    assert again == first, "one password per certificate issued, not per write"
    assert secure_store.read_json(tmp_path / "certificate.json")["p12_password"] == first


def _unreadable(monkeypatch, path):
    """A protected file DPAPI refuses: the data folder was copied to another PC or user."""
    path.write_bytes(secure_store.MAGIC + b"blob from another machine")

    def refuse(_blob):
        raise OSError("Key not valid for use in specified state")

    monkeypatch.setattr(secure_store, "unprotect", refuse)


def test_an_unreadable_certificate_cache_is_treated_as_missing(portal, tmp_path, monkeypatch, capsys):
    fake = portal([OURS])
    _unreadable(monkeypatch, tmp_path / "certificate.json")
    monkeypatch.setattr(secure_store, "protect", lambda data: data)

    _key, _der, serial, _password = provision._ensure_certificate(TEAM, None)

    assert serial == "NEWLYISSUED0001", "a new certificate is issued, as on first use"
    assert fake.revoked == [OURS["serialNumber"]], "only our own old one makes room"
    lines = [line for line in capsys.readouterr().err.splitlines() if line]
    assert len(lines) == 1 and "certificate.json" in lines[0], "one line says why"


def test_a_certificate_cache_that_cannot_be_opened_is_not_a_reason_to_revoke(
    portal, tmp_path, monkeypatch
):
    """A backup or indexer tool holding the file open is not "no certificate"."""
    fake = portal([OURS])
    secure_store.write_json(tmp_path / "certificate.json", {"serial": OURS["serialNumber"]})
    real = Path.read_bytes

    def locked(self):
        if self.name == "certificate.json":
            raise PermissionError("used by another process")
        return real(self)

    monkeypatch.setattr(Path, "read_bytes", locked)

    with pytest.raises(PermissionError):
        provision._ensure_certificate(TEAM, None)

    assert fake.revoked == [], "the certificate that is still good stays"
    assert fake.issued is None


@pytest.mark.parametrize("content", ["not json", "[1, 2]"])
def test_a_damaged_certificate_cache_is_treated_as_missing(portal, tmp_path, content):
    portal([OURS])
    (tmp_path / "certificate.json").write_text(content, encoding="utf-8")

    assert provision._ensure_certificate(TEAM, None)[2] == "NEWLYISSUED0001"


def test_an_unreadable_bundle_is_reported_as_no_bundle(monkeypatch, tmp_path):
    monkeypatch.setattr(paths, "signing_dir", lambda _slug=None: tmp_path)
    monkeypatch.setattr(gsa, "load_session", lambda *a, **k: {"email": None})
    _unreadable(monkeypatch, tmp_path / "bundle.json")

    with pytest.raises(gsa.GsaError, match="no signing bundle"):
        provision.load_bundle()


@pytest.fixture
def provisioning(monkeypatch, tmp_path):
    """ensure_signing_assets with Apple stubbed; returns the passwords build_p12 saw."""
    seen: list[str] = []
    monkeypatch.setattr(paths, "signing_dir", lambda _slug=None: tmp_path)
    monkeypatch.setattr(gsa, "load_session", lambda *a, **k: {"email": None})
    monkeypatch.setattr(developer, "list_teams", lambda: [{"teamId": TEAM, "name": "T"}])
    monkeypatch.setattr(
        provision, "_ensure_certificate", lambda *_a: (b"key", b"der", "S1", "PASSWORD-OF-S1")
    )
    monkeypatch.setattr(provision, "_ensure_device", lambda *_a: None)
    monkeypatch.setattr(provision, "_ensure_app_id", lambda *_a: {"appIdId": "APPID"})
    monkeypatch.setattr(
        developer, "download_profile", lambda *_a: {"encodedProfile": b"profile"}
    )
    monkeypatch.setattr(
        signing, "build_p12", lambda _der, _key, password: seen.append(password) or b"p12"
    )
    return seen


def test_the_identity_uses_its_certificates_password_kept_only_in_the_protected_bundle(
    provisioning, tmp_path
):
    first = provision.ensure_signing_assets("com.a", "UDID")
    second = provision.ensure_signing_assets("com.a", "UDID")

    assert provisioning == ["PASSWORD-OF-S1", "PASSWORD-OF-S1"], "not one per write"
    assert first["p12_password"] == second["p12_password"] == "PASSWORD-OF-S1"
    raw = (tmp_path / "bundle.json").read_bytes()
    assert raw.startswith(secure_store.MAGIC)
    assert secure_store.read_json(tmp_path / "bundle.json") == second
    assert provision.load_bundle() == second


def test_the_identity_is_swapped_in_whole_before_the_bundle_naming_its_password(
    provisioning, tmp_path, monkeypatch
):
    swapped: list[str] = []
    real = secure_store.replace_atomic

    def record(src, dst):
        swapped.append(Path(dst).name)
        real(src, dst)

    monkeypatch.setattr(secure_store, "replace_atomic", record)

    provision.ensure_signing_assets("com.a", "UDID")

    assert swapped == ["identity.p12", "profile.mobileprovision", "bundle.json"]
    assert (tmp_path / "identity.p12").read_bytes() == b"p12"
    assert not list(tmp_path.glob("*.tmp")), "no temp file left behind"


def test_provisioning_holds_the_engine_lock(provisioning, monkeypatch):
    from ipaside_engine import refresh

    depth: list[int] = []
    monkeypatch.setattr(
        provision, "_ensure_device", lambda *_a: depth.append(refresh._lock_depth)
    )

    provision.ensure_signing_assets("com.a", "UDID")

    assert depth == [1], "it writes the signing folder another process may sign from"


def test_a_legacy_plaintext_bundle_is_read_but_not_rewritten_outside_the_lock(
    monkeypatch, tmp_path
):
    """Only ensure_signing_assets, under the lock, writes bundle.json."""
    monkeypatch.setattr(paths, "signing_dir", lambda _slug=None: tmp_path)
    monkeypatch.setattr(gsa, "load_session", lambda *a, **k: {"email": None})
    legacy = {"team_id": TEAM, "p12_password": "iPASide"}
    (tmp_path / "bundle.json").write_text(json.dumps(legacy), encoding="utf-8")

    assert provision.load_bundle() == legacy
    assert not (tmp_path / "bundle.json").read_bytes().startswith(secure_store.MAGIC)
