"""Tests for keeping more than one Apple ID signed in.

The feature exists because of a concrete failure: sign in with a second account,
refresh an app the first one signed, and it is re-signed by a different team. iOS
will not install that over the copy already on the phone, so the app quietly stops
working — the opposite of what a refresh is for. These tests pin the pieces that
prevent it: per-account storage, a remembered team per account, and a refresh that
acts as the account which signed the app.
"""

from __future__ import annotations

import json
import os
import sys
import time

import pytest

from ipaside_engine import gsa, paths

ONE = "first@example.com"
TWO = "second@example.com"


def sign_in(email: str, *, token: str = "token", team: str | None = None) -> None:
    """Write an account file the way a completed login would."""
    gsa._save_account(
        email,
        {"adsid": f"adsid-{email}", "GsIdmsToken": "idms"},
        {"token": token, "expiry": None},
    )
    if team:
        gsa.remember_team(email, team)


# --- storage ---------------------------------------------------------------- #

def test_one_account_is_active_without_being_chosen():
    sign_in(ONE)

    state = gsa.accounts()
    assert [a["email"] for a in state["accounts"]] == [ONE]
    assert state["active"] == ONE
    assert gsa.load_session()["email"] == ONE


def test_a_second_sign_in_becomes_active_and_the_first_is_kept():
    sign_in(ONE)
    sign_in(TWO)

    state = gsa.accounts()
    assert sorted(a["email"] for a in state["accounts"]) == sorted([ONE, TWO])
    assert state["active"] == TWO, "signing in is a deliberate act; use that account"
    assert gsa.load_session()["email"] == TWO


def test_switching_back_does_not_require_the_password_again():
    sign_in(ONE)
    sign_in(TWO)

    gsa.use_account(ONE)

    assert gsa.load_session()["email"] == ONE
    assert gsa.status()["email"] == ONE
    assert gsa.status()["account_count"] == 2


def test_switching_to_an_account_that_is_not_signed_in_is_refused():
    sign_in(ONE)
    with pytest.raises(gsa.GsaError, match="not signed in"):
        gsa.use_account("nobody@example.com")


def test_an_account_with_no_developer_token_cannot_be_used():
    sign_in(ONE, token="")
    with pytest.raises(gsa.GsaError, match="sign in again"):
        gsa.use_account(ONE)


def test_each_account_gets_its_own_file_and_no_email_appears_in_it():
    sign_in(ONE)
    sign_in(TWO)

    names = [p.name for p in paths.accounts_dir().glob("*.json")]
    assert len(names) == 2, "one file per account"
    assert not any("example.com" in name for name in names), (
        "a directory listing should not publish which Apple IDs someone uses"
    )


# --- signing out ------------------------------------------------------------ #

def test_signing_out_one_account_leaves_the_other_alone():
    sign_in(ONE)
    sign_in(TWO)

    result = gsa.logout(TWO)

    assert result["removed"] == [TWO]
    assert [a["email"] for a in gsa.accounts()["accounts"]] == [ONE]
    # The remaining account is picked up without being chosen again.
    assert gsa.load_session()["email"] == ONE


def test_signing_out_with_no_address_removes_everything():
    sign_in(ONE)
    sign_in(TWO)

    result = gsa.logout()

    assert sorted(result["removed"]) == sorted([ONE, TWO])
    assert gsa.accounts() == {"accounts": [], "active": None}
    assert not gsa.status()["authenticated"]


def test_signing_out_removes_the_signing_folder_under_the_engine_lock(monkeypatch):
    """The other engine process may be signing from that folder."""
    from ipaside_engine import refresh

    sign_in(ONE)
    folder = paths.signing_dir(paths.account_slug(ONE))
    depth: list[int] = []
    real = gsa.shutil.rmtree
    monkeypatch.setattr(
        gsa.shutil, "rmtree", lambda path: depth.append(refresh._lock_depth) or real(path)
    )

    gsa.logout(ONE)

    assert depth and min(depth) >= 1, "held (re-entrantly, inside the whole sign-out's lock)"
    assert not folder.exists()
    assert refresh._lock_depth == 0, "and released"


def test_signing_out_holds_the_engine_lock_until_the_account_file_is_gone(monkeypatch):
    """Else an operation in the other process could slip in between the key folder going and
    the account file going, and make a new key folder for the account being signed out."""
    from ipaside_engine import refresh

    sign_in(ONE)
    account = paths.account_file(ONE)
    acquisitions: list[bool] = []
    real = refresh.operation_lock

    class Spy:
        def __enter__(self):
            self.outer = real()
            self.outer.__enter__()
            acquisitions.append(account.exists())

        def __exit__(self, *exc):
            acquisitions.append(account.exists())  # state at the moment of release
            return self.outer.__exit__(*exc)

    monkeypatch.setattr(refresh, "operation_lock", Spy)

    gsa.logout(ONE)

    # One acquisition for the whole sign-out (the signing folder's own lock is re-entrant
    # but would show up here as a second pair), and the file is gone before it is released.
    assert acquisitions[0] is True
    assert acquisitions[-1] is False


def test_signing_out_is_one_lock_acquisition_for_every_account(monkeypatch):
    from ipaside_engine import refresh

    sign_in(ONE)
    sign_in(TWO)
    entered: list[int] = []
    real = refresh.operation_lock

    class Spy:
        def __enter__(self):
            entered.append(refresh._lock_depth)
            self.outer = real()
            self.outer.__enter__()

        def __exit__(self, *exc):
            return self.outer.__exit__(*exc)

    monkeypatch.setattr(refresh, "operation_lock", Spy)

    gsa.logout()

    assert entered.count(0) == 1, "taken once from outside"
    assert gsa.accounts() == {"accounts": [], "active": None}


def test_signing_out_an_unknown_account_says_so():
    sign_in(ONE)
    with pytest.raises(gsa.GsaError, match="not signed in"):
        gsa.logout("nobody@example.com")


# --- migration from the single-account build -------------------------------- #

def test_an_existing_session_survives_the_upgrade():
    # What a build before this feature left on disk.
    paths.legacy_account_file().write_text(
        json.dumps(
            {
                "email": ONE,
                "adsid": "legacy-adsid",
                "GsIdmsToken": "idms",
                "auth_token": "legacy-token",
            }
        ),
        encoding="utf-8",
    )

    session = gsa.load_session()

    assert session["email"] == ONE, "upgrading must not sign anybody out"
    assert session["auth_token"] == "legacy-token"
    assert not paths.legacy_account_file().exists(), "and must not leave two copies"
    assert gsa.accounts()["active"] == ONE


def test_a_corrupt_legacy_file_does_not_break_signing_in():
    paths.legacy_account_file().write_text("{ not json", encoding="utf-8")

    with pytest.raises(gsa.GsaError, match="not signed in"):
        gsa.load_session()

    # Cleared rather than left to fail every future read.
    assert not paths.legacy_account_file().exists()
    sign_in(ONE)
    assert gsa.load_session()["email"] == ONE


# --- teams, and refreshing as the right account ----------------------------- #

def test_an_account_remembers_the_team_it_provisions_under():
    sign_in(ONE, team="TEAMONE")
    assert gsa.account_for_team("TEAMONE") == ONE
    assert gsa.account_for_team("NOSUCHTEAM") is None


def test_the_team_survives_signing_in_again():
    sign_in(ONE, team="TEAMONE")
    sign_in(ONE)  # re-login, e.g. after the token expired

    assert gsa.account_for_team("TEAMONE") == ONE, (
        "losing this would send a refresh to whichever account was active"
    )


def test_acting_as_overrides_the_active_account_only_for_the_block():
    sign_in(ONE)
    sign_in(TWO)
    assert gsa.load_session()["email"] == TWO

    with gsa.acting_as(ONE):
        assert gsa.load_session()["email"] == ONE

    assert gsa.load_session()["email"] == TWO, "the user's own choice is untouched"


def test_acting_as_nothing_is_a_no_op():
    sign_in(ONE)
    with gsa.acting_as(None):
        assert gsa.load_session()["email"] == ONE


def test_acting_as_still_restores_after_a_failure():
    sign_in(ONE)
    sign_in(TWO)

    with pytest.raises(ValueError):
        with gsa.acting_as(ONE):
            raise ValueError("the refresh blew up")

    assert gsa.load_session()["email"] == TWO


# --- ambiguity -------------------------------------------------------------- #

def test_two_accounts_and_no_pointer_asks_rather_than_guessing():
    sign_in(ONE)
    sign_in(TWO)
    paths.active_account_file().unlink()

    with pytest.raises(gsa.GsaError, match="none is selected"):
        gsa.load_session()


def test_a_pointer_at_a_removed_account_falls_back_when_only_one_is_left():
    sign_in(ONE)
    sign_in(TWO)
    # TWO is active; remove its file behind the pointer's back.
    paths.account_file(TWO).unlink()

    assert gsa.load_session()["email"] == ONE


# --- signing material isolation --------------------------------------------- #

def test_signing_material_is_kept_per_account():
    one = paths.signing_dir(paths.account_slug(ONE))
    two = paths.signing_dir(paths.account_slug(TWO))

    assert one != two, (
        "shared, a second Apple ID finds the first one's private key, fails to "
        "match it against its own team's certificates, and revokes that team's "
        "only certificate to recover"
    )
    assert one.parent == two.parent == paths.signing_dir()


def test_the_account_slug_is_stable_and_case_insensitive():
    assert paths.account_slug(ONE) == paths.account_slug(ONE.upper())
    assert paths.account_slug(f"  {ONE} ") == paths.account_slug(ONE)
    assert paths.account_slug(ONE) != paths.account_slug(TWO)


# --- secrets at rest -------------------------------------------------------- #

def test_account_files_are_protected_and_still_load():
    sign_in(ONE, token="very-secret-token")

    raw = paths.account_file(ONE).read_bytes()

    assert raw.startswith(b"EZS1")
    assert gsa.load_session()["auth_token"] == "very-secret-token"
    assert gsa.status()["has_auth_token"] is True
    assert [a["email"] for a in gsa.list_accounts()] == [ONE]
    if sys.platform == "win32":
        assert b"very-secret-token" not in raw
        assert ONE.encode() not in raw


def test_the_active_pointer_stays_plain():
    sign_in(ONE)
    assert json.loads(paths.active_account_file().read_text(encoding="utf-8")) == {"email": ONE}


def test_a_plaintext_account_from_an_older_build_is_read_and_protected_on_next_save():
    path = paths.account_file(ONE)
    path.write_text(
        json.dumps(
            {
                "email": ONE,
                "adsid": "old-adsid",
                "GsIdmsToken": "idms",
                "auth_token": "old-token",
                "team_id": "TEAMONE",
            }
        ),
        encoding="utf-8",
    )

    assert gsa.load_session(ONE)["auth_token"] == "old-token"
    assert gsa.account_for_team("TEAMONE") == ONE
    assert not path.read_bytes().startswith(b"EZS1"), "reading alone does not rewrite"

    sign_in(ONE, token="new-token")  # the next save

    assert path.read_bytes().startswith(b"EZS1")
    assert gsa.load_session(ONE)["auth_token"] == "new-token"
    assert gsa.account_for_team("TEAMONE") == ONE, "the team survives the rewrite"


def test_remembering_a_team_rewrites_a_plaintext_account_protected():
    path = paths.account_file(ONE)
    path.write_text(
        json.dumps({"email": ONE, "adsid": "a", "auth_token": "t"}), encoding="utf-8"
    )

    gsa.remember_team(ONE, "TEAMONE")

    assert path.read_bytes().startswith(b"EZS1")
    assert gsa.account_for_team("TEAMONE") == ONE


def test_the_legacy_single_account_file_is_migrated_into_a_protected_file():
    paths.legacy_account_file().write_text(
        json.dumps({"email": ONE, "adsid": "a", "auth_token": "legacy-token"}),
        encoding="utf-8",
    )

    assert gsa.load_session()["auth_token"] == "legacy-token"
    assert paths.account_file(ONE).read_bytes().startswith(b"EZS1")


# --- pending 2FA ------------------------------------------------------------ #

def test_pending_2fa_is_protected_and_round_trips():
    gsa._save_pending(ONE, "adsid", "very-secret-idms", "sms", phone_id=3)

    raw = paths.pending_2fa_file().read_bytes()
    pending = gsa._load_pending()

    assert raw.startswith(b"EZS1")
    assert pending == {
        "email": ONE,
        "adsid": "adsid",
        "idms": "very-secret-idms",
        "method": "sms",
        "phone_id": 3,
    }
    if sys.platform == "win32":
        assert b"very-secret-idms" not in raw


def _age(path, seconds):
    old = time.time() - seconds
    os.utime(path, (old, old))


def test_a_pending_sign_in_is_still_usable_within_fifteen_minutes():
    gsa._save_pending(ONE, "adsid", "idms", "trusteddevice")
    _age(paths.pending_2fa_file(), 14 * 60)

    assert gsa._load_pending()["email"] == ONE


def test_an_abandoned_pending_sign_in_is_ignored_and_deleted():
    gsa._save_pending(ONE, "adsid", "idms", "trusteddevice")
    _age(paths.pending_2fa_file(), 16 * 60)

    assert gsa._load_pending() is None
    assert not paths.pending_2fa_file().exists()
    with pytest.raises(gsa.GsaError, match="no pending 2FA"):
        gsa.complete_2fa(ONE, "password", "123456")


def test_a_plaintext_pending_file_from_an_older_build_is_still_read():
    paths.pending_2fa_file().write_text(
        json.dumps({"email": ONE, "adsid": "a", "idms": "i", "method": "sms"}),
        encoding="utf-8",
    )

    assert gsa._load_pending()["idms"] == "i"


def test_an_unreadable_pending_file_counts_as_none():
    paths.pending_2fa_file().write_bytes(b"EZS1" + b"garbage that is not a blob")

    assert gsa._load_pending() is None
    assert not paths.pending_2fa_file().exists()


def test_status_sweeps_an_abandoned_pending_sign_in():
    gsa._save_pending(ONE, "adsid", "idms", "trusteddevice")
    _age(paths.pending_2fa_file(), 16 * 60)

    gsa.status()

    assert not paths.pending_2fa_file().exists()


def test_status_keeps_a_pending_sign_in_that_is_still_young():
    gsa._save_pending(ONE, "adsid", "idms", "trusteddevice")

    gsa.status()

    assert paths.pending_2fa_file().exists()


# --- signing out removes the key -------------------------------------------- #

def _signing_folder(email):
    folder = paths.signing_dir(paths.account_slug(email))
    (folder / "identity.p12").write_bytes(b"p12")
    (folder / "certificate.json").write_text("{}", encoding="utf-8")
    return folder


def test_signing_out_one_account_deletes_its_signing_folder_only():
    sign_in(ONE)
    sign_in(TWO)
    one, two = _signing_folder(ONE), _signing_folder(TWO)

    gsa.logout(TWO)

    assert not two.exists(), "the private key must not stay behind"
    assert one.exists()


def test_signing_out_everyone_deletes_every_signing_folder():
    sign_in(ONE)
    sign_in(TWO)
    one, two = _signing_folder(ONE), _signing_folder(TWO)

    gsa.logout()

    assert not one.exists() and not two.exists()


def test_signing_out_everyone_also_removes_an_account_dpapi_cannot_open():
    sign_in(ONE)
    sign_in(TWO)
    one, two = _signing_folder(ONE), _signing_folder(TWO)
    paths.account_file(TWO).write_bytes(b"EZS1" + b"garbage that is not a blob")

    result = gsa.logout()

    assert result["removed"] == [ONE], "only the readable account has an address to report"
    assert not list(paths.accounts_dir().glob("*.json"))
    assert not one.exists() and not two.exists(), "the private key must not stay behind"


def test_signing_out_without_a_signing_folder_still_works():
    sign_in(ONE)
    gsa.logout(ONE)
    assert gsa.accounts()["accounts"] == []


def test_a_signing_folder_that_cannot_be_deleted_keeps_the_account_signed_in(monkeypatch):
    sign_in(ONE)
    _signing_folder(ONE)

    def locked(path, *args, **kwargs):
        raise PermissionError("in use")

    monkeypatch.setattr(gsa.shutil, "rmtree", locked)

    with pytest.raises(gsa.GsaError, match="could not delete the signing key folder"):
        gsa.logout(ONE)
    assert [a["email"] for a in gsa.list_accounts()] == [ONE]


def test_an_unreadable_account_file_asks_to_sign_in_again():
    sign_in(ONE)
    paths.account_file(ONE).write_bytes(b"EZS1" + b"garbage that is not a blob")

    with pytest.raises(gsa.GsaError, match="sign in again"):
        gsa.load_session(ONE)
    assert gsa.list_accounts() == [], "an unreadable file is skipped, as a corrupt one always was"
