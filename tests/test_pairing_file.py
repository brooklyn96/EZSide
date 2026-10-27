"""Export, import, and placement of pairing files for EscapeOS and peers.

The LiveContainer-specific UDID-key tests stay in test_pairing.py. This file is
the rest of the pairing surface: Remote Pairing detection, iLoader import, the
consumer catalogue, and the sideload hook that places a file after EscapeOS
lands on the phone.
"""

from __future__ import annotations

import plistlib

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


def test_escapeos_and_livecontainer_are_distinct_consumers():
    escapeos = pairing.match_consumer("com.ipaside.escapeos.V872QWK5TY")
    livecontainer = pairing.match_consumer("com.kdt.livecontainer.ASK9QR9SBC")
    sidestore = pairing.match_consumer("com.SideStore.SideStore.TEAM")
    ordinary = pairing.match_consumer("com.atebits.Tweetie2")

    assert escapeos is not None and escapeos.id == "escapeos"
    assert escapeos.filename == "pairingFile.plist"
    assert escapeos.needs_rppairing is True
    assert livecontainer is not None and livecontainer.id == "livecontainer"
    assert livecontainer.filename == pairing.ALT_PAIRING_NAME
    assert sidestore is not None and sidestore.id == "sidestore"
    assert ordinary is None


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


def test_deliver_writes_escapeos_under_the_name_it_reads(lockdown_dir, monkeypatch):
    lockdown_dir({UDID: USBMUX_RECORD})
    calls: dict = {}

    async def fake_write(bundle_id, serial, files, *, directories):
        calls.update(
            bundle_id=bundle_id, serial=serial, files=files, directories=directories
        )
        return [f"{d}/{n}" for d in directories for n in files]

    from ipaside_engine import livecontainer

    monkeypatch.setattr(livecontainer, "_write_documents", fake_write)

    result = pairing.deliver_to_app("com.ipaside.escapeos.V872QWK5TY", UDID, UDID)

    assert result["placed"] is True
    assert result["id"] == "escapeos"
    assert list(calls["files"]) == ["pairingFile.plist"]
    assert calls["directories"] == ("/Documents",)
    assert result["warning"] is not None, "lockdown-only must warn EscapeOS about iOS 26"


def test_deliver_to_device_places_every_supported_app(lockdown_dir, monkeypatch):
    lockdown_dir({UDID: {**USBMUX_RECORD, **RP_KEYS}})
    monkeypatch.setattr(
        pairing.apps,
        "list_installed",
        lambda _serial: {
            "com.ipaside.escapeos.TEAM": {"name": "EscapeOS"},
            "com.kdt.livecontainer.TEAM": {"name": "LiveContainer"},
            "com.atebits.Tweetie2": {"name": "X"},
        },
    )
    written: list[str] = []

    async def fake_write(bundle_id, _serial, files, *, directories):
        written.append(bundle_id)
        return [f"{d}/{next(iter(files))}" for d in directories]

    from ipaside_engine import livecontainer

    monkeypatch.setattr(livecontainer, "_write_documents", fake_write)

    result = pairing.deliver_to_device(UDID, UDID)

    assert result["has_rppairing"] is True
    assert result["supported_installed"] == 2
    assert written == [
        "com.ipaside.escapeos.TEAM",
        "com.kdt.livecontainer.TEAM",
    ]
    assert all(item["placed"] for item in result["placed"])
    assert all(item.get("warning") is None for item in result["placed"])


def test_deliver_to_device_can_target_one_app(lockdown_dir, monkeypatch):
    lockdown_dir({UDID: {**USBMUX_RECORD, **RP_KEYS}})
    monkeypatch.setattr(
        pairing.apps,
        "list_installed",
        lambda _serial: {
            "com.ipaside.escapeos.TEAM": {"name": "EscapeOS"},
            "com.kdt.livecontainer.TEAM": {"name": "LiveContainer"},
        },
    )
    written: list[str] = []

    async def fake_write(bundle_id, _serial, files, *, directories):
        written.append(bundle_id)
        return [f"{d}/{next(iter(files))}" for d in directories]

    from ipaside_engine import livecontainer

    monkeypatch.setattr(livecontainer, "_write_documents", fake_write)

    result = pairing.deliver_to_device(
        UDID, UDID, bundle_ids=["com.ipaside.escapeos.TEAM"]
    )

    assert written == ["com.ipaside.escapeos.TEAM"]
    assert result["supported_installed"] == 1
    assert result["placed"][0]["placed"] is True


def test_deliver_to_device_accepts_a_bundle_id_without_the_team_suffix(
    lockdown_dir, monkeypatch
):
    lockdown_dir({UDID: {**USBMUX_RECORD, **RP_KEYS}})
    monkeypatch.setattr(
        pairing.apps,
        "list_installed",
        lambda _serial: {"com.ipaside.escapeos.TEAM": {"name": "EscapeOS"}},
    )
    written: list[str] = []

    async def fake_write(bundle_id, _serial, files, *, directories):
        written.append(bundle_id)
        return [f"{d}/{next(iter(files))}" for d in directories]

    from ipaside_engine import livecontainer

    monkeypatch.setattr(livecontainer, "_write_documents", fake_write)

    result = pairing.deliver_to_device(UDID, UDID, bundle_ids=["com.ipaside.escapeos"])

    assert written == ["com.ipaside.escapeos.TEAM"]
    assert result["placed"][0]["placed"] is True
    assert result["placed"][0]["bundle_id"] == "com.ipaside.escapeos.TEAM"


def test_deliver_if_consumer_skips_livecontainer_and_ordinary_apps(lockdown_dir):
    lockdown_dir({UDID: USBMUX_RECORD})

    assert pairing.deliver_if_consumer("com.atebits.Tweetie2", UDID, skip_ids=()) is None
    assert pairing.deliver_if_consumer(
        "com.kdt.livecontainer.TEAM",
        UDID,
        skip_ids=frozenset({"livecontainer"}),
    ) is None


def test_status_lists_installed_consumers_even_when_the_pc_has_no_rp_keys(
    lockdown_dir, monkeypatch
):
    lockdown_dir({UDID: USBMUX_RECORD})
    monkeypatch.setattr(
        pairing.apps,
        "list_installed",
        lambda _serial: {"com.ipaside.escapeos.TEAM": {"name": "EscapeOS"}},
    )

    report = pairing.status(UDID, UDID)

    assert report["device_reachable"] is True
    assert report["consumers"][0]["id"] == "escapeos"
    assert report["consumers"][0]["needs_rppairing"] is True


def test_status_survives_a_device_that_cannot_be_listed(lockdown_dir, monkeypatch):
    lockdown_dir({UDID: USBMUX_RECORD})

    def explode(_serial):
        raise OSError("device went away")

    monkeypatch.setattr(pairing.apps, "list_installed", explode)

    report = pairing.status(UDID, UDID)

    assert report["has_lockdown"] is True
    assert report["device_reachable"] is False
    assert "device went away" in report["device_error"]
    assert report["consumers"] == []


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


def test_deliver_to_device_does_not_call_the_phone_from_a_test_lockdown_dir(
    lockdown_dir, monkeypatch
):
    """Unit tests patch Lockdown; they must not trigger USB pair-setup."""
    lockdown_dir({UDID: USBMUX_RECORD})
    monkeypatch.setattr(
        pairing.apps,
        "list_installed",
        lambda _serial: {"com.ipaside.escapeos.TEAM": {"name": "EscapeOS"}},
    )

    def boom(udid, serial=None):
        raise AssertionError("test lockdown dir must not create Remote Pairing")

    monkeypatch.setattr(pairing, "_remote_pair_keys", boom)

    async def fake_write(bundle_id, _serial, files, *, directories):
        return [f"{d}/{next(iter(files))}" for d in directories]

    from ipaside_engine import livecontainer

    monkeypatch.setattr(livecontainer, "_write_documents", fake_write)

    result = pairing.deliver_to_device(UDID, UDID)

    assert result["has_rppairing"] is False
    assert result["placed"][0]["placed"] is True
    assert result["placed"][0]["warning"] is not None


def test_cli_pairing_flags_are_mutually_exclusive():
    parser = build_parser()
    args = parser.parse_args(["pairing", "--json", "--udid", UDID])
    assert args.command == "pairing"
    assert args.pairing_export is None
    assert args.pairing_import is None
    assert args.deliver is False
    assert args.pairing_create is False

    exported = parser.parse_args(["pairing", "--export", r"C:\out.plist", "--udid", UDID])
    assert exported.pairing_export == r"C:\out.plist"

    imported = parser.parse_args(["pairing", "--import", r"C:\in.plist", "--udid", UDID])
    assert imported.pairing_import == r"C:\in.plist"

    created = parser.parse_args(["pairing", "--create", "--udid", UDID])
    assert created.pairing_create is True

    delivered = parser.parse_args(["pairing", "--deliver", "--udid", UDID])
    assert delivered.deliver is True
    assert delivered.pairing_app is None

    one = parser.parse_args(
        ["pairing", "--deliver", "--app", "com.ipaside.escapeos.TEAM", "--udid", UDID]
    )
    assert one.pairing_app == "com.ipaside.escapeos.TEAM"
