"""Tests for explaining the free-profile install ceiling.

Found by asking whether more than three sideloaded apps are possible, and testing it on
an iPhone 8 Plus. iOS refuses the fourth at install time with:

    ApplicationVerificationFailed: This device has reached the maximum number of
    installed apps using a free developer profile: {(
        "ASK9QR9SBC.com.ipaside.slottest2",
        "ASK9QR9SBC.com.ipaside.slottest3",
        "CMU239YZ46.lt.manodrabuziai.fr.CMU239YZ46"
    )}

Two facts worth preserving. The apps it counts can belong to different developer teams,
so the ceiling is per device rather than per Apple ID — which makes the common advice to
sign in with a second account useless, and it was worth testing rather than repeating.
And the raw message embeds a Python set of tuples, which is no way to tell somebody their
phone is full.
"""

from __future__ import annotations

from ipaside_engine import apps

# Verbatim from the device, both accounts producing the same list.
TWO_TEAMS = (
    'This device has reached the maximum number of installed apps using a free '
    'developer profile: {(\n    "ASK9QR9SBC.com.ipaside.slottest2",\n'
    '    "ASK9QR9SBC.com.ipaside.slottest3",\n'
    '    "CMU239YZ46.lt.manodrabuziai.fr.CMU239YZ46"\n)}'
)

ONE_TEAM = (
    'This device has reached the maximum number of installed apps using a free '
    'developer profile: {(\n    "ASK9QR9SBC.com.one",\n'
    '    "ASK9QR9SBC.com.two",\n    "ASK9QR9SBC.com.three"\n)}'
)


def test_the_occupied_slots_are_pulled_out_of_the_message():
    assert apps._installed_ids(TWO_TEAMS) == [
        "ASK9QR9SBC.com.ipaside.slottest2",
        "ASK9QR9SBC.com.ipaside.slottest3",
        "CMU239YZ46.lt.manodrabuziai.fr.CMU239YZ46",
    ]


def test_it_reads_as_a_sentence_and_names_what_is_in_the_way():
    message = apps._readable_install_error("ApplicationVerificationFailed", TWO_TEAMS)

    assert message is not None
    assert "most apps a free Apple ID can install at once (3)" in message
    assert "Delete one to make room." in message
    # Each occupant, with the team that signed it, on its own line.
    assert "com.ipaside.slottest2  (team ASK9QR9SBC)" in message
    assert "lt.manodrabuziai.fr.CMU239YZ46  (team CMU239YZ46)" in message
    # And none of the raw shape.
    assert "{(" not in message
    assert "ApplicationVerificationFailed" not in message


def test_a_mixed_team_list_says_a_second_account_will_not_help():
    message = apps._readable_install_error("ApplicationVerificationFailed", TWO_TEAMS)

    assert "more than one Apple ID" in message
    assert "does not add slots" in message
    assert "paid developer account" in message


def test_a_single_team_list_says_the_same_thing_without_claiming_evidence():
    message = apps._readable_install_error("ApplicationVerificationFailed", ONE_TEAM)

    assert "does not add slots" in message
    assert "more than one Apple ID" not in message, (
        "with one team on the list, there is nothing on screen to point at"
    )


def test_other_install_failures_are_left_alone():
    assert apps._readable_install_error("ApplicationVerificationFailed", "something else") is None
    assert apps._readable_install_error("MismatchedApplicationIdentifierEntitlement", None) is None


def test_the_limit_error_is_an_engine_error_so_it_prints_without_a_traceback():
    from ipaside_engine.errors import EngineError

    assert issubclass(apps.InstallLimitError, EngineError)
