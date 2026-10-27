"""Tests for the doctor's device check: usbmux lists one entry per transport, so
a phone that is both plugged in and on Wi-Fi must still be reported as one device.
"""

import pytest

from ipaside_engine import device, doctor

UDID = "935cbbb9b82d25d15566e5939bcea5677b1c44ae"
OTHER = "0f1e2d3c4b5a69788796a5b4c3d2e1f009876543"


@pytest.fixture
def fake_devices(monkeypatch):
    """Replace the usbmux enumeration with a fixed list."""

    def install(entries):
        monkeypatch.setattr(device, "list_devices", lambda: entries)

    return install


def test_one_phone_on_two_transports_counts_once(fake_devices):
    fake_devices([
        {"serial": UDID, "connection_type": "Network"},
        {"serial": UDID, "connection_type": "USB"},
    ])
    check = doctor._check_devices()
    assert check["status"] == doctor.OK
    # USB leads, matching the connection policy that prefers it.
    assert check["detail"] == f"1 device: {UDID} (USB/Network)"


def test_two_phones_count_separately(fake_devices):
    fake_devices([
        {"serial": UDID, "connection_type": "USB"},
        {"serial": OTHER, "connection_type": "Network"},
    ])
    assert doctor._check_devices()["detail"] == (
        f"2 devices: {UDID} (USB), {OTHER} (Network)"
    )


def test_single_usb_phone_reads_naturally(fake_devices):
    fake_devices([{"serial": UDID, "connection_type": "USB"}])
    assert doctor._check_devices()["detail"] == f"1 device: {UDID} (USB)"


def test_duplicate_transport_is_not_repeated(fake_devices):
    fake_devices([
        {"serial": UDID, "connection_type": "USB"},
        {"serial": UDID, "connection_type": "USB"},
    ])
    assert doctor._check_devices()["detail"] == f"1 device: {UDID} (USB)"


def test_missing_fields_do_not_crash(fake_devices):
    fake_devices([{}])
    assert doctor._check_devices()["detail"] == "1 device: ? (?)"


def test_no_devices_warns_with_guidance(fake_devices):
    fake_devices([])
    check = doctor._check_devices()
    assert check["status"] == doctor.WARN
    assert "Trust" in check["detail"]


def test_enumeration_failure_warns_rather_than_raising(fake_devices, monkeypatch):
    def boom():
        raise RuntimeError("usbmuxd is not running")

    monkeypatch.setattr(device, "list_devices", boom)
    check = doctor._check_devices()
    assert check["status"] == doctor.WARN
    assert "usbmuxd is not running" in check["detail"]
