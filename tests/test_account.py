"""Reporting and tidying a developer account, per Apple ID.

The point of this module is to make visible what iPASide had been guessing at. Two things
it must get right, because both mislead by default:

* whose certificate is whose - a team routinely holds one per tool, and revoking the wrong
  one stops another tool's apps from opening;
* that registered app identifiers are not the weekly registration ceiling.
"""

from __future__ import annotations

import contextlib

import pytest

from ipaside_engine import account, developer, gsa, provision

TEAM = "ASK9QR9SBC"
OUR_SERIAL = "29C8EC73C890EBCA0EE74E017975D97B"

OURS = {
    "serialNumber": OUR_SERIAL,
    "machineName": provision.CERTIFICATE_MACHINE_NAME,
    "name": "iOS Development: Someone",
    "expirationDate": "2027-07-26 11:13:24",
    "certificateType": {"name": "iOS Development", "certificateTypeDisplayId": "5QPB9NHCEI"},
}
SIDESTORE = {
    "serialNumber": "6739B3069372332966091DE3341C96BE",
    "machineName": "SideStore - Someone's iPhone",
    "certificateType": {"name": "iOS Development", "certificateTypeDisplayId": "5QPB9NHCEI"},
}
XCODE = {
    "serialNumber": "63EDA768F91B8C905FC6877994086D66",
    "machineName": "Someone's MacBook Pro",
    "certificateType": {"name": "Development", "certificateTypeDisplayId": "83Q87W3TGH"},
}

APP_IDS = [
    {"appIdId": "AAA1", "identifier": "com.kdt.livecontainer.ASK9QR9SBC", "name": "LiveContainer"},
    {"appIdId": "BBB2", "identifier": "com.burbn.instagram.ASK9QR9SBC", "name": "Instagram"},
]
DEVICES = [{"deviceId": "D1", "name": "A phone", "deviceNumber": "935cbbb9", "devicePlatform": "ios"}]


@pytest.fixture
def portal(monkeypatch):
    """Stubs the developer API and the session, recording what was asked and of whom."""

    def _make(certs=(OURS, SIDESTORE, XCODE), bundle=None, acted=None):
        state = {"revoked": [], "deleted": [], "acted_as": acted if acted is not None else []}

        monkeypatch.setattr(developer, "list_teams", lambda: [
            {"teamId": TEAM, "name": "Someone", "type": "Individual"}
        ])
        monkeypatch.setattr(developer, "list_certificates", lambda _t: list(certs))
        monkeypatch.setattr(developer, "list_app_ids", lambda _t: list(APP_IDS))
        monkeypatch.setattr(developer, "list_devices", lambda _t: list(DEVICES))
        monkeypatch.setattr(
            developer, "revoke_certificate",
            lambda _t, serial: state["revoked"].append(serial),
        )
        monkeypatch.setattr(
            developer, "delete_app_id",
            lambda _t, app_id: state["deleted"].append(app_id),
        )
        monkeypatch.setattr(gsa, "load_session", lambda *a, **k: {"email": "a@b.c"})

        default_bundle = {"team_id": TEAM, "certificate_serial": OUR_SERIAL}
        chosen = default_bundle if bundle is None else bundle

        def load_bundle():
            if chosen is False:
                raise gsa.GsaError("no signing bundle")
            return chosen

        monkeypatch.setattr(provision, "load_bundle", load_bundle)

        @contextlib.contextmanager
        def acting_as(email):
            state["acted_as"].append(email)
            yield

        monkeypatch.setattr(gsa, "acting_as", acting_as)
        return state

    return _make


# --------------------------------------------------------------------------- #
# Whose certificate is whose
# --------------------------------------------------------------------------- #
def test_our_certificate_is_marked_as_in_use_here(portal):
    portal()
    certs = {c["serial"]: c for c in account.overview()["certificates"]}

    mine = certs[OUR_SERIAL]
    assert mine["ours"] is True
    assert mine["in_use_here"] is True


@pytest.mark.parametrize("other", [SIDESTORE, XCODE], ids=["sidestore", "xcode"])
def test_another_tools_certificate_is_not_claimed_as_ours(portal, other):
    portal()
    certs = {c["serial"]: c for c in account.overview()["certificates"]}

    theirs = certs[other["serialNumber"]]
    assert theirs["ours"] is False
    assert theirs["in_use_here"] is False
    assert theirs["machine"] == other["machineName"]


def test_a_certificate_iPASide_issued_elsewhere_is_ours_but_not_in_use_here(portal):
    """Recognised by machine name, so it can be tidied - but losing it breaks nothing here."""
    elsewhere = {
        "serialNumber": "OTHERMACHINE01",
        "machineName": provision.CERTIFICATE_MACHINE_NAME,
        "certificateType": {"name": "iOS Development"},
    }
    portal(certs=(OURS, elsewhere))
    certs = {c["serial"]: c for c in account.overview()["certificates"]}

    assert certs["OTHERMACHINE01"]["ours"] is True
    assert certs["OTHERMACHINE01"]["in_use_here"] is False


def test_a_bundle_for_a_different_team_does_not_mark_anything_in_use(portal):
    """Another Apple ID's cached certificate says nothing about this team's."""
    portal(bundle={"team_id": "OTHERTEAM1", "certificate_serial": OUR_SERIAL})

    assert all(not c["in_use_here"] for c in account.overview()["certificates"])


def test_no_cached_bundle_is_not_an_error(portal):
    """An account that has never provisioned still has an account to report on."""
    portal(bundle=False)

    report = account.overview()

    assert len(report["certificates"]) == 3
    assert all(not c["in_use_here"] for c in report["certificates"])


# --------------------------------------------------------------------------- #
# App identifiers, and the limit that is not what it looks like
# --------------------------------------------------------------------------- #
def test_registered_identifiers_are_reported_separately_from_the_weekly_limit(portal):
    portal()
    report = account.overview()

    assert report["registered_app_ids"] == 2
    assert report["weekly_app_id_limit"] == account.WEEKLY_APP_ID_LIMIT
    # Deliberately two fields: one fraction would read as spare capacity for the week,
    # which is how somebody gets refused mid-install having been told they had room.
    assert "app_id_count" not in report


def test_app_ids_carry_the_id_needed_to_delete_them(portal):
    portal()
    assert [a["id"] for a in account.overview()["app_ids"]] == ["AAA1", "BBB2"]


def test_deleting_an_identifier_reports_which_one(portal):
    state = portal()

    result = account.delete_app_id("AAA1")

    assert state["deleted"] == ["AAA1"]
    assert result["identifier"] == "com.kdt.livecontainer.ASK9QR9SBC"
    assert result["remaining"] == 1


# --------------------------------------------------------------------------- #
# Revoking
# --------------------------------------------------------------------------- #
def test_revoking_ours_says_the_local_apps_are_now_broken(portal):
    state = portal()

    result = account.revoke_certificate(OUR_SERIAL)

    assert state["revoked"] == [OUR_SERIAL]
    assert result["was_ours"] is True
    assert result["invalidates_local_apps"] is True


def test_revoking_another_tools_certificate_does_not_claim_to_break_ours(portal):
    state = portal()

    result = account.revoke_certificate(SIDESTORE["serialNumber"])

    assert state["revoked"] == [SIDESTORE["serialNumber"]]
    assert result["was_ours"] is False
    assert result["invalidates_local_apps"] is False
    assert result["machine"] == SIDESTORE["machineName"]


def test_revoking_something_that_is_not_there_is_refused_before_asking_apple(portal):
    state = portal()

    with pytest.raises(developer.DeveloperServicesError, match="No certificate"):
        account.revoke_certificate("NOTHINGLIKETHIS")

    assert state["revoked"] == []


# --------------------------------------------------------------------------- #
# Multiple Apple IDs
# --------------------------------------------------------------------------- #
def test_reporting_runs_as_the_account_asked_about(portal):
    """iPASide can hold several signed in; asking about one must not disturb another."""
    state = portal()

    account.overview("second@example.com")

    assert state["acted_as"], "the lookups must run inside acting_as"
    assert set(state["acted_as"]) == {"second@example.com"}


def test_omitting_the_account_means_the_active_one(portal):
    state = portal()

    account.overview()

    assert set(state["acted_as"]) == {None}


@pytest.mark.parametrize(
    "action",
    [
        lambda: account.revoke_certificate(OUR_SERIAL, "second@example.com"),
        lambda: account.delete_app_id("AAA1", "second@example.com"),
    ],
    ids=["revoke", "delete-app-id"],
)
def test_changes_are_made_on_the_account_asked_about(portal, action):
    state = portal()

    action()

    assert set(state["acted_as"]) == {"second@example.com"}
