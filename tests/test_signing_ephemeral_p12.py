"""sign_ipa keeps the identity's long-lived password out of zsign's argv.

zsign gets a throwaway re-export under a one-time password, in data_dir()/signing-temp, that is
gone again after the run (a copy left by a killed engine is swept by the next sign). Keys and
certificates are generated on the fly.
"""

import datetime
from pathlib import Path

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

from ipaside_engine import paths, signing

PASSWORD = "long-lived-Zq81-secret"
NOW = datetime.datetime.now(datetime.timezone.utc)


def _identity():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test")])
    cert = (
        x509.CertificateBuilder()
        .subject_name(name).issuer_name(name).public_key(key.public_key())
        .serial_number(1)
        .not_valid_before(NOW - datetime.timedelta(days=1))
        .not_valid_after(NOW + datetime.timedelta(days=30))
        .sign(key, hashes.SHA256())
    )
    return key, cert


def _write_p12(path, legacy=False, password=PASSWORD):
    key, cert = _identity()
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
    path.write_bytes(pkcs12.serialize_key_and_certificates(b"seller", key, cert, None, encryption))
    return cert


class _Proc:
    def __init__(self, returncode=0):
        self.returncode, self.stdout, self.stderr = returncode, "", "boom" if returncode else ""


def _fake_zsign(monkeypatch, returncode=0):
    seen = {}
    monkeypatch.setattr(signing, "resolve_zsign", lambda: "zsign")

    def run(cmd, **_kwargs):
        seen["cmd"] = list(cmd)
        k, p = cmd[cmd.index("-k") + 1], cmd[cmd.index("-p") + 1]
        seen["p12"], seen["password"] = k, p
        with open(k, "rb") as handle:  # the file must exist and open with the argv password
            seen["loaded"] = pkcs12.load_key_and_certificates(handle.read(), p.encode())
        return _Proc(returncode)

    monkeypatch.setattr(signing.subprocess, "run", run)
    return seen


def _temp() -> Path:
    return paths.data_dir() / "signing-temp"


def _sign(scratch, p12):
    return signing.sign_ipa(
        "in.ipa", "out.ipa", p12_path=str(p12), p12_password=PASSWORD,
        profile_path="p.mobileprovision", temp_folder=str(scratch),
    )


@pytest.mark.parametrize("legacy", [False, True])
def test_zsign_argv_has_a_one_time_password_and_the_same_identity(monkeypatch, tmp_path, legacy):
    p12 = tmp_path / "identity.p12"
    cert = _write_p12(p12, legacy=legacy)  # legacy: 3DES input still has to work
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    seen = _fake_zsign(monkeypatch)

    _sign(scratch, p12)

    assert PASSWORD not in seen["cmd"]
    assert not any(PASSWORD in part for part in seen["cmd"])
    assert seen["password"] and seen["password"] != PASSWORD
    assert seen["p12"] != str(p12)
    assert _temp() in Path(seen["p12"]).parents  # inside signing-temp, not the scratch folder
    key, loaded_cert, _ = seen["loaded"]
    assert key is not None and loaded_cert.fingerprint(hashes.SHA1()) == cert.fingerprint(hashes.SHA1())
    assert list(_temp().iterdir()) == []  # the copy is gone after success
    assert list(scratch.iterdir()) == []  # and nothing was written to the scratch folder
    assert p12.exists()  # the original is untouched


def test_the_one_time_password_differs_each_time(monkeypatch, tmp_path):
    p12 = tmp_path / "identity.p12"
    _write_p12(p12)
    seen = _fake_zsign(monkeypatch)
    _sign(tmp_path, p12)
    first = seen["password"]
    _sign(tmp_path, p12)
    assert seen["password"] != first


def test_the_copy_is_removed_when_zsign_fails(monkeypatch, tmp_path):
    p12 = tmp_path / "identity.p12"
    _write_p12(p12)
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    seen = _fake_zsign(monkeypatch, returncode=1)

    with pytest.raises(signing.SigningError):
        _sign(scratch, p12)

    assert not any(PASSWORD in part for part in seen["cmd"])
    assert list(_temp().iterdir()) == []


def test_a_wrong_password_fails_before_zsign_runs_and_leaves_nothing(monkeypatch, tmp_path):
    p12 = tmp_path / "identity.p12"
    _write_p12(p12, password="another-password")
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    seen = _fake_zsign(monkeypatch)

    with pytest.raises(signing.SigningError, match="wrong password"):
        _sign(scratch, p12)

    assert "cmd" not in seen
    assert list(_temp().iterdir()) == []


def test_a_missing_identity_file_fails_before_zsign_and_never_passes_the_password(monkeypatch, tmp_path):
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    monkeypatch.setattr(signing, "resolve_zsign", lambda: "zsign")
    ran = []
    monkeypatch.setattr(signing.subprocess, "run", lambda cmd, **_k: ran.append(list(cmd)) or _Proc())

    with pytest.raises(signing.SigningError, match="certificate file is missing"):
        _sign(scratch, tmp_path / "missing.p12")

    assert ran == []  # zsign never ran, so the password never reached an argv
    assert list(_temp().iterdir()) == []


def test_the_copy_is_removed_when_zsign_cannot_be_started(monkeypatch, tmp_path):
    p12 = tmp_path / "identity.p12"
    _write_p12(p12)
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    monkeypatch.setattr(signing, "resolve_zsign", lambda: "zsign")

    def run(cmd, **_kwargs):
        raise FileNotFoundError("zsign")

    monkeypatch.setattr(signing.subprocess, "run", run)

    with pytest.raises(FileNotFoundError):
        _sign(scratch, p12)

    assert list(_temp().iterdir()) == []


def test_a_missing_scratch_folder_does_not_matter_for_the_copy(monkeypatch, tmp_path):
    p12 = tmp_path / "identity.p12"
    _write_p12(p12)
    seen = _fake_zsign(monkeypatch)

    _sign(tmp_path / "does-not-exist", p12)  # the copy lives in signing-temp, not in the scratch folder

    assert seen["password"] != PASSWORD
    assert _temp() in Path(seen["p12"]).parents
    assert not Path(seen["p12"]).exists()


def test_a_leftover_from_a_killed_run_is_swept_by_the_next_sign(monkeypatch, tmp_path):
    p12 = tmp_path / "identity.p12"
    _write_p12(p12)
    stale_dir = _temp() / "p12-killed"  # what a force-killed engine leaves behind
    stale_dir.mkdir(parents=True)
    (stale_dir / "identity.p12").write_bytes(b"stale")
    stale_file = _temp() / "loose.p12"
    stale_file.write_bytes(b"stale")
    seen = _fake_zsign(monkeypatch)

    _sign(tmp_path, p12)

    assert not stale_dir.exists() and not stale_file.exists()
    assert Path(seen["p12"]).parent != stale_dir
    assert list(_temp().iterdir()) == []


def test_an_undeletable_leftover_warns_and_signing_goes_on(monkeypatch, tmp_path, capsys):
    p12 = tmp_path / "identity.p12"
    _write_p12(p12)
    stuck = _temp() / "p12-stuck"
    stuck.mkdir(parents=True)
    seen = _fake_zsign(monkeypatch)
    real_rmtree = signing.shutil.rmtree

    def rmtree(path, *args, **kwargs):
        if Path(path) == stuck:
            raise PermissionError(13, "in use", str(path))
        return real_rmtree(path, *args, **kwargs)

    monkeypatch.setattr(signing.shutil, "rmtree", rmtree)

    result = _sign(tmp_path, p12)

    assert result["output"] == "out.ipa"  # signing went on
    assert seen["password"] != PASSWORD
    assert stuck.exists()  # still there; the next sign retries
    err = capsys.readouterr().err
    assert "could not delete a temporary signing file" in err
    assert PASSWORD not in err and seen["password"] not in err
    assert [e.name for e in _temp().iterdir()] == ["p12-stuck"]  # this sign's own copy is gone


def test_sweep_signing_temp_clears_the_folder_and_tolerates_a_missing_one():
    signing.sweep_signing_temp()  # no folder yet: no error
    (_temp() / "p12-a").mkdir(parents=True)
    (_temp() / "p12-a" / "identity.p12").write_bytes(b"x")
    (_temp() / "p12-b").write_bytes(b"x")

    signing.sweep_signing_temp()

    assert list(_temp().iterdir()) == []


def test_nothing_is_written_outside_signing_temp(monkeypatch, tmp_path):
    p12 = tmp_path / "identity.p12"
    _write_p12(p12)
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    data = paths.data_dir()
    before = {e for e in data.rglob("*")}
    seen = _fake_zsign(monkeypatch)

    _sign(scratch, p12)

    created = {e for e in data.rglob("*")} - before
    assert all(e == _temp() or _temp() in e.parents for e in created)
    assert list(scratch.iterdir()) == []
    assert _temp() in Path(seen["p12"]).parents
