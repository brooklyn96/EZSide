"""Tests for noticing an .ipa built for something other than iPhone or iPad.

Asked on r/sideloaded whether iPASide can install to an Apple TV. It cannot, and the
reason it matters that we say so early is that a tvOS `.ipa` is indistinguishable from
an iOS one until the Info.plist is read: same zip, same `Payload/<App>.app`, same keys.
Signed as iOS it provisions cleanly, uploads, and is refused by the device at the last
step with nothing that points at the platform.
"""

from __future__ import annotations

import plistlib
import zipfile

import pytest

from ipaside_engine import ipa, sideload


def build_ipa(path, info: dict) -> str:
    """A minimal .ipa carrying `info` as its Info.plist."""
    target = path / "Sample.ipa"
    with zipfile.ZipFile(target, "w") as zf:
        zf.writestr("Payload/Sample.app/Info.plist", plistlib.dumps(info))
        zf.writestr("Payload/Sample.app/Sample", b"\xcf\xfa\xed\xfe" + b"\x00" * 60)
    return str(target)


BASE = {"CFBundleIdentifier": "com.example.sample", "CFBundleExecutable": "Sample"}


# --- reading the platform out of an Info.plist ------------------------------- #

@pytest.mark.parametrize(
    ("info", "expected"),
    [
        ({"CFBundleSupportedPlatforms": ["iPhoneOS"]}, "ios"),
        ({"CFBundleSupportedPlatforms": ["AppleTVOS"]}, "tvos"),
        ({"CFBundleSupportedPlatforms": ["WatchOS"]}, "watchos"),
        ({"CFBundleSupportedPlatforms": ["XROS"]}, "visionos"),
        # UIDeviceFamily is the fallback: 1 iPhone, 2 iPad, 3 Apple TV, 4 Watch.
        ({"UIDeviceFamily": [1]}, "ios"),
        ({"UIDeviceFamily": [2]}, "ios"),
        ({"UIDeviceFamily": [1, 2]}, "ios"),
        ({"UIDeviceFamily": [3]}, "tvos"),
        ({"UIDeviceFamily": [4]}, "watchos"),
        # Nothing to go on.
        ({}, None),
    ],
)
def test_the_platform_is_read_from_the_plist(info, expected):
    assert ipa._platform(info) == expected


def test_the_explicit_platform_wins_over_the_device_family():
    # Xcode writes both; the platform list is the direct statement.
    assert ipa._platform(
        {"CFBundleSupportedPlatforms": ["AppleTVOS"], "UIDeviceFamily": [3]}
    ) == "tvos"


def test_a_universal_build_that_also_claims_ios_is_ios():
    assert ipa._platform({"UIDeviceFamily": [1, 2, 3]}) == "ios", (
        "an app that runs on iPhone is installable, whatever else it also supports"
    )


def test_inspect_reports_the_platform(tmp_path):
    report = ipa.inspect(build_ipa(tmp_path, {**BASE, "CFBundleSupportedPlatforms": ["AppleTVOS"]}))
    assert report["platform"] == "tvos"


def test_an_ordinary_iphone_ipa_reads_as_ios(tmp_path):
    report = ipa.inspect(build_ipa(tmp_path, {**BASE, "UIDeviceFamily": [1]}))
    assert report["platform"] == "ios"


# --- and refusing only a genuine mismatch ------------------------------------ #

@pytest.fixture
def device_class(monkeypatch):
    """Pretends the selected device is of a given lockdown DeviceClass."""

    def _set(value: str, name: str = "Test Device"):
        monkeypatch.setattr(
            sideload.device, "get_device_info",
            lambda *a, **k: {"DeviceClass": value, "DeviceName": name},
        )
        monkeypatch.setattr(sideload, "resolve_udid", lambda u: "0000")

    return _set


def test_a_tvos_app_going_to_an_iphone_is_refused(tmp_path, device_class):
    device_class("iPhone")
    path = build_ipa(tmp_path, {**BASE, "CFBundleSupportedPlatforms": ["AppleTVOS"]})

    with pytest.raises(sideload.SideloadError) as caught:
        sideload.run_sideload(path, "0000")

    message = str(caught.value)
    assert "Sample.ipa" in message, "say which file"
    assert "Apple TV (tvOS)" in message, "what it is built for"
    assert "an iPhone or iPad" in message, "and what was selected"
    assert "--allow-other-platform" in message


def test_an_ios_app_going_to_an_apple_tv_is_refused(tmp_path, device_class):
    device_class("AppleTV")
    path = build_ipa(tmp_path, {**BASE, "UIDeviceFamily": [1]})

    with pytest.raises(sideload.SideloadError, match="an Apple TV"):
        sideload.run_sideload(path, "0000")


def test_a_tvos_app_going_to_an_apple_tv_is_allowed(tmp_path, device_class):
    """The case this used to block outright.

    Apple registers an Apple TV and issues its profile through the same `ios/` endpoints
    it uses for a phone - the same ones iPASide already calls - so there is nothing about
    the provisioning that rules this out. It gets past the platform gate and fails later,
    on the device it cannot actually reach from a test.
    """
    device_class("AppleTV")
    path = build_ipa(tmp_path, {**BASE, "CFBundleSupportedPlatforms": ["AppleTVOS"]})

    with pytest.raises(Exception) as caught:
        sideload.run_sideload(path, "0000")
    assert "is built for" not in str(caught.value), (
        "a tvOS app on an Apple TV is not a mismatch and must not be refused as one"
    )


def test_an_iphone_app_going_to_an_iphone_is_allowed(tmp_path, device_class):
    device_class("iPhone")
    path = build_ipa(tmp_path, {**BASE, "UIDeviceFamily": [1]})

    with pytest.raises(Exception) as caught:
        sideload.run_sideload(path, "0000")
    assert "is built for" not in str(caught.value)


def test_an_unreachable_device_does_not_block_the_install(tmp_path, monkeypatch):
    """A device we cannot read is the install's problem to report, not the gate's."""
    monkeypatch.setattr(sideload, "resolve_udid", lambda u: "0000")

    def unreachable(*a, **k):
        raise RuntimeError("no route to device")

    monkeypatch.setattr(sideload.device, "get_device_info", unreachable)
    path = build_ipa(tmp_path, {**BASE, "CFBundleSupportedPlatforms": ["AppleTVOS"]})

    with pytest.raises(Exception) as caught:
        sideload.run_sideload(path, "0000")
    assert "is built for" not in str(caught.value)


def test_an_ipa_that_does_not_say_is_allowed_through(tmp_path, device_class):
    """No platform recorded is not evidence of the wrong platform."""
    device_class("iPhone")
    path = build_ipa(tmp_path, BASE)

    with pytest.raises(Exception) as caught:
        sideload.run_sideload(path, "0000")
    assert "is built for" not in str(caught.value)


def test_the_mismatch_can_be_overridden(tmp_path, device_class):
    device_class("iPhone")
    path = build_ipa(tmp_path, {**BASE, "CFBundleSupportedPlatforms": ["AppleTVOS"]})

    with pytest.raises(Exception) as caught:
        sideload.run_sideload(path, "0000", allow_other_platform=True)
    assert "is built for" not in str(caught.value)
