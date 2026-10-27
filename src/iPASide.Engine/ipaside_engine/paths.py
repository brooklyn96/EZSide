"""Filesystem locations for EZSide's cached state.

All mutable, machine-specific data (anisette provisioning, Apple session, signing
material) lives under a single per-user data directory so it is easy to find,
back up, or wipe. Nothing here is ever committed to source control.
"""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

APP_NAME = "EZSide"


def resource_dir() -> Path:
    """Directory of bundled package resources (certs, vendored zsign).

    Works both from source and from the shipped portable-Python build, and still
    honours ``sys._MEIPASS`` so a frozen build would resolve too.
    """
    if getattr(sys, "frozen", False):
        base = getattr(sys, "_MEIPASS", None)
        if base:
            return Path(base) / "ipaside_engine"
    return Path(__file__).parent


DATA_DIR_ENV = "IPASIDE_DATA_DIR"


def installed_app_dir() -> Path | None:
    """The program folder when running from the installed layout, else None.

    The installer ships the engine as ``<install>\\app\\engine\\python\\python.exe``;
    the interpreter (or, failing that, the package inside its site-packages) tells
    us where ``<install>\\app`` is, wherever the user chose to install it. The data
    folder is its sibling, ``<install>\\data``.
    """
    for folder in (Path(sys.executable).parent, *resource_dir().parents):
        if (
            folder.name.lower() == "python"
            and folder.parent.name.lower() == "engine"
            and (folder / "python.exe").is_file()
        ):
            return folder.parent.parent
    return None


def data_dir() -> Path:
    """Application data directory (created if missing).

    In order: ``IPASIDE_DATA_DIR`` (made absolute when relative);
    ``<install folder>\\data`` for an installed copy, next to the program folder
    ``<install folder>\\app``, so the install folder holds everything EZSide writes;
    otherwise the per-user default (``%LOCALAPPDATA%\\EZSide``). The app resolves the
    same order and passes its answer down, so the two can never disagree.
    """
    override = os.environ.get(DATA_DIR_ENV, "").strip()
    if override:
        path = Path(override).absolute()
    elif (app_dir := installed_app_dir()) is not None:
        path = app_dir.parent / "data"
    else:
        base = os.environ.get("LOCALAPPDATA") or os.path.join(
            os.path.expanduser("~"), ".local", "share"
        )
        path = Path(base) / APP_NAME
    path.mkdir(parents=True, exist_ok=True)
    return path


def anisette_dir() -> Path:
    """Directory holding the cached anisette libraries + provisioning state."""
    path = data_dir() / "anisette"
    path.mkdir(parents=True, exist_ok=True)
    return path


def anisette_state_file() -> Path:
    """Combined anisette state (portable libs + provisioning) as one file."""
    return anisette_dir() / "anisette.bin"


def session_dir() -> Path:
    """Directory holding the Apple account session + pending 2FA state."""
    path = data_dir() / "session"
    path.mkdir(parents=True, exist_ok=True)
    return path


def pending_2fa_file() -> Path:
    """Transient state between triggering and submitting a 2FA code."""
    return session_dir() / "pending.json"


def accounts_dir() -> Path:
    """One file per signed-in Apple ID. Never committed."""
    path = session_dir() / "accounts"
    path.mkdir(parents=True, exist_ok=True)
    return path


def account_slug(email: str) -> str:
    """A stable, filesystem-safe name for an account's file.

    Hashed rather than sanitised so no address can collide with another, and so an
    email never appears in a filename — the directory listing of someone's profile
    is not a good place to publish which Apple IDs they use.
    """
    return hashlib.sha256(email.strip().lower().encode("utf-8")).hexdigest()[:16]


def account_file(email: str) -> Path:
    """Authenticated GSA session for one Apple ID (adsid + tokens)."""
    return accounts_dir() / f"{account_slug(email)}.json"


def active_account_file() -> Path:
    """Which of the signed-in accounts commands act on by default."""
    return session_dir() / "active.json"


def legacy_account_file() -> Path:
    """Where the single-account builds kept their one session.

    Read once and migrated; upgrading must not sign anybody out.
    """
    return session_dir() / "account.json"


def signing_dir(account_slug_: str | None = None) -> Path:
    """Signing material (private key, cert, profile, p12).

    Kept per account once one is known, because the material is meaningless
    outside the team that issued it. Sharing one directory between accounts let a
    cached bundle from one Apple ID be read while another was signed in — pointing
    at an App ID on a team the current session cannot even see.
    """
    path = data_dir() / "signing"
    if account_slug_:
        path = path / account_slug_
    path.mkdir(parents=True, exist_ok=True)
    return path


def signed_dir() -> Path:
    """Directory holding signed IPAs the user asked to keep (plus sign-time scratch)."""
    path = data_dir() / "signed"
    path.mkdir(parents=True, exist_ok=True)
    return path


def installs_file() -> Path:
    """Registry of apps this machine has sideloaded (for expiry + auto-refresh)."""
    return data_dir() / "sideloads.json"


def tweaks_dir() -> Path:
    """Cache of dylibs extracted from .deb tweak packages, ready to inject."""
    path = data_dir() / "tweaks"
    path.mkdir(parents=True, exist_ok=True)
    return path


def downloads_dir() -> Path:
    """Directory holding third-party installers the engine fetches for the user.

    Currently only Apple's iTunes installer, which is ~200MB and is downloaded at
    most once. Kept out of the folders above so a user clearing space can tell the
    difference between a redistributable and iPASide's own state.
    """
    path = data_dir() / "downloads"
    path.mkdir(parents=True, exist_ok=True)
    return path


def autorefresh_log() -> Path:
    """Log written by the scheduled background auto-refresh runs."""
    return data_dir() / "autorefresh.log"
