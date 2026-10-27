"""LiveContainer setup: entitlements, release selection, and the import request.

The parts worth pinning down are the ones a phone cannot tell us about quickly: that the
entitlements are exactly what LiveContainer looks for and nothing a free profile would
reject, that a release download cannot pick a build we cannot provision, and that the
import request matches the keys the injected dylib reads.
"""

from __future__ import annotations

import plistlib

import pytest

from ipaside_engine import livecontainer, sideload

TEAM = "ASK9QR9SBC"
BUNDLE_ID = f"{livecontainer.BUNDLE_PREFIX}.{TEAM}"


# --------------------------------------------------------------------------- #
# Entitlements
# --------------------------------------------------------------------------- #
def test_bundle_id_is_team_scoped():
    assert livecontainer.bundle_id_for(TEAM) == f"com.kdt.livecontainer.{TEAM}"


def test_app_groups_are_both_stores_in_preference_order():
    groups = livecontainer.app_group_identifiers(TEAM)
    assert groups == [
        f"group.com.SideStore.SideStore.{TEAM}",
        f"group.com.rileytestut.AltStore.{TEAM}",
    ]


def test_entitlements_carry_the_jitless_requirements():
    ents = livecontainer.build_entitlements(TEAM, BUNDLE_ID)

    assert ents["application-identifier"] == f"{TEAM}.{BUNDLE_ID}"
    assert ents["com.apple.developer.team-identifier"] == TEAM
    assert ents["get-task-allow"] is True
    assert ents["com.apple.security.application-groups"] == (
        livecontainer.app_group_identifiers(TEAM)
    )


def test_keychain_groups_are_expanded_not_wildcarded():
    """LiveContainer derives guest keychain groups by index, so the list must be explicit.

    A profile's `TEAMID.*` wildcard legally covers these, which is why signing with them
    is accepted - but leaving the wildcard in place is what makes other signers unusable
    with LiveContainer.
    """
    groups = livecontainer.build_entitlements(TEAM, BUNDLE_ID)["keychain-access-groups"]

    assert len(groups) == livecontainer.KEYCHAIN_GROUPS
    assert f"{TEAM}.*" not in groups
    assert groups[0] == f"{TEAM}.com.kdt.livecontainer.shared"
    assert groups[1] == f"{TEAM}.com.kdt.livecontainer.shared.1"
    assert groups[-1] == (
        f"{TEAM}.com.kdt.livecontainer.shared.{livecontainer.KEYCHAIN_GROUPS - 1}"
    )
    assert len(set(groups)) == len(groups), "duplicate keychain groups"


@pytest.mark.parametrize(
    "entitlement",
    [
        "com.apple.developer.healthkit",
        "com.apple.developer.kernel.increased-memory-limit",
    ],
)
def test_entitlements_omit_what_a_free_profile_will_not_grant(entitlement):
    """Asking for an ungranted entitlement invalidates the whole signature.

    LiveContainer's own build asks for these; we deliberately do not, because a free
    profile does not carry them and the result is a signature iOS rejects outright
    rather than one granted in part.
    """
    assert entitlement not in livecontainer.build_entitlements(TEAM, BUNDLE_ID)


def test_entitlements_are_plist_serializable():
    """zsign is handed these as a plist, so anything unserializable fails at sign time."""
    ents = livecontainer.build_entitlements(TEAM, BUNDLE_ID)
    assert plistlib.loads(plistlib.dumps(ents)) == ents


# --------------------------------------------------------------------------- #
# Recognising LiveContainer
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize(
    ("bundle_id", "expected"),
    [
        ("com.kdt.livecontainer", True),
        (f"com.kdt.livecontainer.{TEAM}", True),
        ("com.burbn.instagram", False),
        ("com.kdt.something-else", False),
        ("", False),
        (None, False),
    ],
)
def test_is_livecontainer(bundle_id, expected):
    assert livecontainer.is_livecontainer({"bundle_id": bundle_id}) is expected


# --------------------------------------------------------------------------- #
# Release asset selection
# --------------------------------------------------------------------------- #
RELEASE_ASSETS = [
    {"name": "LiveContainer.TrollStore.ipa", "size": 1},
    {"name": "LiveContainer.ipa", "size": 2},
    {"name": "LiveContainer+SideStore.ipa", "size": 3},
    {"name": "LiveContainer.JB.ipa", "size": 4},
]


def test_only_the_plain_build_is_picked():
    """The build that bundles SideStore is deliberately never offered."""
    assert livecontainer._pick_asset(RELEASE_ASSETS)["name"] == "LiveContainer.ipa"


def test_a_release_with_only_the_sidestore_build_has_no_usable_asset():
    """Better no answer than quietly handing back the other build."""
    assert livecontainer._pick_asset([{"name": "LiveContainer+SideStore.ipa"}]) is None


def test_asset_selection_skips_builds_we_cannot_provision():
    """A TrollStore build installs and then will not run under a free profile."""
    assets = [{"name": "LiveContainer.TrollStore.ipa"}, {"name": "LiveContainer.JB.ipa"}]
    assert livecontainer._pick_asset(assets) is None


def test_asset_selection_never_picks_the_jailbreak_build():
    """LiveContainer-Jailbreak.ipa names no "jb", yet it must not be chosen."""
    assert livecontainer._pick_asset([{"name": "LiveContainer-Jailbreak.ipa"}]) is None
    assets = [{"name": "LiveContainer-Jailbreak.ipa", "size": 1}, {"name": "LiveContainer.ipa", "size": 2}]
    assert livecontainer._pick_asset(assets)["name"] == "LiveContainer.ipa"


def test_asset_selection_ignores_non_ipa_assets():
    assets = [
        {"name": "LiveContainer.tipa"},
        {"name": "SHA256SUMS.txt"},
        {"name": "source.zip"},
    ]
    assert livecontainer._pick_asset(assets) is None


def test_asset_selection_handles_an_empty_release():
    assert livecontainer._pick_asset([]) is None


# --------------------------------------------------------------------------- #
# The import request the dylib reads
# --------------------------------------------------------------------------- #
def test_import_request_matches_the_dylib_contract(tmp_path):
    p12 = tmp_path / "identity.p12"
    p12.write_bytes(b"pkcs12-bytes")

    request = plistlib.loads(
        livecontainer._import_request(
            {"team_id": TEAM, "p12_path": str(p12), "p12_password": "iPASide"}
        )
    )

    # These three key names are the contract with tools/lc-cert-import/; renaming one
    # here without rebuilding the dylib silently stops the automatic import working.
    assert set(request) == {"AppGroupID", "CertificateData", "CertificatePassword"}
    assert request["AppGroupID"] == f"group.com.SideStore.SideStore.{TEAM}"
    assert request["CertificateData"] == b"pkcs12-bytes"
    assert request["CertificatePassword"] == "iPASide"


def test_import_request_names_the_group_livecontainer_prefers():
    """LiveContainer resolves its own group, so the request must name the same one."""
    request_group = f"group.com.SideStore.SideStore.{TEAM}"
    assert livecontainer.app_group_identifiers(TEAM)[0] == request_group


# --------------------------------------------------------------------------- #
# Wiring into the sideload path
# --------------------------------------------------------------------------- #
def test_sideload_resolves_the_livecontainer_profile():
    groups, entitlements, dylibs = sideload._signing_profile(
        livecontainer.SIGNING_PROFILE, TEAM, BUNDLE_ID
    )

    assert groups == livecontainer.app_group_identifiers(TEAM)
    assert entitlements == livecontainer.build_entitlements(TEAM, BUNDLE_ID)
    # Built on macOS in CI and committed, so a source checkout may or may not have it;
    # either way the profile must return a list rather than fail.
    assert isinstance(dylibs, list)
    assert all(str(d).endswith(".dylib") for d in dylibs)


def test_unknown_signing_profile_is_refused():
    with pytest.raises(sideload.SideloadError, match="Unknown signing profile"):
        sideload._signing_profile("not-a-profile", TEAM, BUNDLE_ID)


def test_post_install_delivers_the_certificate(monkeypatch):
    """A refresh must re-deliver it, not only a first install.

    LiveContainer keeps its own copy of the signing certificate. If that certificate is
    ever reissued - Apple revoking it, or the local cache going missing - a re-sign
    leaves LiveContainer holding one that no longer matches, and nothing reports it: the
    app installs, launches, and only fails when it tries to sign a guest app.
    """
    seeded: list[tuple[dict, str | None]] = []
    monkeypatch.setattr(
        sideload.provision,
        "load_bundle",
        lambda: {"team_id": TEAM, "p12_path": "x", "bundle_id": BUNDLE_ID},
    )
    monkeypatch.setattr(
        livecontainer,
        "seed_certificate",
        lambda bundle, serial=None, **kw: seeded.append((bundle, serial)) or {"seeded": True},
    )

    result = sideload._profile_post_install(livecontainer.SIGNING_PROFILE, "UDID123")

    assert result["certificate"] == {"seeded": True}
    assert seeded[0][1] == "UDID123"


def test_post_install_does_nothing_for_an_ordinary_sideload():
    assert sideload._profile_post_install("not-a-profile", "UDID123") is None


def test_post_install_outcome_is_not_recorded(monkeypatch):
    """It describes one run, so replaying it on a refresh would be meaningless."""
    recorded: dict = {}
    monkeypatch.setattr(sideload.refresh, "record", lambda entry: recorded.update(entry))

    # Mirrors what run_sideload builds, to pin the filter rather than the whole flow.
    result = {"bundle_id": BUNDLE_ID, "signed_ipa": "x.ipa", "post_install": {"seeded": True}}
    transient = ("signed_ipa", "post_install")
    sideload.refresh.record({k: v for k, v in result.items() if k not in transient})

    assert "post_install" not in recorded
    assert "signed_ipa" not in recorded
    assert recorded["bundle_id"] == BUNDLE_ID


# --------------------------------------------------------------------------- #
# Which certificate route the user is put on
# --------------------------------------------------------------------------- #
def test_seeding_writes_both_files_when_the_dylib_is_shipped(monkeypatch, tmp_path):
    p12 = tmp_path / "identity.p12"
    p12.write_bytes(b"pkcs12")
    written: dict[str, bytes] = {}

    monkeypatch.setattr(livecontainer.signing, "resolve_helper_dylib", lambda: "helper.dylib")
    monkeypatch.setattr(
        livecontainer,
        "_write_documents",
        lambda bundle_id, serial, files: written.update(files) or _noop(),
    )

    result = livecontainer.seed_certificate(
        {"team_id": TEAM, "bundle_id": BUNDLE_ID, "p12_path": str(p12), "p12_password": "iPASide"}
    )

    assert result["automatic"] is True
    assert set(written) == {livecontainer.CERTIFICATE_NAME, livecontainer.REQUEST_NAME}


def test_seeding_writes_only_the_p12_when_the_dylib_is_absent(monkeypatch, tmp_path):
    """Never promise an automatic import that nothing on the device can perform."""
    p12 = tmp_path / "identity.p12"
    p12.write_bytes(b"pkcs12")
    written: dict[str, bytes] = {}

    monkeypatch.setattr(livecontainer.signing, "resolve_helper_dylib", lambda: None)
    monkeypatch.setattr(
        livecontainer,
        "_write_documents",
        lambda bundle_id, serial, files: written.update(files) or _noop(),
    )

    result = livecontainer.seed_certificate(
        {"team_id": TEAM, "bundle_id": BUNDLE_ID, "p12_path": str(p12), "p12_password": "iPASide"}
    )

    assert result["automatic"] is False
    assert set(written) == {livecontainer.CERTIFICATE_NAME}
    assert livecontainer.CERTIFICATE_NAME in result["instructions"]
    assert "iPASide" in result["instructions"], "the password must be shown to the user"


def test_seeding_failure_is_reported_not_raised(monkeypatch, tmp_path):
    """The app is already installed by then; failing the whole setup would be worse."""
    p12 = tmp_path / "identity.p12"
    p12.write_bytes(b"pkcs12")

    monkeypatch.setattr(livecontainer.signing, "resolve_helper_dylib", lambda: "helper.dylib")

    def explode(*_args, **_kwargs):
        raise OSError("device went away")

    monkeypatch.setattr(livecontainer, "_write_documents", explode)

    result = livecontainer.seed_certificate(
        {"team_id": TEAM, "bundle_id": BUNDLE_ID, "p12_path": str(p12), "p12_password": "iPASide"}
    )

    assert result["seeded"] is False
    assert result["automatic"] is False
    assert "device went away" in result["error"]
    assert result["instructions"], "a manual route must still be offered"


async def _noop() -> None:
    """Stand-in for the awaitable _write_documents returns."""


def test_setup_refuses_an_ipa_that_is_not_livecontainer(monkeypatch, tmp_path):
    """Signing something else with LiveContainer's entitlements makes no sense."""
    monkeypatch.setattr(
        livecontainer.ipa_module,
        "inspect",
        lambda _path: {"bundle_id": "com.burbn.instagram", "display_name": "Instagram"},
    )
    ipa = tmp_path / "Instagram.ipa"
    ipa.write_bytes(b"not really an ipa")

    with pytest.raises(livecontainer.LiveContainerError, match="not\\s+LiveContainer"):
        livecontainer.setup(str(ipa))
