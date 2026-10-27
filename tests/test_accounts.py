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
