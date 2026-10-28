"""This PC's pairing file for an iPhone: status, export, import, and create.

A pairing file is this computer's trusted identity with one iPhone. This module
reads the usbmux record Windows keeps, can export it to a file, can create the
Remote Pairing half over USB, and can still import a file another tool wrote
(iLoader, for example). EZSide never writes the file into an app on the phone:
the user moves an exported file themselves.

Windows usbmux writes the lockdown half (certificates, HostID, escrow) and omits
``UDID`` because the file name carries it. Remote Pairing keys (``identifier``,
Ed25519 ``public_key`` / ``private_key``, ``alt_irk``) are not in that record.
iOS 26.4 and later tunnels need those keys. EZSide creates them itself over the
already-trusted USB lockdown channel (promptless; no second Trust dialog).
Importing an iLoader file remains optional.
"""

from __future__ import annotations

import plistlib
from pathlib import Path
from typing import Any

from . import paths, secure_store
from .errors import EngineError

#: Where usbmux keeps the pairing records this PC has for its devices.
_LOCKDOWN_DIR = Path(r"C:\ProgramData\Apple\Lockdown")

#: Keys iLoader adds so a Remote Pairing tunnel can start. ``alt_irk`` is useful
#: but not required for ``rp_pairing_file_read``.
_RP_REQUIRED_KEYS = ("identifier", "public_key", "private_key")

#: Why a lockdown-only file is not enough for iOS 26.4 and later tunnels.
MISSING_RP_WARNING = (
    "This file has this PC's USB pairing keys only (same as iLoader, including iOS 15-18). "
    "iOS 26.4 and later tunnels also need Remote Pairing keys. "
    "Plug the iPhone in over USB once and let EZSide create them, then export the file again."
)

HAS_RP_NOTE = (
    "This file is the iLoader-style merge: USB pairing plus Remote Pairing keys. "
    "The phone does not need to stay connected to this PC."
)


class PairingError(EngineError):
    """The pairing file could not be read, imported, exported, or created."""


def pairing_dir() -> Path:
    """Per-device imported pairing files, outside Apple's Lockdown folder.

    Apple's directory is the usbmux record. A Remote Pairing file iPASide creates
    (or an imported iLoader file) is a different document, and writing it there
    would mix a credential Windows did not write with the one it owns. Keeping it
    under iPASide's data directory means clearing iPASide state drops it without
    touching the USB pairing.
    """
    path = paths.data_dir() / "pairing"
    path.mkdir(parents=True, exist_ok=True)
    return path


def has_lockdown_keys(record: dict[str, Any]) -> bool:
    """True when the record can drive a lockdown / minimuxer session."""
    return bool(record.get("DeviceCertificate") and record.get("HostCertificate"))


def has_rppairing_keys(record: dict[str, Any]) -> bool:
    """True when ``rp_pairing_file_read`` has the keys it actually parses."""
    return all(record.get(key) not in (None, b"", "") for key in _RP_REQUIRED_KEYS)


def payload_bytes(udid: str, *, lockdown_dir: Path | None = None) -> bytes:
    """The pairing file that should be exported for ``udid``.

    An imported or EZSide-created file wins, because that is the one that carries
    Remote Pairing keys. Missing lockdown keys in the store are filled from usbmux
    so a Remote-Pairing-only document still carries the USB half. With no store,
    this is the usbmux record plus ``UDID``.
    """
    record = payload_record(udid, lockdown_dir=lockdown_dir)
    return plistlib.dumps(record, fmt=plistlib.FMT_XML)


def payload_record(udid: str, *, lockdown_dir: Path | None = None) -> dict[str, Any]:
    """The pairing dict :func:`payload_bytes` serialises, without dumping it."""
    directory = lockdown_dir or _LOCKDOWN_DIR
    imported = _read_imported(udid)
    lockdown: dict[str, Any] | None = None
    try:
        lockdown = _load_lockdown(udid, directory)
        lockdown.setdefault("UDID", udid)
    except PairingError:
        lockdown = None

    if imported is None and lockdown is None:
        raise PairingError(_missing_record_message())

    if imported is None:
        return lockdown  # type: ignore[return-value]

    # Imported or created keys win: that document already merged both halves.
    merged = {**(lockdown or {}), **imported}
    merged.setdefault("UDID", udid)
    return merged


def inspect_record(udid: str, *, lockdown_dir: Path | None = None) -> dict[str, Any]:
    """What this PC holds for ``udid``, without talking to the phone."""
    directory = lockdown_dir or _LOCKDOWN_DIR
    imported_file = _imported_path(udid)
    imported_present = imported_file.is_file()
    lockdown_present = False
    try:
        _load_lockdown(udid, directory)
        lockdown_present = True
    except PairingError:
        pass

    source = "none"
    record: dict[str, Any] | None = None
    error: str | None = None
    try:
        record = payload_record(udid, lockdown_dir=directory)
        source = "imported" if imported_present else "lockdown"
    except PairingError as exc:
        error = str(exc)

    has_lockdown = has_lockdown_keys(record) if record else lockdown_present
    has_rp = has_rppairing_keys(record) if record else False
    return {
        "udid": udid,
        "source": source,
        "has_lockdown": has_lockdown,
        "has_rppairing": has_rp,
        "imported": imported_present,
        "imported_path": str(imported_file) if imported_present else None,
        "bytes": len(plistlib.dumps(record, fmt=plistlib.FMT_XML)) if record else 0,
        "note": HAS_RP_NOTE if has_rp else (MISSING_RP_WARNING if record else None),
        "error": error,
    }


def export_to(udid: str, destination: str | Path, *, lockdown_dir: Path | None = None) -> dict[str, Any]:
    """Write the pairing file for ``udid`` to ``destination`` as XML."""
    payload = payload_bytes(udid, lockdown_dir=lockdown_dir)
    path = Path(destination).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    record = plistlib.loads(payload)
    return {
        "exported": True,
        "path": str(path.resolve()),
        "bytes": len(payload),
        "has_lockdown": has_lockdown_keys(record),
        "has_rppairing": has_rppairing_keys(record),
        "note": HAS_RP_NOTE if has_rppairing_keys(record) else MISSING_RP_WARNING,
    }


def import_from(
    udid: str,
    source: str | Path,
    *,
    lockdown_dir: Path | None = None,
) -> dict[str, Any]:
    """Store ``source`` as this PC's pairing file for ``udid``.

    The file is validated, checked against ``udid`` so another phone's record
    cannot be attached by accident, merged with the usbmux lockdown half when the
    import is Remote-Pairing-only, and written under EZSide's data directory.
    """
    path = Path(source).expanduser()
    if not path.is_file():
        raise PairingError(f"{path} is not a file, so it cannot be imported as a pairing record.")
    try:
        parsed = plistlib.loads(path.read_bytes())
    except (OSError, ValueError) as exc:
        raise PairingError(f"{path} is not a pairing plist: {exc}") from exc
    if not isinstance(parsed, dict):
        raise PairingError(f"{path} is a plist, but not a pairing record (expected a dictionary).")
    if not has_lockdown_keys(parsed) and not has_rppairing_keys(parsed):
        raise PairingError(
            f"{path} has neither USB pairing certificates nor Remote Pairing keys, "
            "so it is not a pairing file."
        )
    _reject_foreign_udid(parsed, udid)

    directory = lockdown_dir or _LOCKDOWN_DIR
    lockdown: dict[str, Any] | None = None
    try:
        lockdown = _load_lockdown(udid, directory)
        lockdown.setdefault("UDID", udid)
    except PairingError:
        lockdown = None
    merged = {**(lockdown or {}), **parsed}
    merged.setdefault("UDID", udid)

    stored = _imported_path(udid)
    secure_store.write_bytes(stored, plistlib.dumps(merged, fmt=plistlib.FMT_XML))
    return {
        "imported": True,
        "path": str(stored),
        "from": str(path.resolve()),
        "has_lockdown": has_lockdown_keys(merged),
        "has_rppairing": has_rppairing_keys(merged),
        "note": HAS_RP_NOTE if has_rppairing_keys(merged) else MISSING_RP_WARNING,
    }


def create_remote_pairing(
    udid: str,
    serial: str | None = None,
    *,
    force: bool = False,
    lockdown_dir: Path | None = None,
) -> dict[str, Any]:
    """Create this PC's Remote Pairing keys over USB and store the merged file.

    Pair-setup runs on the already-trusted lockdown channel, so the phone does
    not show a second Trust dialog. ``force`` re-runs pair-setup even when a
    complete file is already stored.
    """
    directory = lockdown_dir or _LOCKDOWN_DIR
    existing: dict[str, Any] | None
    try:
        existing = payload_record(udid, lockdown_dir=directory)
    except PairingError:
        existing = None
    if existing is not None and has_rppairing_keys(existing) and not force:
        report = inspect_record(udid, lockdown_dir=directory)
        report["created"] = False
        return report

    rp_keys = _remote_pair_keys(udid, serial)
    lockdown = _load_lockdown(udid, directory)
    lockdown.setdefault("UDID", udid)
    merged = {**lockdown, **rp_keys}
    merged.setdefault("UDID", udid)
    stored = _imported_path(udid)
    secure_store.write_bytes(stored, plistlib.dumps(merged, fmt=plistlib.FMT_XML))
    report = inspect_record(udid, lockdown_dir=directory)
    report["created"] = True
    report["path"] = str(stored)
    return report


def _remote_pair_keys(udid: str, serial: str | None = None) -> dict[str, Any]:
    """Ask the phone for a Remote Pairing identity over USB lockdown.

    Isolated as its own function so tests can supply keys without a device.
    The ``identifier`` written into the plist is the same host id pymobiledevice3
    registered during pair-setup (derived from this PC's hostname).
    """
    from pymobiledevice3.exceptions import RemotePairingCompletedError
    from pymobiledevice3.pair_records import generate_host_id
    from pymobiledevice3.remote.tunnel_service import RemotePairingLockdownService

    from . import lockdown as lockdown_mod
    from ._asyncutil import run

    async def _pair() -> dict[str, Any]:
        # usbmux only: Remote Pairing pairs, and pairing never runs over Wi-Fi direct.
        client = await lockdown_mod.create(
            serial or udid, prefer_usb=True, allow_wifi_direct=False
        )
        service = None
        try:
            service = await RemotePairingLockdownService.create(client)
            try:
                await service.connect(autopair=True)
            except RemotePairingCompletedError:
                await service.close()
                service = await RemotePairingLockdownService.create(client)
                await service.connect(autopair=False)
            path = service.pair_record_path
            if not path.is_file():
                raise PairingError(
                    "Remote Pairing finished, but this PC has no pair record to read."
                )
            parsed = plistlib.loads(path.read_bytes())
            if not isinstance(parsed, dict):
                raise PairingError(f"The Remote Pairing record at {path} is not a dictionary.")
            return parsed
        finally:
            if service is not None:
                await service.close()
            await lockdown_mod.close(client)

    try:
        parsed = run(_pair())
    except PairingError:
        raise
    except Exception as exc:  # noqa: BLE001 - surface as pairing, not a traceback
        raise PairingError(
            "Could not create Remote Pairing keys over USB. Unlock the iPhone, "
            f"keep it plugged in, and trust this PC, then try again. ({exc})"
        ) from exc

    public = parsed.get("public_key")
    private = parsed.get("private_key")
    if not public or not private:
        raise PairingError(
            "Remote Pairing did not write public_key and private_key, so the "
            "file would have no Remote Pairing keys."
        )
    keys: dict[str, Any] = {
        "identifier": str(parsed.get("identifier") or parsed.get("host_identifier") or generate_host_id()),
        "public_key": public,
        "private_key": private,
    }
    alt = parsed.get("alt_irk")
    if alt:
        keys["alt_irk"] = alt
    return keys


def _load_lockdown(udid: str, lockdown_dir: Path) -> dict[str, Any]:
    """The usbmux plist for ``udid``, or PairingError when there is none."""
    source = _find_lockdown_file(udid, lockdown_dir)
    if source is None:
        raise PairingError(_missing_record_message())
    try:
        parsed = plistlib.loads(source.read_bytes())
    except (OSError, ValueError) as exc:
        raise PairingError(f"The pairing record at {source} could not be read: {exc}") from exc
    if not isinstance(parsed, dict):
        raise PairingError(f"The pairing record at {source} is not a dictionary.")
    return parsed


def _find_lockdown_file(udid: str, lockdown_dir: Path) -> Path | None:
    """The usbmux file for ``udid``, matching on the file name first, then the UDID key."""
    if not lockdown_dir.is_dir():
        return None
    exact = lockdown_dir / f"{udid}.plist"
    if exact.exists():
        return exact
    wanted = _folded_udid(udid)
    for path in sorted(lockdown_dir.glob("*.plist")):
        try:
            parsed = plistlib.loads(path.read_bytes())
        except (OSError, ValueError):
            continue
        if not isinstance(parsed, dict):
            continue
        if _folded_udid(str(parsed.get("UDID", ""))) == wanted:
            return path
    return None


def _imported_path(udid: str) -> Path:
    """Where an imported file for ``udid`` is stored, creating no file."""
    directory = pairing_dir()
    exact = directory / f"{udid}.plist"
    if exact.exists():
        return exact
    wanted = _folded_udid(udid)
    for path in directory.glob("*.plist"):
        if _folded_udid(path.stem) == wanted:
            return path
    return exact


def _read_imported(udid: str) -> dict[str, Any] | None:
    path = _imported_path(udid)
    if not path.is_file():
        return None
    try:
        parsed = plistlib.loads(secure_store.read_bytes(path))
    except (OSError, ValueError) as exc:
        raise PairingError(_unreadable_imported_message(path, str(exc))) from exc
    if not isinstance(parsed, dict):
        raise PairingError(_unreadable_imported_message(path, "it is not a dictionary"))
    return parsed


def _reject_foreign_udid(record: dict[str, Any], udid: str) -> None:
    """Refuse a file that already names a different device."""
    listed = record.get("UDID")
    if not listed:
        return
    if _folded_udid(str(listed)) != _folded_udid(udid):
        raise PairingError(
            f"That pairing file is for {listed}, not {udid}. Use a pairing file "
            "that was made with this iPhone."
        )


def _folded_udid(value: str) -> str:
    return value.replace("-", "").lower()


def _unreadable_imported_message(path: Path, reason: str) -> str:
    return (
        f"The pairing file EZSide stored at {path} could not be read ({reason}). "
        "Create the Remote Pairing keys again or import a pairing file."
    )


def _missing_record_message() -> str:
    return (
        "This PC has no pairing record for the device, so there is no pairing file to "
        "export or extend. Reconnect it over USB and trust this computer, then try again."
    )
