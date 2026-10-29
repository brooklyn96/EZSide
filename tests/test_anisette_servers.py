"""The anisette service list the user chooses in Settings must survive a restart.

Why this exists. Apple only accepts anisette made by its own macOS libraries, so EZSide
asks a remote Mac service for headers. That service was a fixed list until now, which
left no way to put a self-hosted server in front of the public ones: a server you run
yourself is the only one that sees your requests while it is up, and the public ones
should still answer when it is not. The list is therefore saved to the data folder,
first entry first, and the engine tries them in that order.

These tests pin the storage and the precedence, because the failure mode is silent:
a list that does not round-trip means sign-in quietly goes back to the public services.
"""

from __future__ import annotations

import json

import pytest

from ipaside_engine import anisette_remote, paths
from ipaside_engine.anisette import AnisetteError

_LOCAL = "http://127.0.0.1:6969"
_PUBLIC = "https://mac-ani.jkcoxson.com"


def _saved_file():
    return paths.anisette_dir() / anisette_remote.SERVERS_FILE


def test_nothing_is_saved_by_default() -> None:
    """A fresh install must use the built-in list, not an empty one."""
    assert anisette_remote.load_servers() is None
    assert anisette_remote.RemoteAnisette().servers() == anisette_remote.SERVERS


def test_saved_list_is_used_in_order(monkeypatch) -> None:
    """The first entry is tried first: that is what makes a self-hosted server primary."""
    monkeypatch.delenv(anisette_remote.SERVER_ENV, raising=False)
    anisette_remote.save_servers([_LOCAL, _PUBLIC])

    assert anisette_remote.load_servers() == (_LOCAL, _PUBLIC)
    assert anisette_remote.RemoteAnisette().servers() == (_LOCAL, _PUBLIC)


def test_saved_list_beats_the_environment(monkeypatch) -> None:
    """Settings wins over the environment, so the app can change it without a relaunch."""
    monkeypatch.setenv(anisette_remote.SERVER_ENV, _PUBLIC)
    anisette_remote.save_servers([_LOCAL])

    assert anisette_remote.RemoteAnisette().servers() == (_LOCAL,)


def test_environment_still_works_without_a_saved_list(monkeypatch) -> None:
    """The override that existed before Settings keeps working, unchanged."""
    monkeypatch.setenv(anisette_remote.SERVER_ENV, _PUBLIC)

    assert anisette_remote.RemoteAnisette().servers() == (_PUBLIC,)


def test_clearing_restores_the_built_ins() -> None:
    """Removing every service must not leave an empty list, which would fail sign-in."""
    anisette_remote.save_servers([_LOCAL])
    anisette_remote.clear_servers()

    assert anisette_remote.load_servers() is None
    assert not _saved_file().exists()
    assert anisette_remote.RemoteAnisette().servers() == anisette_remote.SERVERS


def test_saving_an_empty_list_clears() -> None:
    """The Settings screen clears by saving nothing, so that path must clear too."""
    anisette_remote.save_servers([_LOCAL])
    anisette_remote.save_servers([])

    assert anisette_remote.load_servers() is None


def test_addresses_are_cleaned_before_they_are_saved() -> None:
    """Trailing slashes, stray spaces and duplicates are not worth a second entry."""
    saved = anisette_remote.save_servers([f"  {_LOCAL}/  ", "", _LOCAL, _PUBLIC])

    assert saved == (_LOCAL, _PUBLIC)
    assert anisette_remote.load_servers() == (_LOCAL, _PUBLIC)


@pytest.mark.parametrize("address", ["ftp://example.com", "ani.example.com", "http://example.com"])
def test_unusable_addresses_are_refused(address: str) -> None:
    """Plain HTTP is only allowed to this machine, so a remote one is rejected up front."""
    with pytest.raises(AnisetteError, match="anisette service address"):
        anisette_remote.save_servers([address])


def test_a_hand_edited_file_cannot_break_sign_in() -> None:
    """A corrupt or stale file falls back to the built-ins instead of raising."""
    _saved_file().parent.mkdir(parents=True, exist_ok=True)
    _saved_file().write_text(json.dumps({"servers": ["ftp://nope"]}), encoding="utf-8")

    assert anisette_remote.load_servers() is None
    assert anisette_remote.RemoteAnisette().servers() == anisette_remote.SERVERS


def test_local_http_is_accepted_for_a_self_hosted_server() -> None:
    """The whole point of the feature: a server on this PC needs no certificate."""
    assert anisette_remote.normalise_servers([_LOCAL]) == (_LOCAL,)
    assert anisette_remote.normalise_servers(["http://localhost:6969"]) == (
        "http://localhost:6969",
    )


def test_the_list_is_capped() -> None:
    """Each entry that cannot be reached costs a timeout, so a long list is slower, not safer."""
    too_many = [
        f"https://ani{index}.example.com" for index in range(anisette_remote.MAX_SERVERS + 1)
    ]

    with pytest.raises(AnisetteError, match="At most"):
        anisette_remote.save_servers(too_many)


def test_the_cap_counts_unique_addresses_only() -> None:
    """Duplicates collapse first, so a list is never refused for repeating itself."""
    repeated = [
        f"https://ani{index % 3}.example.com" for index in range(anisette_remote.MAX_SERVERS * 2)
    ]

    saved = anisette_remote.save_servers(repeated)

    assert len(saved) == 3
    assert len(saved) <= anisette_remote.MAX_SERVERS
