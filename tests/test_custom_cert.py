"""Importing a seller's .p12 + .mobileprovision and signing with it (E/custom_cert.py).

Everything here is generated on the fly: throwaway keys, certificates and profiles.
"""

import datetime
import plistlib
from pathlib import Path
import shutil
import subprocess
import threading
import time

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

from ipaside_engine import custom_cert, paths, refresh, secure_store, signing

PASSWORD = "seller-pass-Zq81"
UDID = "00008110-001234567890801E"
TEAM = "ABCDE12345"
NOW = datetime.datetime.now(datetime.timezone.utc)
DAY = datetime.timedelta(days=1)


class Identity:
    def __init__(self, days_valid=300, cn="iPhone Distribution: Test Seller (ABCDE12345)"):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
        self.cert = (
            x509.CertificateBuilder()
            .subject_name(name)
            .issuer_name(name)
            .public_key(self.key.public_key())
            .serial_number(0xABC123)
            .not_valid_before(NOW - 10 * DAY)
            .not_valid_after(NOW + days_valid * DAY if days_valid > 0 else NOW - DAY)
            .sign(self.key, hashes.SHA256())
        )
        self.der = self.cert.public_bytes(serialization.Encoding.DER)


def p12_bytes(identity, password=PASSWORD, legacy=False, key=True):
    if legacy:
        encryption = (
            serialization.PrivateFormat.PKCS12.encryption_builder()
            .kdf_rounds(2048)
            .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
            .hmac_hash(hashes.SHA1())
            .build(password.encode())
        )
    else:
        encryption = serialization.BestAvailableEncryption(password.encode())
    return pkcs12.serialize_key_and_certificates(
        b"seller", identity.key if key else None, identity.cert, None, encryption
    )


def profile_bytes(identity, app_id=f"{TEAM}.*", devices=(UDID,), days=300, all_devices=False, certs=None):
    entitlements = {"application-identifier": app_id, "get-task-allow": False}
    body = {
        "Name": "Seller profile",
        "TeamName": "Test Seller",
        "TeamIdentifier": [TEAM],
        "ExpirationDate": (NOW + days * DAY).replace(tzinfo=None),
        "DeveloperCertificates": [identity.der] if certs is None else certs,
        "Entitlements": entitlements,
    }
    if all_devices:
        body["ProvisionsAllDevices"] = True
    else:
        body["ProvisionedDevices"] = list(devices)
    # a fake CMS wrapper around the XML plist, as in a real .mobileprovision
    return b"\x30\x82\x0f\xa0junk" + plistlib.dumps(body) + b"\x00trailer"


@pytest.fixture
def files(tmp_path):
    def make(identity=None, *, p12=None, profile=None, password=PASSWORD):
        identity = identity or Identity()
        p12_file = tmp_path / "seller.p12"
        profile_file = tmp_path / "seller.mobileprovision"
        p12_file.write_bytes(p12 if p12 is not None else p12_bytes(identity, password))
        profile_file.write_bytes(profile if profile is not None else profile_bytes(identity))
        return p12_file, profile_file

    return make


def do_import(files, identity=None, **kw):
    identity = identity or Identity()
    password = kw.pop("password", PASSWORD)
    p12_file, profile_file = files(identity, password=password, **kw)
    return custom_cert.import_certificate(p12_file, password, profile_file)


# --- import: happy path and the facts ---------------------------------------------------


def test_nothing_imported_yet():
    assert custom_cert.status() is None
    assert custom_cert.active() is False
    assert custom_cert.remove() is False


def test_import_returns_the_facts(files):
    identity = Identity(days_valid=200)
    info = do_import(files, identity, profile=profile_bytes(identity, days=100))
    assert set(info) == {
        "name", "team_id", "team_name", "serial", "fingerprint", "certificate_expires", "profile_name",
        "profile_expires", "expires", "app_id", "wildcard", "all_devices", "device_count", "imported_at",
    }
    assert info["name"] == "iPhone Distribution: Test Seller (ABCDE12345)"
    assert info["team_id"] == TEAM
    assert info["team_name"] == "Test Seller"
    assert info["serial"] == "ABC123"
    assert info["fingerprint"] == __import__("hashlib").sha1(identity.der).hexdigest()
    assert info["profile_name"] == "Seller profile"
    assert info["app_id"] == f"{TEAM}.*"
    assert info["wildcard"] is True
    assert info["all_devices"] is False
    assert info["device_count"] == 1
    for key in ("certificate_expires", "profile_expires", "expires", "imported_at"):
        assert info[key].endswith("Z") and len(info[key]) == 20
    assert info["expires"] == info["profile_expires"]  # the profile ends first
    assert info["profile_expires"] < info["certificate_expires"]


def test_expires_is_the_certificate_when_it_ends_first(files):
    identity = Identity(days_valid=50)
    info = do_import(files, identity, profile=profile_bytes(identity, days=100))
    assert info["expires"] == info["certificate_expires"]


def test_explicit_app_id_is_not_a_wildcard(files):
    identity = Identity()
    info = do_import(files, identity, profile=profile_bytes(identity, app_id=f"{TEAM}.com.x.y"))
    assert info["wildcard"] is False


def test_all_devices_profile(files):
    identity = Identity()
    info = do_import(files, identity, profile=profile_bytes(identity, all_devices=True))
    assert info["all_devices"] is True
    assert info["device_count"] == 0


def test_profile_listing_the_sha256_of_the_certificate_matches(files):
    identity = Identity()
    digest = hashes.Hash(hashes.SHA256())
    digest.update(identity.der)
    info = do_import(files, identity, profile=profile_bytes(identity, certs=[digest.finalize()]))
    assert info["serial"] == "ABC123"


def test_legacy_3des_p12_loads(files):
    identity = Identity()
    info = do_import(files, identity, p12=p12_bytes(identity, legacy=True))
    assert info["serial"] == "ABC123"


def test_legacy_rc2_40_p12_loads(tmp_path, files):
    openssl = shutil.which("openssl")
    if not openssl:
        pytest.skip("openssl not available to build an RC2-40 p12")
    identity = Identity()
    key_pem = tmp_path / "k.pem"
    cert_pem = tmp_path / "c.pem"
    key_pem.write_bytes(
        identity.key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
        )
    )
    cert_pem.write_bytes(identity.cert.public_bytes(serialization.Encoding.PEM))
    out = tmp_path / "rc2.p12"
    run = subprocess.run(
        [
            openssl, "pkcs12", "-export", "-legacy", "-inkey", str(key_pem), "-in", str(cert_pem),
            "-out", str(out), "-passout", f"pass:{PASSWORD}", "-certpbe", "PBE-SHA1-RC2-40",
            "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1",
        ],
        capture_output=True,
    )
    if run.returncode != 0:
        pytest.skip("this openssl cannot build an RC2-40 p12")
    info = do_import(files, identity, p12=out.read_bytes())
    assert info["serial"] == "ABC123"


def test_empty_password_p12_loads(files):
    identity = Identity()
    p12 = pkcs12.serialize_key_and_certificates(b"s", identity.key, identity.cert, None, serialization.NoEncryption())
    p12_file, profile_file = files(identity, p12=p12)
    assert custom_cert.import_certificate(p12_file, "", profile_file)["serial"] == "ABC123"


# --- storage ----------------------------------------------------------------------------


def test_stored_p12_has_a_new_random_password_and_the_original_is_stored_nowhere(files):
    identity = Identity()
    do_import(files, identity)
    folder = paths.data_dir() / "custom-certificate"
    assert {p.name for p in folder.iterdir()} == {"identity.p12", "profile.mobileprovision", "certificate.json"}
    stored = secure_store.read_json(folder / "certificate.json")
    new_password = stored["p12_password"]
    assert new_password != PASSWORD and len(new_password) >= 32
    p12 = (folder / "identity.p12").read_bytes()
    key, cert, _ = pkcs12.load_key_and_certificates(p12, new_password.encode())
    assert key is not None and cert.serial_number == 0xABC123
    with pytest.raises(ValueError):
        pkcs12.load_key_and_certificates(p12, PASSWORD.encode())
    for path in folder.iterdir():
        assert PASSWORD.encode() not in path.read_bytes(), path.name
    # nothing else under the data folder keeps it either
    for path in paths.data_dir().rglob("*"):
        if path.is_file():
            assert PASSWORD.encode() not in path.read_bytes(), path


def test_certificate_json_is_protected_and_the_profile_is_a_byte_copy(files):
    identity = Identity()
    raw_profile = profile_bytes(identity)
    do_import(files, identity, profile=raw_profile)
    folder = paths.data_dir() / "custom-certificate"
    raw = (folder / "certificate.json").read_bytes()
    assert raw.startswith(secure_store.MAGIC)
    stored = secure_store.read_json(folder / "certificate.json")
    assert set(stored) == {"p12_password", "info"}
    assert (folder / "profile.mobileprovision").read_bytes() == raw_profile


def test_a_second_import_replaces_the_first(files):
    first, second = Identity(), Identity(cn="Second Seller")
    do_import(files, first)
    do_import(files, second)
    assert custom_cert.status()["name"] == "Second Seller"
    assert not [p for p in paths.data_dir().iterdir() if p.name.startswith("custom-certificate.")]


def test_a_failed_import_keeps_the_previous_certificate(files):
    do_import(files, Identity(cn="Keep Me"))
    with pytest.raises(custom_cert.CustomCertError):
        do_import(files, Identity(), password="x", p12=b"garbage")
    assert custom_cert.status()["name"] == "Keep Me"


def test_a_failed_swap_restores_the_previous_certificate(files, monkeypatch):
    do_import(files, Identity(cn="Keep Me"))
    real = secure_store.replace_atomic

    def flaky(src, dst):
        if dst.name == "custom-certificate" and src.name.endswith(".new"):  # the new folder into place
            raise PermissionError("locked")
        real(src, dst)

    monkeypatch.setattr(secure_store, "replace_atomic", flaky)
    with pytest.raises(custom_cert.CustomCertError, match="could not be updated"):
        do_import(files, Identity(cn="New"))
    monkeypatch.setattr(secure_store, "replace_atomic", real)
    assert custom_cert.status()["name"] == "Keep Me"
    assert not [p for p in paths.data_dir().iterdir() if p.name.startswith("custom-certificate.")]


# --- validation errors ------------------------------------------------------------------


def expect_error(files, fragment, identity=None, **kw):
    with pytest.raises(custom_cert.CustomCertError) as raised:
        do_import(files, identity, **kw)
    assert fragment in str(raised.value)
    assert PASSWORD not in str(raised.value)
    assert custom_cert.status() is None
    return raised.value


def test_wrong_password(files):
    identity = Identity()
    p12_file, profile_file = files(identity)
    with pytest.raises(custom_cert.CustomCertError) as raised:
        custom_cert.import_certificate(p12_file, "not-the-password", profile_file)
    assert "password" in str(raised.value)
    assert "not-the-password" not in str(raised.value)


def test_unreadable_p12(files):
    expect_error(files, "password is wrong, or the .p12 file is damaged", p12=b"not a p12 at all")


def test_p12_without_a_private_key(files):
    identity = Identity()
    expect_error(files, "no private key", identity, p12=p12_bytes(identity, key=False))


def test_certificate_not_in_the_profile(files):
    identity = Identity()
    expect_error(files, "not listed in the provisioning profile", identity, profile=profile_bytes(identity, certs=[Identity().der]))


def test_profile_without_certificates(files):
    identity = Identity()
    expect_error(files, "not listed in the provisioning profile", identity, profile=profile_bytes(identity, certs=[]))


def test_expired_certificate(files):
    identity = Identity(days_valid=0)
    expect_error(files, "certificate has expired", identity)


def test_expired_profile(files):
    identity = Identity()
    expect_error(files, "profile has expired", identity, profile=profile_bytes(identity, days=-2))


def test_unreadable_profile(files):
    expect_error(files, "profile could not be read", profile=b"\x30\x82 not a profile")


def test_profile_without_an_app_id(files):
    identity = Identity()
    body = plistlib.dumps(
        {"ExpirationDate": (NOW + 10 * DAY).replace(tzinfo=None), "DeveloperCertificates": [identity.der], "Entitlements": {}}
    )
    expect_error(files, "no App ID", identity, profile=b"junk" + body)


def test_missing_file(tmp_path):
    with pytest.raises(custom_cert.CustomCertError, match="could not be read"):
        custom_cert.import_certificate(tmp_path / "nope.p12", PASSWORD, tmp_path / "nope.mobileprovision")


# --- status, active, remove -------------------------------------------------------------


def test_status_without_udid_has_no_device_verdict(files):
    do_import(files)
    result = custom_cert.status()
    assert result["device_ok"] is None
    assert result["name"] and result["serial"] == "ABC123"


def test_status_device_check(files):
    do_import(files)
    assert custom_cert.status(UDID)["device_ok"] is True
    assert custom_cert.status(UDID.lower().replace("-", ""))["device_ok"] is True
    assert custom_cert.status("00008030-000000000000001E")["device_ok"] is False


def test_all_devices_profile_accepts_any_udid(files):
    identity = Identity()
    do_import(files, identity, profile=profile_bytes(identity, all_devices=True))
    assert custom_cert.status("00008030-000000000000001E")["device_ok"] is True
    assert custom_cert.signing_bundle("a.b", "00008030-000000000000001E")["bundle_id"] == "a.b"


def test_active_then_removed(files):
    do_import(files)
    assert custom_cert.active() is True
    assert custom_cert.remove() is True
    assert custom_cert.active() is False
    assert custom_cert.status() is None
    assert not (paths.data_dir() / "custom-certificate").exists()
    assert custom_cert.remove() is False


def expire_stored():
    path = paths.data_dir() / "custom-certificate" / "certificate.json"
    data = secure_store.read_json(path)
    data["info"]["expires"] = "2020-01-01T00:00:00Z"
    secure_store.write_json(path, data)


def test_expired_certificate_is_not_active(files):
    do_import(files)
    expire_stored()
    assert custom_cert.active() is False
    assert custom_cert.status() is not None  # still shown, so the user sees it expired


def test_damaged_certificate_json_means_nothing_imported(files):
    do_import(files)
    (paths.data_dir() / "custom-certificate" / "certificate.json").write_bytes(secure_store.MAGIC + b"garbage")
    assert custom_cert.status() is None
    assert custom_cert.active() is False


# --- signing_bundle ---------------------------------------------------------------------


def test_signing_bundle_shape(files):
    identity = Identity()
    info = do_import(files, identity)
    bundle = custom_cert.signing_bundle("com.example.app", UDID)
    assert set(bundle) == {
        "p12_path", "p12_password", "profile_path", "team_id", "team_name", "bundle_id",
        "certificate_serial", "fingerprint", "expires_at",
    }
    assert bundle["team_id"] == TEAM and bundle["team_name"] == "Test Seller"
    assert bundle["certificate_serial"] == "ABC123"
    assert bundle["fingerprint"] == info["fingerprint"]
    assert bundle["expires_at"] == info["expires"]
    folder = paths.data_dir() / "custom-certificate"
    assert bundle["p12_path"] == str(folder / "identity.p12")
    assert bundle["profile_path"] == str(folder / "profile.mobileprovision")
    key, cert, _ = pkcs12.load_key_and_certificates(
        open(bundle["p12_path"], "rb").read(), bundle["p12_password"].encode()
    )
    assert key is not None and cert is not None
    assert bundle["p12_password"] != PASSWORD


def test_signing_bundle_without_a_certificate():
    with pytest.raises(custom_cert.CustomCertError, match="No certificate is imported"):
        custom_cert.signing_bundle("a.b", UDID)


def test_signing_bundle_with_an_expired_certificate(files):
    do_import(files)
    expire_stored()
    with pytest.raises(custom_cert.CustomCertError, match="expired"):
        custom_cert.signing_bundle("a.b", UDID)


def test_signing_bundle_device_not_in_the_profile(files):
    do_import(files)
    with pytest.raises(custom_cert.CustomCertError) as raised:
        custom_cert.signing_bundle("a.b", "00008030-000000000000001E")
    assert str(raised.value) == (
        "This iPhone (UDID 00008030-000000000000001E) is not in the provisioning profile. "
        "Ask the seller to add it."
    )


def bundle_for(files, app_id, source, override=None):
    identity = Identity()
    do_import(files, identity, profile=profile_bytes(identity, app_id=app_id))
    return custom_cert.signing_bundle(source, UDID, override)["bundle_id"]


def test_explicit_app_id_always_wins(files):
    assert bundle_for(files, f"{TEAM}.com.seller.app", "com.other.thing") == "com.seller.app"
    assert bundle_for(files, f"{TEAM}.com.seller.app", "com.seller.app") == "com.seller.app"


def test_explicit_app_id_accepts_an_equal_override(files):
    assert bundle_for(files, f"{TEAM}.com.seller.app", "com.other.thing", "com.seller.app") == "com.seller.app"


def test_explicit_app_id_rejects_a_different_override(files):
    with pytest.raises(custom_cert.CustomCertError, match="only allows the bundle id com.seller.app"):
        bundle_for(files, f"{TEAM}.com.seller.app", "com.other.thing", "com.else.app")


def test_full_wildcard_keeps_the_ipa_id_or_the_override(files):
    assert bundle_for(files, f"{TEAM}.*", "com.other.thing") == "com.other.thing"
    assert bundle_for(files, f"{TEAM}.*", "com.other.thing", "my.custom.id") == "my.custom.id"


def test_prefix_wildcard_keeps_an_id_that_starts_with_the_prefix(files):
    assert bundle_for(files, f"{TEAM}.com.seller.*", "com.seller.app") == "com.seller.app"


def test_prefix_wildcard_prepends_the_prefix_otherwise(files):
    assert bundle_for(files, f"{TEAM}.com.seller.*", "com.other.thing") == "com.seller.com.other.thing"
    # the bare prefix without the dot is not "starting with p."
    assert bundle_for(files, f"{TEAM}.com.seller.*", "com.seller") == "com.seller.com.seller"


def test_prefix_wildcard_override_must_fit(files):
    assert bundle_for(files, f"{TEAM}.com.seller.*", "com.other.thing", "com.seller.mine") == "com.seller.mine"
    with pytest.raises(custom_cert.CustomCertError, match="does not fit the provisioning profile's App ID"):
        bundle_for(files, f"{TEAM}.com.seller.*", "com.other.thing", "com.else.mine")


# --- crash recovery, leftovers, and errors that are not the user's input ------------------


def leftovers():
    return sorted(p.name for p in paths.data_dir().iterdir() if p.name.startswith("custom-certificate"))


def kill_between_the_renames(files, monkeypatch):
    """A real kill: the first rename (folder -> .old) happens, nothing after it runs."""
    real = secure_store.replace_atomic
    calls = []

    def dying(src, dst):
        if not dst.name.startswith("custom-certificate"):  # certificate.json's own temp file
            return real(src, dst)
        calls.append(dst.name)
        if len(calls) > 1:
            raise SystemExit("killed")  # also the swap's own restore dies
        real(src, dst)

    do_import(files, Identity(cn="Keep Me"))
    monkeypatch.setattr(secure_store, "replace_atomic", dying)
    with pytest.raises(SystemExit):
        do_import(files, Identity(cn="New"))
    monkeypatch.setattr(secure_store, "replace_atomic", real)


def test_kill_between_the_renames_is_seen_by_status_and_active(files, monkeypatch):
    kill_between_the_renames(files, monkeypatch)
    assert not (paths.data_dir() / "custom-certificate").exists()
    assert (paths.data_dir() / "custom-certificate.old").exists()
    assert custom_cert.status()["name"] == "Keep Me"
    assert custom_cert.active() is True
    assert custom_cert.status(UDID)["device_ok"] is True


def test_kill_between_the_renames_signing_bundle_puts_the_old_one_back(files, monkeypatch):
    kill_between_the_renames(files, monkeypatch)
    bundle = custom_cert.signing_bundle("a.b", UDID)
    folder = paths.data_dir() / "custom-certificate"
    assert bundle["p12_path"] == str(folder / "identity.p12") and (folder / "identity.p12").is_file()
    assert leftovers() == ["custom-certificate"]
    assert custom_cert.status()["name"] == "Keep Me"


def test_kill_between_the_renames_then_a_new_import_works_and_cleans_up(files, monkeypatch):
    kill_between_the_renames(files, monkeypatch)
    do_import(files, Identity(cn="Second"))
    assert custom_cert.status()["name"] == "Second"
    assert leftovers() == ["custom-certificate"]


def make_crash_leftovers():
    """What a kill leaves: a half-finished stage and an old folder with a seller key in them."""
    for name in ("custom-certificate.old", "custom-certificate.abc123.new"):
        folder = paths.data_dir() / name
        folder.mkdir()
        (folder / "identity.p12").write_bytes(b"seller key")
        (folder / "certificate.json").write_bytes(b"x")


def test_remove_after_a_crash_leaves_no_custom_certificate_entry(files):
    do_import(files)
    make_crash_leftovers()
    assert custom_cert.remove() is True
    assert leftovers() == []
    assert custom_cert.status() is None


def test_remove_with_only_a_stage_deletes_it(files):
    make_crash_leftovers()
    shutil.rmtree(paths.data_dir() / "custom-certificate.old")
    assert custom_cert.remove() is False  # no certificate, but no seller key stays either
    assert leftovers() == []


def test_remove_after_a_kill_between_the_renames(files, monkeypatch):
    kill_between_the_renames(files, monkeypatch)
    assert custom_cert.remove() is True
    assert leftovers() == []
    assert custom_cert.active() is False


def test_import_deletes_old_stage_leftovers(files):
    make_crash_leftovers()
    do_import(files)
    assert leftovers() == ["custom-certificate"]


def test_first_import_crash_leftovers_are_cleaned_by_the_next_status(files):
    make_crash_leftovers()  # a kill during the very first import: only a stage (and no live folder)
    shutil.rmtree(paths.data_dir() / "custom-certificate.old")
    assert leftovers() == ["custom-certificate.abc123.new"]
    assert custom_cert.status() is None
    assert leftovers() == []


def test_first_import_crash_leftovers_are_cleaned_by_the_next_active(files):
    make_crash_leftovers()
    shutil.rmtree(paths.data_dir() / "custom-certificate.old")
    assert custom_cert.active() is False
    assert leftovers() == []


def test_status_cleans_leftovers_beside_a_good_certificate(files):
    do_import(files, Identity(cn="Keep Me"))
    make_crash_leftovers()
    assert custom_cert.status()["name"] == "Keep Me"
    assert leftovers() == ["custom-certificate"]


def test_status_logs_a_failed_cleanup_without_raising_or_leaking(files, monkeypatch, capfd):
    do_import(files, Identity(cn="Keep Me"))
    make_crash_leftovers()

    def locked(path, *args, **kwargs):
        raise PermissionError(13, "Access is denied")

    monkeypatch.setattr(custom_cert.shutil, "rmtree", locked)
    assert custom_cert.status()["name"] == "Keep Me"
    assert custom_cert.active() is True
    err = capfd.readouterr().err
    assert "were not cleaned up" in err and "Access is denied" in err
    assert PASSWORD not in err and "seller key" not in err
    assert leftovers() != ["custom-certificate"]  # still there: the warning is the report


def test_status_and_active_never_wait_for_the_lock_and_keep_the_leftovers(files, monkeypatch, capfd):
    do_import(files, Identity(cn="Keep Me"))
    make_crash_leftovers()
    timeouts = []

    def held_elsewhere(timeout):  # another process holds the file lock
        timeouts.append(timeout)
        raise refresh._busy()

    with monkeypatch.context() as held:
        held.setattr(refresh, "_acquire_file_lock", held_elsewhere)
        assert custom_cert.status()["name"] == "Keep Me"
        assert custom_cert.active() is True
        assert timeouts == [0.0, 0.0]  # tried without waiting, twice, never the 600 s timeout
        assert sorted(leftovers()) == ["custom-certificate", "custom-certificate.abc123.new", "custom-certificate.old"]
        assert "were not cleaned up" not in capfd.readouterr().err  # busy is not a failure to report
    assert custom_cert.status()["name"] == "Keep Me"  # the next call, lock free, cleans up
    assert leftovers() == ["custom-certificate"]


def test_signing_bundle_goes_on_when_a_stale_stage_cannot_be_deleted(files, monkeypatch, capfd):
    do_import(files, Identity(cn="Keep Me"))
    make_crash_leftovers()

    def locked(path, *args, **kwargs):
        raise PermissionError(13, "Access is denied")

    monkeypatch.setattr(custom_cert.shutil, "rmtree", locked)
    bundle = custom_cert.signing_bundle("a.b", UDID)
    assert bundle["p12_path"] == str(paths.data_dir() / "custom-certificate" / "identity.p12")
    err = capfd.readouterr().err
    assert "were not cleaned up" in err and "Access is denied" in err
    assert PASSWORD not in err and "seller key" not in err
    assert leftovers() != ["custom-certificate"]


def test_signing_bundle_raises_when_the_previous_certificate_cannot_be_put_back(files, monkeypatch):
    kill_between_the_renames(files, monkeypatch)

    def refused(src, dst):
        raise PermissionError(13, "Access is denied")

    monkeypatch.setattr(secure_store, "replace_atomic", refused)
    with pytest.raises(custom_cert.CustomCertError, match="could not be updated"):
        custom_cert.signing_bundle("a.b", UDID)


def test_import_reports_a_failed_cleanup(files, monkeypatch):
    make_crash_leftovers()

    def locked(path, *args, **kwargs):
        raise PermissionError(13, "Access is denied")

    monkeypatch.setattr(custom_cert.shutil, "rmtree", locked)
    with pytest.raises(custom_cert.CustomCertError, match="could not be updated"):
        do_import(files)


def test_remove_killed_mid_way_leaves_nothing_usable_and_the_next_status_cleans_it(files, monkeypatch):
    do_import(files)
    real = custom_cert.shutil.rmtree

    def killed(path, *args, **kwargs):
        raise SystemExit("killed")  # the process dies before deleting anything

    monkeypatch.setattr(custom_cert.shutil, "rmtree", killed)
    with pytest.raises(SystemExit):
        custom_cert.remove()
    monkeypatch.setattr(custom_cert.shutil, "rmtree", real)
    assert not (paths.data_dir() / "custom-certificate").exists()
    names = leftovers()
    assert len(names) == 1 and names[0].endswith(".new")  # the identity waits under a stage name
    assert custom_cert.active() is False  # status()/active() never read a stage ...
    assert leftovers() == []  # ... and the call cleaned it
    assert custom_cert.status() is None


def test_remove_killed_mid_way_then_remove_cleans_it(files, monkeypatch):
    do_import(files)
    real = custom_cert.shutil.rmtree

    def killed(path, *args, **kwargs):
        raise SystemExit("killed")

    monkeypatch.setattr(custom_cert.shutil, "rmtree", killed)
    with pytest.raises(SystemExit):
        custom_cert.remove()
    monkeypatch.setattr(custom_cert.shutil, "rmtree", real)
    assert custom_cert.remove() is False
    assert leftovers() == []


def test_remove_killed_between_its_renames_keeps_the_certificate_usable_and_a_second_remove_finishes(files, monkeypatch):
    do_import(files, Identity(cn="Keep Me"))
    make_crash_leftovers()  # a .old and a stage beside the live folder
    real = secure_store.replace_atomic
    calls = []

    def dying(src, dst):
        if not dst.name.startswith("custom-certificate"):
            return real(src, dst)
        calls.append(dst.name)
        if len(calls) > 1:
            raise SystemExit("killed")
        real(src, dst)

    monkeypatch.setattr(secure_store, "replace_atomic", dying)
    with pytest.raises(SystemExit):
        custom_cert.remove()
    monkeypatch.setattr(secure_store, "replace_atomic", real)
    assert (paths.data_dir() / "custom-certificate").exists()  # not removed yet, never "half"
    assert custom_cert.remove() is True
    assert leftovers() == []


def test_key_that_does_not_match_its_certificate(files, monkeypatch):
    identity, other = Identity(), Identity()
    # the seller's p12 as the loader reports it: a key that is not the certificate's
    monkeypatch.setattr(pkcs12, "load_key_and_certificates", lambda data, secret: (other.key, identity.cert, []))
    expect_error(files, "does not belong to its certificate", identity)


def test_os_error_while_saving_is_a_custom_cert_error(files, monkeypatch):
    do_import(files, Identity(cn="Keep Me"))

    def full(*args, **kwargs):
        raise OSError(28, "No space left on device")

    real = custom_cert._write
    monkeypatch.setattr(custom_cert, "_write", full)
    with pytest.raises(custom_cert.CustomCertError, match="No space left on device"):
        do_import(files, Identity(cn="New"))
    monkeypatch.setattr(custom_cert, "_write", real)
    assert custom_cert.status()["name"] == "Keep Me"
    assert leftovers() == ["custom-certificate"]


def test_os_error_while_removing_is_a_custom_cert_error(files, monkeypatch):
    do_import(files)

    def locked(path, *args, **kwargs):
        raise PermissionError(13, "Access is denied")

    monkeypatch.setattr(custom_cert.shutil, "rmtree", locked)
    with pytest.raises(custom_cert.CustomCertError, match="could not be updated"):
        custom_cert.remove()


def test_files_are_synced_to_disk_before_the_folder_goes_live(files, monkeypatch):
    synced = []
    real = custom_cert.os.fsync
    monkeypatch.setattr(custom_cert.os, "fsync", lambda fd: (synced.append(fd), real(fd))[1])
    do_import(files)
    assert len(synced) >= 2  # identity.p12 and the profile


def test_remove_also_sweeps_the_signing_temp_folder(files, monkeypatch):
    calls = []
    monkeypatch.setattr(signing, "sweep_signing_temp", lambda: calls.append("swept"))
    assert custom_cert.remove() is False  # nothing imported: the sweep still runs
    do_import(files)
    assert custom_cert.remove() is True
    assert calls == ["swept", "swept"]


def test_import_succeeds_when_the_replaced_certificate_cannot_be_deleted(files, monkeypatch, capfd):
    do_import(files, Identity(cn="Old One"))
    real = custom_cert.shutil.rmtree

    def locked(path, *args, **kwargs):
        if not str(path).endswith(".old") or not Path(path).exists():
            return real(path, *args, **kwargs)
        raise PermissionError(13, "Access is denied")  # e.g. antivirus holds the old p12 open

    monkeypatch.setattr(custom_cert.shutil, "rmtree", locked)
    info = do_import(files, Identity(cn="New One"), password="other-pass")
    assert info["name"] == "New One"  # the new certificate is live: success, not an error
    err = capfd.readouterr().err
    assert "were not cleaned up" in err and "Access is denied" in err
    assert PASSWORD not in err and "other-pass" not in err
    assert "custom-certificate.old" in leftovers()
    monkeypatch.setattr(custom_cert.shutil, "rmtree", real)
    assert custom_cert.status()["name"] == "New One"  # status() heals the leftover
    assert leftovers() == ["custom-certificate"]


def _hold_the_lock():
    """Another holder of the operation lock (a headless refresh, say); returns a release callable."""
    held, release = threading.Event(), threading.Event()

    def hold():
        with refresh.operation_lock():
            held.set()
            release.wait(10)

    holder = threading.Thread(target=hold)
    holder.start()
    assert held.wait(10)

    def done():
        release.set()
        holder.join()

    return done


def test_import_and_remove_answer_a_busy_lock_at_once(files, monkeypatch):
    monkeypatch.setattr(refresh, "LOCK_TIMEOUT_SECONDS", 30.0)  # a wait would blow the time check below
    p12_file, profile_file = files()
    done = _hold_the_lock()
    try:
        started = time.monotonic()
        with pytest.raises(refresh.OperationBusy):
            custom_cert.import_certificate(p12_file, PASSWORD, profile_file)
        with pytest.raises(refresh.OperationBusy):
            custom_cert.remove()
        assert time.monotonic() - started < 5
    finally:
        done()
    assert custom_cert.status() is None  # neither call touched anything
    do_import(files)  # the lock is free again


def test_remove_sweeps_signing_temp_even_when_a_stage_cannot_be_deleted(files, monkeypatch):
    do_import(files)
    calls = []
    monkeypatch.setattr(signing, "sweep_signing_temp", lambda: calls.append("swept"))

    def locked(path, *args, **kwargs):
        raise PermissionError(13, "Access is denied")

    monkeypatch.setattr(custom_cert.shutil, "rmtree", locked)
    with pytest.raises(custom_cert.CustomCertError, match="could not be updated"):
        custom_cert.remove()
    assert calls == ["swept"]
