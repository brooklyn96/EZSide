"""The pairing file the built-in SideStore needs, and the one key Windows leaves out.

SideStore refreshes apps from the phone, and to reach lockdownd it needs the pairing
record this PC already holds. usbmux writes every key a session needs but not ``UDID`` -
the file name carries that - and SideStore is handed the file on its own with no name to
read, so without the key it rejects an otherwise complete record as "invalid or missing".

Confirmed on hardware both ways round: without the key SideStore refused it, and with it
SideStore's own log reported the file loaded and minimuxer bound to 127.0.0.1.
"""

from __future__ import annotations

import plistlib

import pytest

from ipaside_engine import livecontainer

UDID = "935cbbb9b82d25d15566e5939bcea5677b1c44ae"

# What usbmux actually writes on Windows: nine keys, no UDID.
USBMUX_RECORD = {
    "DeviceCertificate": b"-----BEGIN CERTIFICATE-----\ndevice\n",
    "HostCertificate": b"-----BEGIN CERTIFICATE-----\nhost\n",
    "RootCertificate": b"-----BEGIN CERTIFICATE-----\nroot\n",
    "HostPrivateKey": b"-----BEGIN RSA PRIVATE KEY-----\nhost\n",
    "RootPrivateKey": b"-----BEGIN RSA PRIVATE KEY-----\nroot\n",
    "EscrowBag": b"\x00" * 32,
    "HostID": "3125562413961861071686115308",
    "SystemBUID": "3125562413114651971424215308",
    "WiFiMACAddress": "34:08:bc:9f:27:c2",
}


@pytest.fixture
def lockdown_dir(monkeypatch, tmp_path):
    """A stand-in for ProgramData\\Apple\\Lockdown holding whatever a test needs."""

    def _make(records: dict[str, dict]):
        for name, record in records.items():
            (tmp_path / f"{name}.plist").write_bytes(plistlib.dumps(record))
        monkeypatch.setattr(livecontainer, "_LOCKDOWN_DIR", tmp_path)
        return tmp_path

    return _make


def test_the_udid_key_is_added(lockdown_dir):
    """The whole difference between a complete record and a usable one."""
    lockdown_dir({UDID: USBMUX_RECORD})

    record = plistlib.loads(livecontainer.pairing_record(UDID))

    assert record["UDID"] == UDID
    assert "UDID" not in USBMUX_RECORD, "usbmux does not write it; we do"


def test_every_other_key_is_passed_through_untouched(lockdown_dir):
    lockdown_dir({UDID: USBMUX_RECORD})

    record = plistlib.loads(livecontainer.pairing_record(UDID))

    for key, value in USBMUX_RECORD.items():
        assert record[key] == value, key
    assert set(record) == set(USBMUX_RECORD) | {"UDID"}


def test_a_record_that_already_names_its_device_is_not_rewritten(lockdown_dir):
    """A record written by something else may carry its own UDID; honour it."""
    lockdown_dir({UDID: {**USBMUX_RECORD, "UDID": "already-set"}})

    record = plistlib.loads(livecontainer.pairing_record(UDID))

    assert record["UDID"] == "already-set"


def test_it_is_written_as_xml(lockdown_dir):
    """AltStore and SideStore write their own pairing files as XML."""
    lockdown_dir({UDID: USBMUX_RECORD})

    payload = livecontainer.pairing_record(UDID)

    assert payload.lstrip().startswith(b"<?xml")


def test_a_record_is_found_by_its_own_udid_when_the_file_name_differs(lockdown_dir):
    """A connected serial can be formatted differently from the file usbmux wrote."""
    lockdown_dir({"some-other-name": {**USBMUX_RECORD, "UDID": UDID}})

    record = plistlib.loads(livecontainer.pairing_record(UDID))

    assert record["UDID"] == UDID


def test_a_dashed_serial_matches_an_undashed_record(lockdown_dir):
    lockdown_dir({"whatever": {**USBMUX_RECORD, "UDID": "00008150001479110E20401C"}})

    record = plistlib.loads(livecontainer.pairing_record("00008150-001479110E20401C"))

    assert record["UDID"] == "00008150001479110E20401C"


def test_no_record_says_what_to_do_about_it(lockdown_dir):
    lockdown_dir({})

    with pytest.raises(livecontainer.LiveContainerError) as excinfo:
        livecontainer.pairing_record(UDID)

    message = str(excinfo.value)
    assert "no pairing record" in message
    assert "trust this computer" in message, "the fix is to trust the PC again"


def test_an_unreadable_record_is_skipped_rather_than_fatal(lockdown_dir):
    """One corrupt file among several must not hide the usable one."""
    directory = lockdown_dir({"good": {**USBMUX_RECORD, "UDID": UDID}})
    (directory / "broken.plist").write_bytes(b"not a plist at all")

    record = plistlib.loads(livecontainer.pairing_record(UDID))

    assert record["UDID"] == UDID


def test_a_record_for_a_different_device_is_not_used(lockdown_dir):
    """Handing over another device's pairing would be both wrong and a credential leak."""
    lockdown_dir({"other": {**USBMUX_RECORD, "UDID": "a-different-phone"}})

    with pytest.raises(livecontainer.LiveContainerError, match="no pairing record"):
        livecontainer.pairing_record(UDID)


# --------------------------------------------------------------------------- #
# Where it gets written
# --------------------------------------------------------------------------- #
def test_it_is_written_where_sidestore_looks_and_where_the_picker_can_reach(
    lockdown_dir, monkeypatch
):
    lockdown_dir({UDID: USBMUX_RECORD})
    calls: dict = {}

    async def fake_write(bundle_id, serial, files, *, directories):
        calls.update(
            bundle_id=bundle_id, serial=serial, files=files, directories=directories
        )
        return [f"{d}/{n}" for d in directories for n in files]

    monkeypatch.setattr(livecontainer, "_write_documents", fake_write)

    result = livecontainer.deliver_pairing("com.kdt.livecontainer.T", UDID, UDID)

    assert result["paired"] is True
    assert list(calls["files"]) == [livecontainer.PAIRING_NAME]
    assert livecontainer.SIDESTORE_DOCUMENTS in calls["directories"], (
        "SideStore's own Documents is where it looks on launch"
    )
    assert "/Documents" in calls["directories"], (
        "LiveContainer's Documents is what the Files app exposes, for a manual pick"
    )


def test_a_delivery_failure_is_reported_not_raised(lockdown_dir, monkeypatch):
    """LiveContainer is already installed by then; only the hand-off failed."""
    lockdown_dir({UDID: USBMUX_RECORD})

    async def explode(*_args, **_kwargs):
        raise OSError("device went away")

    monkeypatch.setattr(livecontainer, "_write_documents", explode)

    result = livecontainer.deliver_pairing("com.kdt.livecontainer.T", UDID, UDID)

    assert result["paired"] is False
    assert "device went away" in result["error"]
