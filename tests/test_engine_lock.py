"""The sideload registry is written safely and one operation runs at a time.

The desktop app and the scheduled background refresh are separate engine processes
working on the same sideloads.json; a damaged registry must never be quietly replaced.
"""

from __future__ import annotations

import json
import os

import pytest

from ipaside_engine import paths, refresh


def _other_process_holds_the_lock():
    """A second handle on the lock file, locked: what another process would hold."""
    handle = open(paths.data_dir() / refresh.LOCK_FILE, "a+b")
    refresh._try_lock(handle)
    return handle


def _lock_is_free() -> bool:
    try:
        handle = _other_process_holds_the_lock()
    except OSError:
        return False
    refresh._unlock(handle)
    return True


def test_the_lock_is_held_inside_and_released_after():
    with refresh.operation_lock():
        assert not _lock_is_free(), "another process must not get in"
    assert _lock_is_free()


def test_the_lock_is_reentrant_within_a_process():
    with refresh.operation_lock():
        with refresh.operation_lock():  # a refresh running a sideload
            assert refresh._lock_depth == 2
        assert not _lock_is_free(), "the inner release must not free the outer hold"
    assert refresh._lock_depth == 0
    assert _lock_is_free()


def test_the_lock_is_released_when_the_operation_fails():
    with pytest.raises(RuntimeError):
        with refresh.operation_lock():
            raise RuntimeError("boom")
    assert _lock_is_free()


def test_a_held_lock_times_out_with_a_sentence(monkeypatch):
    monkeypatch.setattr(refresh, "LOCK_TIMEOUT_SECONDS", 0.3)
    monkeypatch.setattr(refresh, "_LOCK_POLL_SECONDS", 0.05)
    other = _other_process_holds_the_lock()
    try:
        with pytest.raises(refresh.RegistryError, match="Another EZSide operation is running"):
            with refresh.operation_lock():
                pass
        assert refresh._lock_depth == 0
    finally:
        refresh._unlock(other)


def test_waiting_for_the_lock_emits_one_progress_line(monkeypatch, capsys):
    monkeypatch.setattr(refresh, "LOCK_TIMEOUT_SECONDS", 0.3)
    monkeypatch.setattr(refresh, "_LOCK_POLL_SECONDS", 0.05)
    other = _other_process_holds_the_lock()
    try:
        with pytest.raises(refresh.RegistryError):
            with refresh.operation_lock():
                pass
    finally:
        refresh._unlock(other)

    lines = [json.loads(line) for line in capsys.readouterr().err.splitlines() if line]
    assert lines == [{
        "event": "progress", "phase": "provision", "percent": None,
        "step": "Waiting for another EZSide operation to finish...",
    }]


def test_an_uncontended_lock_prints_nothing(capsys):
    with refresh.operation_lock():
        pass
    assert capsys.readouterr().err == ""


def test_registry_writes_take_the_lock(monkeypatch):
    seen = []
    real_save = refresh._save

    def save(data):
        seen.append(_lock_is_free())
        real_save(data)

    monkeypatch.setattr(refresh, "_save", save)
    refresh.record({"bundle_id": "com.a"})
    refresh.forget("com.a")

    assert seen == [False, False]


# --------------------------------------------------------------------------- #
# Registry file safety
# --------------------------------------------------------------------------- #
def test_a_missing_registry_is_empty():
    assert not paths.installs_file().exists()
    assert refresh.records() == []


@pytest.mark.parametrize("content", ["{not json", "[1, 2]"])
def test_a_damaged_registry_is_moved_aside_and_reported(content):
    registry = paths.installs_file()
    registry.write_text(content, encoding="utf-8")

    with pytest.raises(refresh.RegistryError, match="moved to"):
        refresh.record({"bundle_id": "com.new"})

    assert not registry.exists(), "never overwritten with the one new entry"
    aside = list(registry.parent.glob("sideloads.json.corrupt-*"))
    assert len(aside) == 1
    assert aside[0].read_text(encoding="utf-8") == content, "kept for the user to inspect"


def test_a_write_leaves_no_temp_file_and_a_failed_one_keeps_the_old_registry(monkeypatch):
    refresh.record({"bundle_id": "com.a"})
    registry = paths.installs_file()
    before = registry.read_text(encoding="utf-8")

    def explode(*_a, **_k):
        raise OSError("disk full")

    monkeypatch.setattr(refresh.json, "dump", explode)
    with pytest.raises(OSError, match="disk full"):
        refresh.record({"bundle_id": "com.b"})

    assert registry.read_text(encoding="utf-8") == before
    assert json.loads(before) == {"com.a": {"bundle_id": "com.a"}}
    assert [p.name for p in registry.parent.glob("sideloads.json*")] == ["sideloads.json"]


def test_a_save_survives_a_reader_holding_the_registry_open(monkeypatch):
    refresh.record({"bundle_id": "com.a"})
    real_replace = os.replace
    attempts = []

    def reader_holds_it(src, dst):
        attempts.append(1)
        if len(attempts) < 3:
            raise PermissionError("[WinError 5] Access is denied")
        real_replace(src, dst)

    monkeypatch.setattr(os, "replace", reader_holds_it)
    monkeypatch.setattr(refresh.secure_store.time, "sleep", lambda _s: None)

    refresh.record({"bundle_id": "com.b"})
    monkeypatch.setattr(os, "replace", real_replace)  # not undo(): that drops the data-dir isolation

    assert len(attempts) == 3
    assert set(json.loads(paths.installs_file().read_text(encoding="utf-8"))) == {"com.a", "com.b"}


# --------------------------------------------------------------------------- #
# EZSide's own copy of an app
# --------------------------------------------------------------------------- #
def test_a_bundle_id_that_could_leave_the_apps_folder_gets_no_cache(tmp_path):
    source = tmp_path / "a.ipa"
    source.write_bytes(b"PK")
    for bad in ("..", "../evil", "a/b", "a\\b", "", "a..b"):
        assert refresh.app_dir(bad) is None
        assert refresh.cache_ipa(bad, str(source)) is None


def test_caching_from_the_cache_itself_is_a_no_op(tmp_path):
    source = tmp_path / "a.ipa"
    source.write_bytes(b"PK original")
    cached = refresh.cache_ipa("com.a", str(source))

    assert refresh.cache_ipa("com.a", cached) == cached
    assert open(cached, "rb").read() == b"PK original"


def test_ids_that_differ_only_by_case_get_distinct_folders(tmp_path):
    upper, lower = refresh.app_dir("com.Example.App"), refresh.app_dir("com.example.app")

    assert upper != lower
    assert upper.name.lower() != lower.name.lower(), "distinct even on a case-insensitive disk"
    assert refresh.app_dir("com.Example.App") == upper, "stable for one id"

    source = tmp_path / "a.ipa"
    source.write_bytes(b"PK one")
    refresh.cache_ipa("com.Example.App", str(source))
    source.write_bytes(b"PK two")
    refresh.cache_ipa("com.example.app", str(source))
    assert (upper / refresh.CACHED_IPA).read_bytes() == b"PK one"
    refresh.forget("com.example.app")
    assert (upper / refresh.CACHED_IPA).exists(), "forgetting one leaves the other's cache"
