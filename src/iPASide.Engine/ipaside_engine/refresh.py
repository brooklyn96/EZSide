"""Sideload registry + expiry tracking (the basis of auto-refresh).

A free Apple ID's provisioning profile expires seven days after it is issued, at
which point the sideloaded app stops launching. We record each successful
sideload - the source IPA plus the exact options it was signed with - so the app
can re-sign and reinstall it before it expires, either on demand from the UI or
from a scheduled background task.

The registry is a single JSON file keyed by installed bundle id. It holds no
secrets (only paths + option flags + timestamps). Each app also gets a folder of
its own, data_dir()/apps/<bundle id>-<hash> (see :func:`app_dir`), holding EZSide's copy of the source IPA so a
refresh never depends on the user keeping theirs.

Every write, and every sideload / refresh / forget, runs under
:func:`operation_lock`, so the desktop app and the scheduled background refresh
(two separate engine processes) never interleave.
"""

from __future__ import annotations

import contextlib
import datetime
import hashlib
import json
import os
import plistlib
import re
import shutil
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Iterator

from . import paths, secure_store
from .errors import EngineError

#: How long an operation waits for another EZSide process to finish before giving up.
LOCK_TIMEOUT_SECONDS = 600.0
_LOCK_POLL_SECONDS = 0.25
LOCK_FILE = "engine.lock"
CACHED_IPA = "source.ipa"
_WAIT_MESSAGE = "Waiting for another EZSide operation to finish..."

# A bundle id as Apple allows it (letters, digits, '-', '_' in dot-separated parts). It
# names a folder, so anything else - '..', a slash - gets no cache rather than a path.
_BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$")


class RegistryError(EngineError):
    """The sideload registry could not be read, or another operation holds it."""


def _now() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def _load() -> dict[str, Any]:
    """The registry; ``{}`` when there is none yet.

    A file that is there but unreadable as a registry is moved aside and reported, never
    treated as empty: the next write would otherwise replace every record with one.
    """
    path = paths.installs_file()
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    except OSError as exc:
        raise RegistryError(f"Cannot read the sideload registry {path}: {exc}") from exc
    try:
        data = json.loads(text)
    except ValueError:
        data = None
    if isinstance(data, dict):
        return data

    stamp = _now().strftime("%Y%m%dT%H%M%SZ")
    aside = path.with_name(f"{path.name}.corrupt-{stamp}")
    try:
        os.replace(path, aside)
    except OSError as exc:
        raise RegistryError(
            f"The sideload registry {path} is damaged and could not be moved aside "
            f"({exc}). Move or delete it, then sideload your apps again."
        ) from exc
    raise RegistryError(
        f"The sideload registry was damaged and has been moved to {aside}. EZSide no "
        "longer knows which apps to refresh; sideload them again to track them."
    )


def _save(data: dict[str, Any]) -> None:
    """Write the registry atomically: a temp file beside it, then one rename."""
    path = paths.installs_file()
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=f"{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        secure_store.replace_atomic(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise


# --------------------------------------------------------------------------- #
# Cross-process lock
# --------------------------------------------------------------------------- #
_process_lock = threading.RLock()
_lock_depth = 0
_lock_handle: Any = None


def _try_lock(handle: Any) -> None:
    """Take the OS lock on ``handle`` without waiting; OSError when it is held."""
    if sys.platform == "win32":
        import msvcrt

        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
    else:
        import fcntl

        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)


def _unlock(handle: Any) -> None:
    try:
        if sys.platform == "win32":
            import msvcrt

            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl

            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    finally:
        handle.close()


def _busy() -> RegistryError:
    return RegistryError(
        "Another EZSide operation is running (a sideload or refresh, maybe the scheduled "
        "background refresh). Try again when it has finished."
    )


def _announce_wait() -> None:
    """One progress event on stderr - the engine's progress channel (see __main__'s
    ``_progress_to_stderr``; ``serve`` forwards each line to the app) - so a caller
    waiting on another operation shows a message instead of looking frozen."""
    event = {"event": "progress", "phase": "wait", "percent": None, "step": _WAIT_MESSAGE}
    print(json.dumps(event), file=sys.stderr, flush=True)


def _acquire_file_lock() -> Any:
    handle = open(paths.data_dir() / LOCK_FILE, "a+b")
    deadline = time.monotonic() + LOCK_TIMEOUT_SECONDS
    announced = False
    while True:
        try:
            _try_lock(handle)
            return handle
        except OSError:
            if time.monotonic() >= deadline:
                handle.close()
                raise _busy() from None
            if not announced:
                announced = True
                _announce_wait()
            time.sleep(_LOCK_POLL_SECONDS)


@contextlib.contextmanager
def operation_lock() -> Iterator[None]:
    """Hold data_dir()/engine.lock for a sideload, refresh, forget or registry write.

    Re-entrant within a process (a refresh holds it and the sideload it runs takes it
    again); another process waits up to :data:`LOCK_TIMEOUT_SECONDS`, then gets a
    :class:`RegistryError` saying another operation is running.
    """
    global _lock_depth, _lock_handle
    if not _process_lock.acquire(timeout=LOCK_TIMEOUT_SECONDS):
        raise _busy()
    try:
        if _lock_depth == 0:
            _lock_handle = _acquire_file_lock()
        _lock_depth += 1
        try:
            yield
        finally:
            _lock_depth -= 1
            if _lock_depth == 0:
                handle, _lock_handle = _lock_handle, None
                _unlock(handle)
    finally:
        _process_lock.release()


# --------------------------------------------------------------------------- #
# EZSide's own copy of each app
# --------------------------------------------------------------------------- #
def app_dir(bundle_id: str) -> Path | None:
    """data_dir()/apps/<bundle_id>-<hash>, or None for an id that cannot safely name a folder.

    NTFS ignores case, so two ids that differ only by case would share one folder. The
    name is the lowercase id plus a short hash of the exact id, which keeps them apart.
    """
    if not bundle_id or not _BUNDLE_ID_RE.match(bundle_id):
        return None
    digest = hashlib.sha256(bundle_id.encode("utf-8")).hexdigest()[:8]
    return paths.data_dir() / "apps" / f"{bundle_id.lower()}-{digest}"


def cache_ipa(bundle_id: str, source: str) -> str | None:
    """Copy ``source`` into the app's own folder and return the copy's path.

    None when the id cannot name a folder or the copy fails (a full disk, say): the app
    is installed either way, and a refresh then falls back to the recorded source.
    """
    folder = app_dir(bundle_id)
    if folder is None:
        return None
    target = folder / CACHED_IPA
    try:
        if target.exists() and Path(source).resolve() == target.resolve():
            return str(target)  # this run signed from the cache itself
        folder.mkdir(parents=True, exist_ok=True)
        fd, temp = tempfile.mkstemp(dir=folder, prefix=f"{CACHED_IPA}.", suffix=".tmp")
        os.close(fd)
        try:
            shutil.copyfile(source, temp)
            secure_store.replace_atomic(temp, target)
        except BaseException:
            Path(temp).unlink(missing_ok=True)
            raise
    except OSError:
        return None
    return str(target)


def profile_expiration(profile_bytes: bytes) -> datetime.datetime | None:
    """Extract ``ExpirationDate`` from a ``.mobileprovision`` (CMS-wrapped plist).

    A provisioning profile is a PKCS#7/CMS blob with an XML plist embedded in the
    signed content; slice the plist out and read its expiry.
    """
    start = profile_bytes.find(b"<?xml")
    end = profile_bytes.find(b"</plist>")
    if start == -1 or end == -1:
        return None
    try:
        plist = plistlib.loads(profile_bytes[start : end + len(b"</plist>")])
    except Exception:
        return None
    expiry = plist.get("ExpirationDate")
    if isinstance(expiry, datetime.datetime):
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=datetime.timezone.utc)
        return expiry
    return None


def record(entry: dict[str, Any]) -> dict[str, Any]:
    """Upsert a sideload record, keyed by its installed bundle id."""
    with operation_lock():
        data = _load()
        data[entry["bundle_id"]] = entry
        _save(data)
    return entry


def get(bundle_id: str) -> dict[str, Any] | None:
    return _load().get(bundle_id)


def forget(bundle_id: str) -> bool:
    """Drop a record and EZSide's cached copy of its IPA."""
    with operation_lock():
        data = _load()
        removed = data.pop(bundle_id, None) is not None
        if removed:
            _save(data)
        folder = app_dir(bundle_id)
        if folder is not None:
            shutil.rmtree(folder, ignore_errors=True)
    return removed


def _days_left(expires_at: str | None) -> float | None:
    if not expires_at:
        return None
    try:
        expiry = datetime.datetime.fromisoformat(expires_at)
    except ValueError:
        return None
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc)
    return round((expiry - _now()).total_seconds() / 86400, 2)


def records() -> list[dict[str, Any]]:
    """All recorded sideloads, annotated with ``days_left`` + ``expired``, soonest first."""
    out: list[dict[str, Any]] = []
    for entry in _load().values():
        item = dict(entry)
        days = _days_left(entry.get("expires_at"))
        item["days_left"] = days
        item["expired"] = days is not None and days <= 0
        out.append(item)
    out.sort(key=lambda r: (r.get("days_left") is None, r.get("days_left") or 0.0))
    return out


def due(within_days: float = 2.0) -> list[dict[str, Any]]:
    """Records whose profile expires within ``within_days`` (or already has)."""
    return [
        r for r in records()
        if r.get("days_left") is not None and r["days_left"] <= within_days
    ]
