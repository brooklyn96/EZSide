"""A signing identity the user imported: a seller's .p12, its password and a .mobileprovision.

While one is active, sideloads are signed with it instead of an Apple ID. The files live in
data_dir()/custom-certificate: ``identity.p12`` (re-exported here under a fresh random
password, so the seller's password is never kept), ``profile.mobileprovision`` (a byte copy)
and ``certificate.json`` (DPAPI-protected: the new password and the facts shown to the user).
"""

from __future__ import annotations

import datetime
import hashlib
import os
import plistlib
import secrets
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

from cryptography.exceptions import UnsupportedAlgorithm
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

from . import paths, secure_store, signing
from .errors import EngineError

FOLDER = "custom-certificate"
_P12 = "identity.p12"
_PROFILE = "profile.mobileprovision"
_JSON = "certificate.json"
_FRIENDLY_NAME = b"EZSide"


class CustomCertError(EngineError):
    """An imported certificate that cannot be used, with what to do about it."""


def _folder() -> Path:
    return paths.data_dir() / FOLDER


def _iso(moment: datetime.datetime) -> str:
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse(stamp: Any) -> datetime.datetime | None:
    try:
        moment = datetime.datetime.fromisoformat(stamp)
    except (TypeError, ValueError):
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=datetime.timezone.utc)


def _aware(moment: datetime.datetime) -> datetime.datetime:
    """plistlib returns naive UTC dates."""
    return moment if moment.tzinfo else moment.replace(tzinfo=datetime.timezone.utc)


def _profile_plist(profile_bytes: bytes) -> dict[str, Any]:
    """The plist inside a .mobileprovision (a CMS blob), sliced out like refresh.profile_expiration."""
    start = profile_bytes.find(b"<?xml")
    end = profile_bytes.find(b"</plist>")
    try:
        if start == -1 or end == -1:
            raise ValueError("no plist")
        plist = plistlib.loads(profile_bytes[start : end + len(b"</plist>")])
        if not isinstance(plist, dict):
            raise ValueError("not a dict")
        return plist
    except Exception:
        raise CustomCertError(
            "The provisioning profile could not be read. Choose the .mobileprovision file the seller sent."
        ) from None


def _load_p12(data: bytes, password: str):
    """(private key, certificate, other certificates) of a seller's p12, any common encryption."""
    secrets_to_try = [password.encode("utf-8")]
    if not password:
        secrets_to_try.append(None)  # a p12 made without a password
    for secret in secrets_to_try:
        try:
            return pkcs12.load_key_and_certificates(data, secret)
        except (ValueError, UnsupportedAlgorithm):
            continue
    raise CustomCertError(
        "The certificate password is wrong, or the .p12 file is damaged or uses an unsupported encryption. "
        "Check the password and the file the seller sent."
    )


def _device_in_profile(plist: dict[str, Any], udid: str) -> bool:
    if plist.get("ProvisionsAllDevices"):
        return True
    # lockdown and profiles can differ in dashes and case
    norm = lambda value: str(value).replace("-", "").upper()  # noqa: E731
    return norm(udid) in {norm(item) for item in plist.get("ProvisionedDevices") or []}


def import_certificate(p12_path: Path, password: str, profile_path: Path) -> dict[str, Any]:
    """Validate a seller's .p12 + .mobileprovision and make them the active identity.

    Replaces any earlier import; on any error the earlier one is left untouched.
    Returns the facts the UI shows (see ``info`` in the contract).
    """
    try:
        p12_raw = Path(p12_path).read_bytes()
        profile_raw = Path(profile_path).read_bytes()
    except OSError as exc:
        raise CustomCertError(
            f"A selected file could not be read ({exc.strerror or exc}). Choose the files again."
        ) from None
    key, cert, others = _load_p12(p12_raw, password)
    if key is None:
        raise CustomCertError("The .p12 file has no private key. Ask the seller for a .p12 that includes it.")
    if cert is None:
        raise CustomCertError("The .p12 file has no certificate. Ask the seller for a complete .p12.")
    plist = _profile_plist(profile_raw)

    cert_der = cert.public_bytes(serialization.Encoding.DER)
    listed = [bytes(item) for item in plist.get("DeveloperCertificates") or [] if isinstance(item, (bytes, bytearray))]
    if cert_der not in listed and hashlib.sha256(cert_der).digest() not in listed:
        raise CustomCertError(
            "This certificate is not listed in the provisioning profile. "
            "Ask the seller for the profile made for this certificate."
        )
    app_id = (plist.get("Entitlements") or {}).get("application-identifier")
    if not isinstance(app_id, str) or "." not in app_id:
        raise CustomCertError("The provisioning profile has no App ID. Ask the seller for a valid profile.")
    expiry = plist.get("ExpirationDate")
    if not isinstance(expiry, datetime.datetime):
        raise CustomCertError("The provisioning profile has no expiry date. Ask the seller for a valid profile.")
    cert_expires = cert.not_valid_after_utc
    profile_expires = _aware(expiry)
    now = datetime.datetime.now(datetime.timezone.utc)
    if cert_expires <= now:
        raise CustomCertError("This certificate has expired. Ask the seller for a new one.")
    if profile_expires <= now:
        raise CustomCertError("The provisioning profile has expired. Ask the seller for a new one.")

    team_ids = plist.get("TeamIdentifier") or []
    names = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
    info = {
        "name": str(names[0].value) if names else cert.subject.rfc4514_string(),
        "team_id": str(team_ids[0]) if team_ids else app_id.split(".", 1)[0],
        "team_name": str(plist.get("TeamName") or ""),
        "serial": format(cert.serial_number, "X"),
        "fingerprint": hashlib.sha1(cert_der).hexdigest(),
        "certificate_expires": _iso(cert_expires),
        "profile_name": str(plist.get("Name") or ""),
        "profile_expires": _iso(profile_expires),
        "expires": _iso(min(cert_expires, profile_expires)),
        "app_id": app_id,
        "wildcard": app_id.endswith("*"),
        "all_devices": bool(plist.get("ProvisionsAllDevices")),
        "device_count": len(plist.get("ProvisionedDevices") or []),
        "imported_at": _iso(now),
    }
    new_password = secrets.token_urlsafe(24)
    try:
        new_p12 = pkcs12.serialize_key_and_certificates(
            _FRIENDLY_NAME, key, cert, others or None, serialization.BestAvailableEncryption(new_password.encode("utf-8"))
        )
    except ValueError:  # the private key is not the one of the certificate
        raise CustomCertError(
            "The .p12's private key does not belong to its certificate. Ask the seller for a correct .p12."
        ) from None

    with _locked(wait=False):  # a GUI command: a busy lock answers at once (OperationBusy)
        _recover(strict=True)
        try:
            stage = Path(tempfile.mkdtemp(prefix=f"{FOLDER}.", suffix=".new", dir=paths.data_dir()))
        except OSError as exc:
            raise _storage_error(exc) from None
        try:
            _write(stage / _P12, new_p12)
            _write(stage / _PROFILE, profile_raw)
            secure_store.write_json(stage / _JSON, {"p12_password": new_password, "info": info})
            _swap_in(stage)
        except OSError as exc:
            shutil.rmtree(stage, ignore_errors=True)
            raise _storage_error(exc) from None
        except BaseException:
            shutil.rmtree(stage, ignore_errors=True)
            raise
    return dict(info)


def _storage_error(exc: OSError) -> CustomCertError:
    return CustomCertError(
        f"The certificate files could not be updated ({exc.strerror or exc}). "
        "Free some disk space, close programs using EZSide's data folder, then try again."
    )


def _locked(wait: bool = True):
    """The engine's operation lock (re-entrant), imported late: refresh may itself import this module."""
    from . import refresh

    return refresh.operation_lock(wait)


def _write(path: Path, data: bytes) -> None:
    """Write [data] and flush it to disk, so a power loss cannot leave an empty file beside a valid json."""
    with open(path, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())


def _backup() -> Path:
    return _folder().with_name(FOLDER + ".old")


def _stages() -> list[Path]:
    return list(paths.data_dir().glob(f"{FOLDER}.*.new"))


def _recover(strict: bool = False) -> None:
    """Heal what a crash between the swap's two renames left; call it under the lock.

    A missing certificate folder with a ``.old`` beside it is the previous certificate: it
    goes back (a failure there raises: the live certificate is missing). Whatever ``.old``
    and ``.*.new`` stage folders remain after that are deleted, so no seller key is left
    behind; one that cannot be deleted is logged and the certificate stays usable (an import,
    which makes a new one, passes ``strict`` and gets the error instead).
    """
    target, backup = _folder(), _backup()
    if not target.exists() and backup.exists():
        try:
            secure_store.replace_atomic(backup, target)
        except OSError as exc:
            raise _storage_error(exc) from None
    for leftover in [backup, *_stages()]:
        try:
            _delete(leftover)
        except CustomCertError as exc:
            if strict:
                raise
            _warn_leftover(exc)


def _warn_leftover(exc: Exception) -> None:
    """Report (no secrets in it) that leftover files were not cleaned up, without failing the caller."""
    print(f"warning: the leftover custom certificate files were not cleaned up: {exc}",
          file=sys.__stderr__ or sys.stderr, flush=True)


def _delete(folder: Path) -> None:
    """Delete [folder] (absent is fine); a failure is reported, so no seller key stays unnoticed."""
    try:
        shutil.rmtree(folder)
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise _storage_error(exc) from None


def _heal() -> None:
    """status() / active(): run recovery when a crash left ``.old`` or a stage behind.

    Under the operation lock, so a running import's stage is never deleted, and never
    waiting for it: while another holder has it (an import, a sideload in another process)
    this skips and a later call cleans up, so a read cannot block the app. A failure is
    logged (no secrets in it), not raised: a read must still answer.
    """
    from . import refresh

    if not (_backup().exists() or _stages()):
        return
    try:
        with _locked(wait=False):
            _recover()
    except refresh.OperationBusy:
        return
    except EngineError as exc:  # the previous certificate could not be put back
        _warn_leftover(exc)


def _swap_in(stage: Path) -> None:
    """Make [stage] the certificate folder; the old one is restored if that fails."""
    target, backup = _folder(), _backup()
    if target.exists():
        secure_store.replace_atomic(target, backup)
    try:
        secure_store.replace_atomic(stage, target)
    except BaseException:
        if backup.exists() and not target.exists():
            secure_store.replace_atomic(backup, target)
        raise
    try:
        _delete(backup)
    except CustomCertError as exc:  # the new certificate is live: report success, _heal cleans up later
        _warn_leftover(exc)


def _live() -> Path:
    """The certificate folder to read: the previous one while a crash left only ``.old``."""
    return _folder() if _folder().exists() or not _backup().exists() else _backup()


def _stored() -> dict[str, Any] | None:
    """The stored {p12_password, info}, or None when nothing usable is imported."""
    folder = _live()
    try:
        data = secure_store.read_json(folder / _JSON)
    except (OSError, ValueError):
        return None
    if not (isinstance(data, dict) and isinstance(data.get("info"), dict) and isinstance(data.get("p12_password"), str)):
        return None
    if not ((folder / _P12).is_file() and (folder / _PROFILE).is_file()):
        return None
    return data


def _expired(info: dict[str, Any]) -> bool:
    expiry = _parse(info.get("expires"))
    return expiry is None or expiry <= datetime.datetime.now(datetime.timezone.utc)


def _device_ok(udid: str) -> bool:
    try:
        return _device_in_profile(_profile_plist((_live() / _PROFILE).read_bytes()), udid)
    except (OSError, CustomCertError):
        return False


def status(udid: str | None = None) -> dict[str, Any] | None:
    """The imported certificate's facts plus ``device_ok`` (None without a udid), or None."""
    _heal()
    data = _stored()
    if data is None:
        return None
    return {**data["info"], "device_ok": None if udid is None else _device_ok(udid)}


def remove() -> bool:
    """Delete the imported certificate. True if there was one."""
    with _locked(wait=False):  # a GUI command: a busy lock answers at once (OperationBusy)
        existed = _folder().exists() or _backup().exists()
        # Rename first (``.old`` before the live folder, so a kill never leaves ``.old`` as
        # the certificate): a half-run rmtree then only ever works on a stage name, which
        # status() never reads and recovery deletes.
        for live in (_backup(), _folder()):
            if live.exists():
                try:
                    secure_store.replace_atomic(live, live.with_name(f"{FOLDER}.{secrets.token_hex(6)}.new"))
                except OSError as exc:
                    raise _storage_error(exc) from None
        signing.sweep_signing_temp()  # before the stage loop: an undeletable stage must not skip it
        for leftover in _stages():  # also what a crash left: no seller key stays
            _delete(leftover)
        return existed


def active() -> bool:
    """An imported certificate that has not expired."""
    _heal()
    data = _stored()
    return data is not None and not _expired(data["info"])


def signing_bundle(source_bundle_id: str, udid: str, bundle_id: str | None = None) -> dict[str, Any]:
    """What sign_ipa needs, shaped like provision.ensure_signing_assets' result (see the contract)."""
    with _locked():
        _recover()
    data = _stored()
    if data is None:
        raise CustomCertError("No certificate is imported. Import a .p12 and its provisioning profile first.")
    info = data["info"]
    if _expired(info):
        raise CustomCertError(
            f"The imported certificate or its profile expired on {info.get('expires')}. Import a new one."
        )
    if not _device_ok(udid):
        raise CustomCertError(
            f"This iPhone (UDID {udid}) is not in the provisioning profile. Ask the seller to add it."
        )
    return {
        "p12_path": str(_folder() / _P12),
        "p12_password": data["p12_password"],
        "profile_path": str(_folder() / _PROFILE),
        "team_id": info["team_id"],
        "team_name": info["team_name"],
        "bundle_id": _bundle_id(info["app_id"], source_bundle_id, bundle_id),
        "certificate_serial": info["serial"],
        "fingerprint": info["fingerprint"],
        "expires_at": info["expires"],
    }


def _bundle_id(app_id: str, source: str, override: str | None) -> str:
    """The bundle id to sign with so that the profile's App ID covers it."""
    pattern = app_id.split(".", 1)[1]  # drop the team prefix
    if pattern == "*":
        return override or source
    if pattern.endswith(".*"):
        prefix = pattern[:-1]  # "p."
        if override is not None:
            if not override.startswith(prefix):
                raise CustomCertError(
                    f"The bundle id {override} does not fit the provisioning profile's App ID {app_id}. "
                    f"Use a bundle id that starts with {prefix}"
                )
            return override
        return source if source.startswith(prefix) else prefix + source
    if override is not None and override != pattern:
        raise CustomCertError(
            f"The provisioning profile only allows the bundle id {pattern}, not {override}. Leave the bundle id empty."
        )
    return pattern
