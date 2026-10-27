"""Sideload registry + provisioning-profile expiry parsing."""

import datetime
import plistlib

from ipaside_engine import refresh


def _iso(days: float) -> str:
    return (datetime.datetime.now(datetime.timezone.utc)
            + datetime.timedelta(days=days)).isoformat()


def test_registry_roundtrip(isolated_data):
    assert refresh.records() == []
    refresh.record({"bundle_id": "com.a", "name": "A", "expires_at": _iso(5)})
    records = refresh.records()
    assert len(records) == 1
    assert records[0]["bundle_id"] == "com.a"
    assert records[0]["expired"] is False
    assert 4.9 < records[0]["days_left"] <= 5.0
    assert refresh.get("com.a")["name"] == "A"
    assert refresh.forget("com.a") is True
    assert refresh.records() == []
    assert refresh.forget("com.a") is False


def test_records_sorted_by_soonest_expiry(isolated_data):
    refresh.record({"bundle_id": "later", "expires_at": _iso(6)})
    refresh.record({"bundle_id": "soon", "expires_at": _iso(1)})
    order = [r["bundle_id"] for r in refresh.records()]
    assert order == ["soon", "later"]


def test_expired_and_due(isolated_data):
    refresh.record({"bundle_id": "old", "expires_at": _iso(-1)})
    refresh.record({"bundle_id": "soon", "expires_at": _iso(1)})
    refresh.record({"bundle_id": "later", "expires_at": _iso(6)})
    by_id = {r["bundle_id"]: r for r in refresh.records()}
    assert by_id["old"]["expired"] is True
    assert by_id["soon"]["expired"] is False
    due_ids = {r["bundle_id"] for r in refresh.due(2.0)}
    assert due_ids == {"old", "soon"}


def test_profile_expiration_parses_cms_embedded_plist():
    expiry = datetime.datetime(2030, 1, 2, 3, 4, 5)  # plist stores naive UTC
    plist = plistlib.dumps({"ExpirationDate": expiry, "AppIDName": "x"})
    blob = b"\x30\x82\x01\x00 fake CMS prefix" + plist + b"\x00signature-bytes\xff"
    got = refresh.profile_expiration(blob)
    assert got is not None
    assert (got.year, got.month, got.day) == (2030, 1, 2)
    assert got.tzinfo is not None  # normalized to aware UTC


def test_profile_expiration_missing_returns_none():
    assert refresh.profile_expiration(b"not a provisioning profile") is None
