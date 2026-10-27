"""Tests for choosing which Apple ID a refresh re-signs under.

Found live: a scheduled background refresh of an app signed by one Apple ID, while
a different one was signed in, reached Apple and came back with bare error 9401
("An App ID with Identifier 'com.burbn.instagram.V872QWK5TY' is not available"),
which reads like a problem with the app rather than with which account is in use.
"""

from __future__ import annotations

import pytest

from ipaside_engine import gsa, sideload

MINE = "mine@example.com"
THEIRS = "theirs@example.com"
MY_TEAM = "MYTEAM0001"
THEIR_TEAM = "THEIRTEAM1"


def sign_in(email: str, *, team: str | None = None) -> None:
    gsa._save_account(
        email,
        {"adsid": f"adsid-{email}", "GsIdmsToken": "idms"},
        {"token": "token", "expiry": None},
    )
    if team:
        gsa.remember_team(email, team)


def record(team: str | None, *, name: str = "Instagram") -> dict[str, object]:
    return {
        "bundle_id": f"com.example.app.{team or 'none'}",
        "name": name,
        "team_id": team,
    }


def effective_account(entry: dict[str, object]) -> str | None:
    """Who the refresh will actually act as.

    ``_refresh_account`` returns None to mean "no override, use the active
    account", so tests compare the account that results rather than which of the
    two equivalent representations was chosen.
    """
    chosen = sideload._refresh_account(entry)
    return chosen or gsa.status().get("email")


@pytest.fixture
def apple_says(monkeypatch):
    """Stubs the one Apple call the chooser is allowed to make."""

    def _set(team: str | None):
        def list_teams():
            if team is None:
                raise RuntimeError("Apple unreachable")
            return [{"teamId": team}]

        monkeypatch.setattr(sideload.developer, "list_teams", list_teams)

    return _set


def test_it_picks_the_account_that_signed_the_app(apple_says):
    sign_in(MINE, team=MY_TEAM)
    sign_in(THEIRS, team=THEIR_TEAM)  # active, and the wrong one
    apple_says(THEIR_TEAM)

    assert effective_account(record(MY_TEAM)) == MINE


def test_the_active_account_is_used_when_it_is_the_right_one(apple_says):
    sign_in(MINE, team=MY_TEAM)
    apple_says(MY_TEAM)

    assert effective_account(record(MY_TEAM)) == MINE


def test_an_unmapped_active_account_is_asked_about_once_and_remembered(apple_says):
    sign_in(MINE)  # signed in, but has never provisioned, so no team recorded
    apple_says(MY_TEAM)

    assert effective_account(record(MY_TEAM)) == MINE
    assert gsa.account_for_team(MY_TEAM) == MINE, (
        "the answer should be kept, so the next refresh needs no round trip"
    )


def test_the_wrong_account_is_refused_with_a_sentence(apple_says):
    sign_in(THEIRS, team=THEIR_TEAM)
    apple_says(THEIR_TEAM)

    with pytest.raises(sideload.SideloadError) as caught:
        sideload._refresh_account(record(MY_TEAM, name="Instagram"))

    message = str(caught.value)
    assert "Instagram" in message, "say which app"
    assert MY_TEAM in message, "say which team it needs"
    assert THEIR_TEAM in message, "and which team is in use"
    assert THEIRS in message, "and who is signed in"
    assert "Sign in" in message, "and what to do about it"
    assert "9401" not in message


def test_a_record_from_before_teams_were_tracked_still_refreshes(apple_says):
    sign_in(MINE, team=MY_TEAM)
    apple_says(MY_TEAM)

    assert effective_account(record(None)) == MINE


def test_being_offline_does_not_turn_into_the_wrong_complaint(apple_says):
    sign_in(MINE)
    apple_says(None)  # Apple unreachable

    # Better to let the refresh fail with the real reason than to blame the
    # account for a network problem.
    assert sideload._refresh_account(record(MY_TEAM)) is None


def test_the_mapping_is_used_without_asking_apple(monkeypatch):
    sign_in(MINE, team=MY_TEAM)
    sign_in(THEIRS, team=THEIR_TEAM)

    def explode():
        raise AssertionError("should not have needed to ask Apple")

    monkeypatch.setattr(sideload.developer, "list_teams", explode)

    assert sideload._refresh_account(record(MY_TEAM)) == MINE
