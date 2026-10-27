"""Export, import, and create of this PC's pairing file.

The UDID-key tests stay in test_pairing.py. This file is the rest of the pairing
surface: Remote Pairing detection, iLoader import, export, create, and how the
stored file is protected. EZSide does not place the file into apps on the phone.
"""

from __future__ import annotations

import plistlib
from pathlib import Path

import pytest

from ipaside_engine import pairing
from ipaside_engine.__main__ import build_parser

UDID = "00008150-001479110E20401C"
OTHER = "935cbbb9b82d25d15566e5939bcea5677b1c44ae"

USBMUX_RECORD = {
    "DeviceCertificate": b"-----BEGIN CERTIFICATE-----\ndevice\n",
    "HostCertificate": b"-----BEGIN CERTIFICATE-----\nhost\n",
    "RootCertificate": b"-----BEGIN CERTIFICATE-----\nroot\n",
    "HostPrivateKey": b"-----BEGIN RSA PRIVATE KEY-----\nhost\n",
    "RootPrivateKey": b"-----BEGIN RSA PRIVATE KEY-----\nroot\n",
    "EscrowBag": b"\x00" * 32,
    "HostID": "host-id",
    "SystemBUID": "buid",
    "WiFiMACAddress": "34:08:bc:9f:27:c2",
}

RP_KEYS = {
    "identifier": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "public_key": b"\x01" * 32,
    "private_key": b"\x02" * 32,
    "alt_irk": b"\x03" * 16,
}


@pytest.fixture
def lockdown_dir(monkeypatch, tmp_path):
    """A stand-in for ProgramData\\Apple\\Lockdown holding whatever a test needs."""

    def _make(records: dict[str, dict]):
        for name, record in records.items():
            (tmp_path / f"{name}.plist").write_bytes(plistlib.dumps(record))
        monkeypatch.setattr(pairing, "_LOCKDOWN_DIR", tmp_path)
        return tmp_path

    return _make


def test_lockdown_only_payload_is_xml_with_udid(lockdown_dir):
    lockdown_dir({UDID: USBMUX_RECORD})

    record = pairing.payload_record(UDID)

    assert record["UDID"] == UDID
    assert pairing.has_lockdown_keys(record) is True
    assert pairing.has_rppairing_keys(record) is False
    assert pairing.payload_bytes(UDID).lstrip().startswith(b"<?xml")


def test_inspect_warns_when_remote_pairing_keys_are_missing(lockdown_dir):
    lockdown_dir({UDID: USBMUX_RECORD})

    report = pairing.inspect_record(UDID)

    assert report["source"] == "lockdown"
    assert report["has_lockdown"] is True
    assert report["has_rppairing"] is False
    assert "Remote Pairing" in report["note"]
    assert report["error"] is None


def test_importing_an_iloader_file_adds_remote_pairing_keys(lockdown_dir, tmp_path):
    lockdown_dir({UDID: USBMUX_RECORD})
    merged = {**USBMUX_RECORD, **RP_KEYS, "UDID": UDID}
    source = tmp_path / "pairingFile.plist"
    source.write_bytes(plistlib.dumps(merged))

    result = pairing.import_from(UDID, source)
    record = pairing.payload_record(UDID)

    assert result["imported"] is True
    assert result["has_rppairing"] is True
    assert pairing.has_rppairing_keys(record) is True
    assert record["identifier"] == RP_KEYS["identifier"]
    assert record["DeviceCertificate"] == USBMUX_RECORD["DeviceCertificate"]
    assert pairing.inspect_record(UDID)["source"] == "imported"


def test_a_remote_pairing_only_import_is_filled_from_usbmux(lockdown_dir, tmp_path):
    """iLoader sometimes writes the RP half; USB trust still lives in Lockdown."""
    lockdown_dir({UDID: USBMUX_RECORD})
    source = tmp_path / "rp-only.plist"
    source.write_bytes(plistlib.dumps({**RP_KEYS}))

    pairing.import_from(UDID, source)
    record = pairing.payload_record(UDID)

    assert pairing.has_rppairing_keys(record) is True
    assert pairing.has_lockdown_keys(record) is True
    assert record["UDID"] == UDID


def test_import_refuses_another_phone_s_file(lockdown_dir, tmp_path):
    lockdown_dir({UDID: USBMUX_RECORD})
    source = tmp_path / "wrong.plist"
    source.write_bytes(plistlib.dumps({**USBMUX_RECORD, **RP_KEYS, "UDID": OTHER}))

    with pytest.raises(pairing.PairingError, match="not 00008150"):
        pairing.import_from(UDID, source)


def test_import_refuses_a_plist_that_is_not_a_pairing_file(lockdown_dir, tmp_path):
    lockdown_dir({UDID: USBMUX_RECORD})
    source = tmp_path / "empty.plist"
    source.write_bytes(plistlib.dumps({"Hello": "World"}))

    with pytest.raises(pairing.PairingError, match="neither USB pairing"):
        pairing.import_from(UDID, source)


def test_export_writes_the_imported_file_not_the_lockdown_half(lockdown_dir, tmp_path):
    lockdown_dir({UDID: USBMUX_RECORD})
    source = tmp_path / "iloader.plist"
    source.write_bytes(plistlib.dumps({**USBMUX_RECORD, **RP_KEYS, "UDID": UDID}))
    pairing.import_from(UDID, source)

    destination = tmp_path / "out" / "pairingFile.plist"
    result = pairing.export_to(UDID, destination)
    exported = plistlib.loads(destination.read_bytes())

    assert result["exported"] is True
    assert result["has_rppairing"] is True
    assert exported["private_key"] == RP_KEYS["private_key"]
    assert destination.read_bytes().lstrip().startswith(b"<?xml")


def test_create_remote_pairing_merges_usb_keys_from_this_pc(lockdown_dir, monkeypatch):
    lockdown_dir({UDID: USBMUX_RECORD})
    monkeypatch.setattr(
        pairing,
        "_remote_pair_keys",
        lambda udid, serial=None: dict(RP_KEYS),
    )

    result = pairing.create_remote_pairing(UDID, UDID)
    record = pairing.payload_record(UDID)

    assert result["created"] is True
    assert result["has_rppairing"] is True
    assert pairing.has_lockdown_keys(record) is True
    assert record["identifier"] == RP_KEYS["identifier"]
    assert record["DeviceCertificate"] == USBMUX_RECORD["DeviceCertificate"]
    assert pairing.inspect_record(UDID)["source"] == "imported"


def test_create_remote_pairing_skips_the_phone_when_keys_already_exist(
    lockdown_dir, monkeypatch
):
    lockdown_dir({UDID: {**USBMUX_RECORD, **RP_KEYS}})
    calls: list[str] = []

    def boom(udid, serial=None):
        calls.append(udid)
        raise AssertionError("must not talk to the phone")

    monkeypatch.setattr(pairing, "_remote_pair_keys", boom)

    result = pairing.create_remote_pairing(UDID, UDID)

    assert result["created"] is False
    assert result["has_rppairing"] is True
    assert calls == []


def test_create_remote_pairing_force_replaces_existing_keys(lockdown_dir, monkeypatch):
    lockdown_dir({UDID: {**USBMUX_RECORD, **RP_KEYS}})
    replacement = {
        "identifier": "ffffffff-1111-2222-3333-444444444444",
        "public_key": b"\x11" * 32,
        "private_key": b"\x22" * 32,
    }
    monkeypatch.setattr(
        pairing, "_remote_pair_keys", lambda udid, serial=None: replacement
    )

    result = pairing.create_remote_pairing(UDID, UDID, force=True)
    record = pairing.payload_record(UDID)

    assert result["created"] is True
    assert record["private_key"] == replacement["private_key"]


def test_cli_pairing_flags_are_mutually_exclusive():
    parser = build_parser()
    args = parser.parse_args(["pairing", "--json", "--udid", UDID])
    assert args.command == "pairing"
    assert args.pairing_export is None
    assert args.pairing_import is None
    assert args.pairing_create is False

    exported = parser.parse_args(["pairing", "--export", r"C:\out.plist", "--udid", UDID])
    assert exported.pairing_export == r"C:\out.plist"

    imported = parser.parse_args(["pairing", "--import", r"C:\in.plist", "--udid", UDID])
    assert imported.pairing_import == r"C:\in.plist"

    created = parser.parse_args(["pairing", "--create", "--udid", UDID])
    assert created.pairing_create is True

    with pytest.raises(SystemExit):
        parser.parse_args(["pairing", "--deliver", "--udid", UDID])


# --- secrets at rest -------------------------------------------------------- #

def test_the_stored_pairing_record_is_protected_and_still_loads(lockdown_dir, tmp_path):
    lockdown_dir({UDID: USBMUX_RECORD})
    source = tmp_path / "iloader.plist"
    source.write_bytes(plistlib.dumps({**USBMUX_RECORD, **RP_KEYS, "UDID": UDID}))

    result = pairing.import_from(UDID, source)
    raw = Path(result["path"]).read_bytes()

    assert raw.startswith(b"EZS1")
    assert pairing.payload_record(UDID)["private_key"] == RP_KEYS["private_key"]
    assert pairing.inspect_record(UDID)["source"] == "imported"


def test_a_created_remote_pairing_is_stored_protected(lockdown_dir, monkeypatch):
    lockdown_dir({UDID: USBMUX_RECORD})
    monkeypatch.setattr(pairing, "_remote_pair_keys", lambda udid, serial=None: dict(RP_KEYS))

    result = pairing.create_remote_pairing(UDID, UDID)

    assert Path(result["path"]).read_bytes().startswith(b"EZS1")
    assert pairing.has_rppairing_keys(pairing.payload_record(UDID)) is True


def test_a_plain_pairing_record_from_an_older_build_is_still_read(lockdown_dir):
    lockdown_dir({UDID: USBMUX_RECORD})
    (pairing.pairing_dir() / f"{UDID}.plist").write_bytes(
        plistlib.dumps({**RP_KEYS, "UDID": UDID})
    )

    record = pairing.payload_record(UDID)

    assert record["identifier"] == RP_KEYS["identifier"]
    assert pairing.inspect_record(UDID)["source"] == "imported"


def test_exports_stay_plain(lockdown_dir, tmp_path):
    lockdown_dir({UDID: USBMUX_RECORD})
    source = tmp_path / "iloader.plist"
    source.write_bytes(plistlib.dumps({**USBMUX_RECORD, **RP_KEYS, "UDID": UDID}))
    pairing.import_from(UDID, source)

    destination = tmp_path / "out.plist"
    pairing.export_to(UDID, destination)

    assert not destination.read_bytes().startswith(b"EZS1")
    assert plistlib.loads(pairing.payload_bytes(UDID))["private_key"] == RP_KEYS["private_key"]


def test_a_stored_file_that_cannot_be_read_is_reported_not_skipped(lockdown_dir):
    """Falling back to the lockdown half would export a file without the Remote Pairing keys."""
    lockdown_dir({UDID: USBMUX_RECORD})
    (pairing.pairing_dir() / f"{UDID}.plist").write_bytes(b"EZS1" + b"not a blob")

    report = pairing.inspect_record(UDID)

    assert report["imported"] is True
    assert report["source"] == "none"
    assert "could not be read" in report["error"]
    assert report["has_lockdown"] is True
    with pytest.raises(pairing.PairingError, match="could not be read"):
        pairing.export_to(UDID, Path("never-written.plist"))


def test_create_remote_pairing_replaces_a_stored_file_that_cannot_be_read(
    lockdown_dir, monkeypatch
):
    lockdown_dir({UDID: USBMUX_RECORD})
    (pairing.pairing_dir() / f"{UDID}.plist").write_bytes(b"EZS1" + b"not a blob")
    monkeypatch.setattr(pairing, "_remote_pair_keys", lambda udid, serial=None: dict(RP_KEYS))

    result = pairing.create_remote_pairing(UDID, UDID)

    assert result["created"] is True
    assert result["error"] is None
    assert pairing.has_rppairing_keys(pairing.payload_record(UDID)) is True
