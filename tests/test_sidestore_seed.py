"""Baking iPASide's certificate into the bundled SideStore.

SideStore imports a certificate it finds in its own framework on first launch, which is
how iPASide can pre-seed it with the same identity that signs LiveContainer - no separate
Apple ID sign-in, and no way to fork a second LiveContainer under a different account.

The exact shape is a contract with SideStore (and with iLoader's isideload, which writes
the same files): ALTCertificate.p12 inside SideStoreApp.framework, encrypted with the
certificate's Apple machineId, plus ALTCertificateID and ALTAppGroups in its Info.plist.
These tests pin every part of that, hermetically - a throwaway self-signed identity and a
synthetic bundle, no device, no Apple.
"""

from __future__ import annotations

import plistlib
import zipfile
from pathlib import Path

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

from ipaside_engine import livecontainer, provision, signing

TEAM = "ASK9QR9SBC"
SERIAL = "29C8EC73C890EBCA0EE74E017975D97B"
MACHINE_ID = "1ecfcd29-cce4-40f6-b653-471ecd342381"


def _identity() -> tuple[bytes, bytes]:
    """A throwaway RSA key + self-signed cert, as (key_pem, cert_der)."""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "iOS Development: Test")])
    import datetime

    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(int(SERIAL, 16))
        .not_valid_before(datetime.datetime(2026, 1, 1))
        .not_valid_after(datetime.datetime(2027, 1, 1))
        .sign(key, hashes.SHA256())
    )
    key_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    )
    return key_pem, cert.public_bytes(serialization.Encoding.DER)


def _sidestore_ipa(path: Path, *, with_framework: bool = True) -> Path:
    """A minimal LiveContainer+SideStore-shaped IPA."""
    app = "Payload/LiveContainer.app"
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr(f"{app}/Info.plist", plistlib.dumps({"CFBundleIdentifier": "com.kdt.livecontainer"}))
        zf.writestr(f"{app}/LiveContainer", b"\xcf\xfa\xed\xfe main")
        if with_framework:
            fw = f"{app}/Frameworks/{livecontainer.SIDESTORE_FRAMEWORK}"
            zf.writestr(
                f"{fw}/Info.plist",
                plistlib.dumps({"CFBundleIdentifier": "com.SideStore.SideStore", "CFBundleName": "SideStore"}),
            )
            zf.writestr(f"{fw}/SideStore", b"\xcf\xfa\xed\xfe sidestore")
    return path


@pytest.fixture
def seeded(monkeypatch, tmp_path):
    """Run the seeding against the synthetic bundle and return (ipa, framework prefix)."""
    key_pem, cert_der = _identity()
    monkeypatch.setattr(provision, "signing_identity", lambda: (key_pem, cert_der, SERIAL))
    monkeypatch.setattr(provision, "certificate_machine_id", lambda team, serial: MACHINE_ID)

    source = _sidestore_ipa(tmp_path / "LC+SS.ipa")
    dest = tmp_path / "out"
    dest.mkdir()
    result = livecontainer.seed_sidestore_certificate(
        str(source), {"team_id": TEAM}, str(dest)
    )
    fw = f"Payload/LiveContainer.app/Frameworks/{livecontainer.SIDESTORE_FRAMEWORK}"
    return result, fw


# --------------------------------------------------------------------------- #
# The files SideStore reads
# --------------------------------------------------------------------------- #
def test_the_certificate_lands_in_the_sidestore_framework(seeded):
    result, fw = seeded
    with zipfile.ZipFile(result) as zf:
        assert f"{fw}/{livecontainer.ALT_CERTIFICATE_FILE}" in zf.namelist()


def test_info_plist_names_the_certificate_and_the_app_group(seeded):
    result, fw = seeded
    with zipfile.ZipFile(result) as zf:
        info = plistlib.loads(zf.read(f"{fw}/Info.plist"))
    assert info["ALTCertificateID"] == SERIAL
    assert info["ALTAppGroups"] == [f"group.com.SideStore.SideStore.{TEAM}"]
    # The framework's own identity must survive - SideStore is still SideStore.
    assert info["CFBundleIdentifier"] == "com.SideStore.SideStore"


def test_the_p12_opens_with_the_machine_id(seeded):
    result, fw = seeded
    with zipfile.ZipFile(result) as zf:
        p12 = zf.read(f"{fw}/{livecontainer.ALT_CERTIFICATE_FILE}")

    key, cert, _ = pkcs12.load_key_and_certificates(p12, MACHINE_ID.encode())
    assert key is not None and cert is not None
    assert format(cert.serial_number, "X").upper() == SERIAL


def test_the_p12_rejects_any_other_password(seeded):
    """If the wrong password opened it, the encryption would be theatre."""
    result, fw = seeded
    with zipfile.ZipFile(result) as zf:
        p12 = zf.read(f"{fw}/{livecontainer.ALT_CERTIFICATE_FILE}")

    with pytest.raises(Exception):
        pkcs12.load_key_and_certificates(p12, b"not-the-machine-id")


def test_nothing_else_in_the_bundle_is_disturbed(seeded, tmp_path):
    """Exactly one file added, none removed - the rest of the app must be untouched."""
    result, _fw = seeded
    original = _sidestore_ipa(tmp_path / "orig.ipa")

    def files(p):
        with zipfile.ZipFile(p) as zf:
            return {n for n in zf.namelist() if not n.endswith("/")}

    before, after = files(original), files(result)
    added = after - before
    assert added == {
        f"Payload/LiveContainer.app/Frameworks/{livecontainer.SIDESTORE_FRAMEWORK}/"
        f"{livecontainer.ALT_CERTIFICATE_FILE}"
    }
    assert not (before - after), "no original file may be dropped"


# --------------------------------------------------------------------------- #
# When it should not run
# --------------------------------------------------------------------------- #
def test_a_build_without_sidestore_is_refused(monkeypatch, tmp_path):
    key_pem, cert_der = _identity()
    monkeypatch.setattr(provision, "signing_identity", lambda: (key_pem, cert_der, SERIAL))
    monkeypatch.setattr(provision, "certificate_machine_id", lambda t, s: MACHINE_ID)

    plain = _sidestore_ipa(tmp_path / "plain.ipa", with_framework=False)
    dest = tmp_path / "out"
    dest.mkdir()

    with pytest.raises(livecontainer.LiveContainerError, match="SideStore"):
        livecontainer.seed_sidestore_certificate(str(plain), {"team_id": TEAM}, str(dest))


def test_has_sidestore_detects_the_framework(tmp_path):
    with_ss = _sidestore_ipa(tmp_path / "with.ipa")
    without = _sidestore_ipa(tmp_path / "without.ipa", with_framework=False)
    assert livecontainer.has_sidestore(str(with_ss)) is True
    assert livecontainer.has_sidestore(str(without)) is False


# --------------------------------------------------------------------------- #
# The sideload pre-sign hook that drives it
# --------------------------------------------------------------------------- #
def test_pre_sign_hook_seeds_only_a_sidestore_livecontainer(monkeypatch, tmp_path):
    from ipaside_engine import sideload

    calls: list[str] = []
    monkeypatch.setattr(
        livecontainer,
        "seed_sidestore_certificate",
        lambda ipa, bundle, dest: calls.append(ipa) or f"{ipa}.seeded",
    )
    monkeypatch.setattr(livecontainer, "has_sidestore", lambda path: "withss" in path)

    withss = str(tmp_path / "withss.ipa")
    plain = str(tmp_path / "plain.ipa")
    bundle = {"team_id": TEAM}

    assert sideload._profile_pre_sign(
        livecontainer.SIGNING_PROFILE, withss, bundle, str(tmp_path)
    ) == f"{withss}.seeded"
    assert (
        sideload._profile_pre_sign(livecontainer.SIGNING_PROFILE, plain, bundle, str(tmp_path))
        is None
    )
    # An ordinary sideload never seeds anything.
    assert (
        sideload._profile_pre_sign(None, withss, bundle, str(tmp_path)) is None
    )
    assert calls == [withss]


def test_signing_identity_reads_the_active_account_cache(monkeypatch, tmp_path):
    """The material comes from the same cache the signing bundle uses."""
    import base64
    import json

    key_pem, cert_der = _identity()
    monkeypatch.setattr(provision.gsa, "load_session", lambda: {"email": "a@b.c"})
    monkeypatch.setattr(provision, "_account_slug", lambda email: "slug")
    monkeypatch.setattr(provision.paths, "signing_dir", lambda slug=None: tmp_path)
    (tmp_path / "certificate.json").write_text(
        json.dumps(
            {
                "serial": SERIAL,
                "key_pem": base64.b64encode(key_pem).decode(),
                "cert_der": base64.b64encode(cert_der).decode(),
            }
        )
    )

    got_key, got_cert, got_serial = provision.signing_identity()
    assert got_serial == SERIAL
    assert got_key == key_pem
    assert got_cert == cert_der


def test_machine_id_comes_from_apple_by_serial(monkeypatch):
    monkeypatch.setattr(
        provision.developer,
        "list_certificates",
        lambda team: [
            {"serialNumber": "OTHER", "machineId": "nope"},
            {"serialNumber": SERIAL, "machineId": MACHINE_ID},
        ],
    )
    assert provision.certificate_machine_id(TEAM, SERIAL) == MACHINE_ID


def test_a_missing_machine_id_is_an_error(monkeypatch):
    monkeypatch.setattr(
        provision.developer, "list_certificates", lambda team: [{"serialNumber": SERIAL}]
    )
    with pytest.raises(provision.gsa.GsaError, match="machine id"):
        provision.certificate_machine_id(TEAM, SERIAL)
