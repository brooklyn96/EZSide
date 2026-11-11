"""App Groups the IPA already carries reach the App ID before the profile is downloaded.

Groups read from the IPA are best effort: Apple may refuse an id another team owns, and
the app then installs without it. Groups a named signing profile (LiveContainer) needs
stay strict.
"""

from __future__ import annotations

import plistlib

import pytest

from _helpers import make_ipa
from ipaside_engine import developer, gsa, paths, provision, sideload

GROUP = "group.com.example.app"
OTHER = "group.com.example.other"


class _Stop(Exception):
    """Raised by a stub once it has seen its arguments, to end run_sideload there."""


def _grouped_ipa(path, *groups):
    entitlements = plistlib.dumps({"com.apple.security.application-groups": list(groups)})
    return make_ipa(path, executable=b"\xca\xfe\xba\xbe" + b"\x00" * 16 + entitlements)


@pytest.fixture
def seen(monkeypatch):
    """Record the ``(required, optional)`` groups provisioning is asked for, then stop."""
    calls: list[tuple[list[str], list[str]]] = []

    def ensure_signing_assets(*_args, app_groups=None, optional_app_groups=None, **_kwargs):
        calls.append((list(app_groups or []), list(optional_app_groups or [])))
        raise _Stop

    monkeypatch.setattr(sideload.provision, "ensure_signing_assets", ensure_signing_assets)
    monkeypatch.setattr(sideload.developer, "list_teams", lambda: [{"teamId": "TEAM"}])
    return calls


@pytest.fixture
def phone(monkeypatch):
    monkeypatch.setattr(sideload, "resolve_udid", lambda _udid: "UDID")
    monkeypatch.setattr(sideload, "_device_values", lambda _udid: {})
    monkeypatch.setattr(
        sideload.ipa_module, "inspect",
        lambda _p: {"bundle_id": "com.example.app", "display_name": "Example"},
    )


@pytest.fixture
def run(seen, phone):
    def go(ipa_path, **options):
        with pytest.raises(_Stop):
            sideload.run_sideload(str(ipa_path), "UDID", record=False, **options)
        return seen[-1]

    return go


def test_the_groups_in_the_ipa_are_registered_before_the_profile(run, tmp_path):
    ipa = _grouped_ipa(tmp_path / "a.ipa", GROUP, "not-a-group")

    assert run(ipa) == ([], [GROUP])


def test_an_ipa_without_groups_registers_none(run, tmp_path):
    assert run(make_ipa(tmp_path / "plain.ipa")) == ([], [])


def test_an_unreadable_ipa_never_fails_the_sideload(run, tmp_path):
    broken = tmp_path / "broken.ipa"
    broken.write_bytes(b"PK\x03\x04 not a zip")

    assert run(broken) == ([], [])


def test_profile_groups_stay_required_and_the_ipas_are_added_once(run, tmp_path, monkeypatch):
    monkeypatch.setattr(
        sideload, "_signing_profile",
        lambda *_a: (["group.profile", GROUP], {}, []),
    )
    ipa = _grouped_ipa(tmp_path / "a.ipa", GROUP, OTHER)

    assert run(ipa, profile="named") == (["group.profile", GROUP], [OTHER])


def test_an_ordinary_profile_only_refresh_registers_nothing(seen, monkeypatch, tmp_path):
    monkeypatch.setattr(sideload.apps, "list_installed", lambda _udid: {"com.example.app.TEAM": {}})
    cached = _grouped_ipa(tmp_path / "source.ipa", GROUP)
    entry = {
        "bundle_id": "com.example.app.TEAM",
        "name": "Example",
        "udid": "UDID",
        "cached_ipa": str(cached),
        "options": {},
    }

    sideload._refresh_profile_only(entry, lambda *_a: None)

    assert seen == [([], [])], "no assignment is sent, so the App ID keeps the groups it has"


# --------------------------------------------------------------------------- #
# Apple refusing a group: the real provision.ensure_signing_assets, Apple stubbed
# --------------------------------------------------------------------------- #


class _Apple:
    """Stands in for developerservices2: which group ids it refuses, and what it saw."""

    def __init__(self, refuses=()):
        self.refuses = set(refuses)
        self.added: list[str] = []
        self.assigned: list[list[str]] = []
        self.downloaded = False

    def add_application_group(self, _team, identifier, _name):
        self.added.append(identifier)
        if identifier in self.refuses:
            raise developer.DeveloperServicesError(f"9401 {identifier} is not available")
        return {"identifier": identifier, "applicationGroup": f"ID-{identifier}"}

    def assign_application_groups(self, _team, _app_id, group_ids):
        self.assigned.append(list(group_ids))

    def download_profile(self, _team, _app_id):
        self.downloaded = True
        raise _Stop  # the profile download is as far as these tests need to get


@pytest.fixture
def apple(phone, monkeypatch, tmp_path):
    def make(*refuses):
        fake = _Apple(refuses)
        monkeypatch.setattr(paths, "signing_dir", lambda _slug=None: tmp_path)
        monkeypatch.setattr(gsa, "load_session", lambda *a, **k: {"email": None})
        monkeypatch.setattr(developer, "list_teams", lambda: [{"teamId": "TEAM", "name": "T"}])
        monkeypatch.setattr(
            provision, "_ensure_certificate", lambda *_a: (b"key", b"der", "S1", "PW")
        )
        monkeypatch.setattr(provision, "_ensure_device", lambda *_a: None)
        monkeypatch.setattr(provision, "_ensure_app_id", lambda *_a: {"appIdId": "APPID"})
        monkeypatch.setattr(developer, "enable_app_id_feature", lambda *_a, **_k: {})
        monkeypatch.setattr(developer, "list_application_groups", lambda _team: [])
        monkeypatch.setattr(developer, "add_application_group", fake.add_application_group)
        monkeypatch.setattr(developer, "assign_application_groups", fake.assign_application_groups)
        monkeypatch.setattr(developer, "download_profile", fake.download_profile)
        return fake

    return make


def test_a_group_apple_refuses_still_reaches_the_profile_on_a_first_sideload(apple, tmp_path):
    fake = apple(GROUP)
    ipa = _grouped_ipa(tmp_path / "a.ipa", GROUP)
    steps: list[str] = []

    with pytest.raises(_Stop):
        sideload.run_sideload(
            str(ipa), "UDID", record=False, on_progress=lambda _s, _p, msg: steps.append(msg)
        )

    assert fake.downloaded
    assert fake.assigned == [], "every group was refused: nothing to assign"
    assert [m for m in steps if GROUP in (m or "")] == [
        f"Apple would not register app group {GROUP} for this Apple ID; installing without it"
    ]


def test_a_group_apple_refuses_still_reaches_the_profile_on_a_resign_refresh(apple, tmp_path):
    fake = apple(GROUP)
    cached = _grouped_ipa(tmp_path / "source.ipa", GROUP)
    entry = {
        "bundle_id": "com.example.app.TEAM",
        "name": "Example",
        "udid": "UDID",
        "team_id": None,
        "cached_ipa": str(cached),
        "source_ipa": str(cached),
        "options": {},
    }

    with pytest.raises(_Stop):
        sideload.refresh_record(entry, resign=True)

    assert fake.added == [GROUP]
    assert fake.downloaded


def test_a_group_the_signing_profile_needs_is_still_refused_loudly(apple, tmp_path, monkeypatch):
    fake = apple("group.profile")
    monkeypatch.setattr(sideload, "_signing_profile", lambda *_a: (["group.profile"], {}, []))
    ipa = _grouped_ipa(tmp_path / "a.ipa", GROUP)

    with pytest.raises(developer.DeveloperServicesError, match="group.profile"):
        sideload.run_sideload(str(ipa), "UDID", record=False, profile="named")

    assert not fake.downloaded


def test_one_refused_group_does_not_cost_the_one_apple_accepts(apple, tmp_path):
    fake = apple(GROUP)
    ipa = _grouped_ipa(tmp_path / "a.ipa", GROUP, OTHER)

    with pytest.raises(_Stop):
        sideload.run_sideload(str(ipa), "UDID", record=False)

    assert fake.added == [GROUP, OTHER]
    assert fake.assigned == [[f"ID-{OTHER}"]]
    assert fake.downloaded
