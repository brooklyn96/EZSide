"""Secrets at rest: DPAPI on Windows, the EZS1 container, atomic writes.

On Windows these run against the real CryptProtectData. Elsewhere the transform is
the identity, so the container, legacy and atomicity rules are still checked.
"""

from __future__ import annotations

import os
import sys

import pytest

from ipaside_engine import secure_store

WINDOWS = sys.platform == "win32"
SECRET = b"adsid=12345;token=very-secret-token"


def test_bytes_round_trip(tmp_path):
    path = tmp_path / "secret.bin"

    secure_store.write_bytes(path, SECRET)

    assert secure_store.read_bytes(path) == SECRET


def test_json_round_trip_keeps_unicode(tmp_path):
    path = tmp_path / "secret.json"
    value = {"email": "nguợi@example.com", "n": 3, "nested": [1, None, True]}

    secure_store.write_json(path, value)

    assert secure_store.read_json(path) == value


def test_empty_payload_round_trips(tmp_path):
    path = tmp_path / "empty.bin"
    secure_store.write_bytes(path, b"")
    assert secure_store.read_bytes(path) == b""


def test_file_starts_with_the_magic(tmp_path):
    path = tmp_path / "secret.bin"
    secure_store.write_bytes(path, SECRET)
    assert path.read_bytes().startswith(b"EZS1")


@pytest.mark.skipif(not WINDOWS, reason="DPAPI exists only on Windows")
def test_secret_is_not_readable_on_disk(tmp_path):
    path = tmp_path / "secret.bin"
    secure_store.write_bytes(path, SECRET)

    raw = path.read_bytes()

    assert SECRET not in raw
    assert b"very-secret-token" not in raw


@pytest.mark.skipif(not WINDOWS, reason="DPAPI exists only on Windows")
def test_protect_changes_the_bytes_and_unprotect_restores_them():
    blob = secure_store.protect(SECRET)

    assert blob != SECRET
    assert secure_store.unprotect(blob) == SECRET


def test_legacy_plaintext_json_is_still_read(tmp_path):
    path = tmp_path / "legacy.json"
    path.write_text('{"email": "a@example.com", "auth_token": "t"}', encoding="utf-8")

    assert secure_store.read_json(path) == {"email": "a@example.com", "auth_token": "t"}


def test_legacy_raw_bytes_are_returned_as_they_are(tmp_path):
    path = tmp_path / "legacy.plist"
    path.write_bytes(b"<?xml version='1.0'?><plist/>")

    assert secure_store.read_bytes(path) == b"<?xml version='1.0'?><plist/>"


def test_rewriting_a_legacy_file_protects_it(tmp_path):
    path = tmp_path / "legacy.json"
    path.write_text('{"a": 1}', encoding="utf-8")

    secure_store.write_json(path, secure_store.read_json(path))

    assert path.read_bytes().startswith(b"EZS1")
    assert secure_store.read_json(path) == {"a": 1}


def test_atomic_write_leaves_no_temp_file_and_replaces_the_old_one(tmp_path):
    path = tmp_path / "secret.json"
    secure_store.write_json(path, {"v": 1})
    secure_store.write_json(path, {"v": 2})

    assert secure_store.read_json(path) == {"v": 2}
    assert [p.name for p in tmp_path.iterdir()] == ["secret.json"]


def test_a_failed_write_keeps_the_old_file_and_cleans_up(tmp_path, monkeypatch):
    path = tmp_path / "secret.json"
    secure_store.write_json(path, {"v": 1})

    def boom(src, dst):
        raise OSError("disk full")

    monkeypatch.setattr(os, "replace", boom)
    with pytest.raises(OSError, match="disk full"):
        secure_store.write_json(path, {"v": 2})
    monkeypatch.undo()

    assert secure_store.read_json(path) == {"v": 1}
    assert [p.name for p in tmp_path.iterdir()] == ["secret.json"]


def test_write_creates_missing_folders(tmp_path):
    path = tmp_path / "a" / "b" / "secret.json"
    secure_store.write_json(path, {"v": 1})
    assert secure_store.read_json(path) == {"v": 1}


def test_a_corrupt_blob_raises(tmp_path):
    path = tmp_path / "secret.json"
    path.write_bytes(b"EZS1" + b"this is not a dpapi blob")

    # OSError from DPAPI on Windows; ValueError from the JSON parse elsewhere.
    with pytest.raises((OSError, ValueError)):
        secure_store.read_json(path)


@pytest.mark.skipif(not WINDOWS, reason="DPAPI exists only on Windows")
def test_a_truncated_blob_raises_oserror(tmp_path):
    path = tmp_path / "secret.bin"
    secure_store.write_bytes(path, SECRET)
    path.write_bytes(path.read_bytes()[:20])

    with pytest.raises(OSError):
        secure_store.read_bytes(path)


def test_a_missing_file_raises_oserror(tmp_path):
    with pytest.raises(OSError):
        secure_store.read_json(tmp_path / "nope.json")
