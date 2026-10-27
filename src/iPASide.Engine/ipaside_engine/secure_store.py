"""Protects EZSide's secrets at rest with Windows DPAPI.

Session tokens, the pending 2FA state and pairing records are written through this
module. On Windows the bytes are encrypted for the current user with
CryptProtectData, so another Windows account, or a copy of the data folder taken
to another PC, cannot read them. Other platforms keep the bytes as they are (the
engine only ships on Windows; this keeps the test suite portable).

A protected file is the 4-byte magic ``EZS1`` followed by the DPAPI blob. A file
without the magic is a plaintext file from an older build: it is still read, and
the caller rewrites it protected on its next save.
"""

from __future__ import annotations

import ctypes
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any

MAGIC = b"EZS1"

# Not a secret: a fixed salt so a blob made by some other program running as the
# same user does not decrypt here by accident.
_ENTROPY = b"EZSide"
_CRYPTPROTECT_UI_FORBIDDEN = 0x1


class _DataBlob(ctypes.Structure):
    _fields_ = [("cbData", ctypes.c_uint32), ("pbData", ctypes.c_void_p)]


def _dpapi(function: str, data: bytes) -> bytes:
    """Run CryptProtectData / CryptUnprotectData over [data]; raises OSError."""
    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p
    call = getattr(crypt32, function)
    call.restype = ctypes.c_int

    # Keep the buffers alive for the whole call; the blobs only point into them.
    data_buf = ctypes.create_string_buffer(data, max(len(data), 1))
    entropy_buf = ctypes.create_string_buffer(_ENTROPY, len(_ENTROPY))
    source = _DataBlob(len(data), ctypes.cast(data_buf, ctypes.c_void_p))
    entropy = _DataBlob(len(_ENTROPY), ctypes.cast(entropy_buf, ctypes.c_void_p))
    result = _DataBlob()

    if not call(
        ctypes.byref(source),
        None,
        ctypes.byref(entropy),
        None,
        None,
        _CRYPTPROTECT_UI_FORBIDDEN,
        ctypes.byref(result),
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return ctypes.string_at(result.pbData, result.cbData)
    finally:
        kernel32.LocalFree(result.pbData)


def protect(data: bytes) -> bytes:
    """Encrypt [data] for the current Windows user (identity elsewhere)."""
    if sys.platform != "win32":
        return data
    return _dpapi("CryptProtectData", data)


def unprotect(blob: bytes) -> bytes:
    """Reverse :func:`protect`. Raises OSError for a blob DPAPI rejects."""
    if sys.platform != "win32":
        return blob
    return _dpapi("CryptUnprotectData", blob)


def write_bytes(path: Path, data: bytes) -> None:
    """Write [data] protected, atomically (temp file in the same folder, then replace)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = MAGIC + protect(data)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=f"{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise


def read_bytes(path: Path) -> bytes:
    """Read a file written by :func:`write_bytes`; a legacy plain file comes back as is."""
    raw = Path(path).read_bytes()
    if raw.startswith(MAGIC):
        return unprotect(raw[len(MAGIC):])
    return raw


def write_json(path: Path, obj: Any) -> None:
    """JSON-encode [obj] and store it with :func:`write_bytes`."""
    write_bytes(path, json.dumps(obj).encode("utf-8"))


def read_json(path: Path) -> Any:
    """Load a JSON file written by :func:`write_json`, or a legacy plaintext one.

    Raises OSError (unreadable file, DPAPI refusal) or ValueError (not JSON).
    """
    return json.loads(read_bytes(path).decode("utf-8"))
