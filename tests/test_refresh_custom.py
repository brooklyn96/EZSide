"""Registry handling of records signed with an imported certificate."""

import datetime

from ipaside_engine import refresh


def _iso(days: float) -> str:
    return (datetime.datetime.now(datetime.timezone.utc)
            + datetime.timedelta(days=days)).isoformat()


def _seed():
    refresh.record({"bundle_id": "apple.soon", "expires_at": _iso(1)})
    refresh.record({"bundle_id": "apple.old", "signer": "apple", "expires_at": _iso(-1)})
    refresh.record({"bundle_id": "custom.old", "signer": "custom", "expires_at": _iso(-1)})
    refresh.record({"bundle_id": "custom.soon", "signer": "custom", "expires_at": _iso(10)})
    refresh.record({"bundle_id": "custom.later", "signer": "custom", "expires_at": _iso(200)})
    refresh.record({"bundle_id": "custom.unknown", "signer": "custom"})


def test_due_skips_custom_records(isolated_data):
    _seed()
    assert {r["bundle_id"] for r in refresh.due(2.0)} == {"apple.soon", "apple.old"}
    assert {r["bundle_id"] for r in refresh.due(1000.0)} == {"apple.soon", "apple.old"}


def test_custom_records_lists_only_custom(isolated_data):
    _seed()
    ids = {r["bundle_id"] for r in refresh.custom_records()}
    assert ids == {"custom.old", "custom.soon", "custom.later", "custom.unknown"}
    assert all("days_left" in r for r in refresh.custom_records())


def test_custom_expiring_respects_threshold(isolated_data):
    _seed()
    got = refresh.custom_expiring()
    assert {r["bundle_id"] for r in got} == {"custom.old", "custom.soon"}
    by_id = {r["bundle_id"]: r for r in got}
    assert by_id["custom.old"]["days_left"] < 0
    assert 9.9 < by_id["custom.soon"]["days_left"] <= 10.0
    assert {r["bundle_id"] for r in refresh.custom_expiring(5.0)} == {"custom.old"}
    assert {r["bundle_id"] for r in refresh.custom_expiring(300.0)} == {
        "custom.old", "custom.soon", "custom.later"}


def test_no_custom_records(isolated_data):
    refresh.record({"bundle_id": "apple.soon", "expires_at": _iso(1)})
    assert refresh.custom_records() == []
    assert refresh.custom_expiring() == []
