"""The jailbreak advisor + Dopamine installer, and the ``jailbreak`` CLI wiring.

The compatibility data is fetched live from a JSON file in the repo, so the advisor
logic is tested against that *real* shipped file (loaded from disk) - a bad edit to the
data fails here - while the network fetch itself is tested with a stub. The installer
and CLI are exercised the same way ``test_cli_livecontainer`` is: stub only the
boundaries iPASide does not own (the network, the device, the sideload).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from ipaside_engine import __main__ as cli
from ipaside_engine import jailbreak

# The real shipped compatibility list, so these tests double as a check on that data.
_COMPAT = json.loads(
    (Path(__file__).resolve().parents[1] / "compat" / "dopamine.json").read_text("utf-8")
)


# --------------------------------------------------------------------------- #
# Device -> chip (from the live list)
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize(
    "product_type, chip",
    [
        ("iPhone10,2", "A11"),  # iPhone 8 Plus
        ("iPhone11,8", "A12"),  # iPhone XR
        ("iPhone12,1", "A13"),  # iPhone 11
        ("iPhone13,2", "A14"),  # iPhone 12
        ("iPhone14,5", "A15"),  # iPhone 13
        ("iPhone15,2", "A16"),  # iPhone 14 Pro
        ("iPhone16,1", "A17 Pro"),  # iPhone 15 Pro
        ("iPhone17,1", "A18 Pro"),  # iPhone 16 Pro
        ("iPhone17,3", "A18"),  # iPhone 16
        ("iPhone18,1", "A19 Pro"),  # iPhone 17 Pro
        ("iPhone18,5", "A19"),  # iPhone 17e
        ("iPad5,3", "A8X"),     # iPad Air 2
        ("iPad6,3", "A9X"),     # iPad Pro 9.7-inch
        ("iPad7,3", "A10X"),    # iPad Pro 10.5-inch
        ("iPad8,1", "A12X"),    # iPad Pro 11-inch (1st gen)
        ("iPad8,9", "A12Z"),    # iPad Pro 11-inch (2nd gen)
        ("iPad11,1", "A12"),    # iPad mini (5th gen)
        ("iPad12,1", "A13"),    # iPad (9th gen)
        ("iPad13,4", "M1"),     # iPad Pro 2021
        ("iPad14,3", "M2"),     # iPad Pro 2022
        ("iPad15,3", "M3"),     # iPad Air 11-inch (M3)
        ("iPad16,3", "M4"),     # iPad Pro 11-inch (M4)
        ("iPad17,1", "M5"),     # iPad Pro 11-inch (M5)
    ],
)
def test_chip_for_known_devices(product_type, chip):
    assert jailbreak.chip_for(_COMPAT, product_type) == chip


def test_chip_for_unknown_device_is_none():
    assert jailbreak.chip_for(_COMPAT, "iPhone99,9") is None
    assert jailbreak.chip_for(_COMPAT, None) is None


def test_device_name_for_iphone_is_marketing_name():
    assert jailbreak.device_name_for(_COMPAT, "iPhone12,1") == "iPhone 11"


# --------------------------------------------------------------------------- #
# Remote-data integrity
# --------------------------------------------------------------------------- #
def _assert_ordered_ranges(ranges):
    assert isinstance(ranges, list)
    previous_high = None
    for pair in ranges:
        assert isinstance(pair, list) and len(pair) == 2
        low = jailbreak.parse_version(pair[0])
        high = jailbreak.parse_version(pair[1])
        assert low is not None and high is not None and low <= high
        if previous_high is not None:
            assert previous_high < low
        previous_high = high


def test_every_device_resolves_to_a_named_policy():
    support = _COMPAT["support"]
    no_jailbreak = set(_COMPAT["no_jailbreak"])
    for product_type, entry in _COMPAT["devices"].items():
        assert product_type
        assert isinstance(entry.get("name"), str) and entry["name"]
        chip = entry.get("chip")
        assert chip in support or chip in no_jailbreak
        if "support" in entry:
            _assert_ordered_ranges(entry["support"])


def test_all_chip_ranges_are_ordered_and_do_not_overlap():
    for ranges in _COMPAT["support"].values():
        _assert_ordered_ranges(ranges)


def test_build_rules_are_exact_unique_and_reference_known_devices():
    seen = set()
    known_devices = set(_COMPAT["devices"])
    known_chips = set(_COMPAT["support"]) | set(_COMPAT["no_jailbreak"])
    for rule in _COMPAT["build_support"]:
        key = (rule["product_version"], rule["build"])
        assert key not in seen
        seen.add(key)
        assert jailbreak.parse_version(rule["product_version"]) is not None
        assert isinstance(rule["label"], str) and rule["label"]
        assert set(rule.get("chips", ())) <= known_chips
        assert set(rule.get("devices", ())) <= known_devices
        assert set(rule.get("exclude_devices", ())) <= known_devices


def _legacy_v1_2_supported(product_type, product_version):
    """Released 1.2.0 behavior: chip ranges only, with no schema-3 fields."""
    entry = _COMPAT["devices"][product_type]
    chip = entry["chip"]
    running = jailbreak.parse_version(product_version)
    if chip in _COMPAT["no_jailbreak"] or running is None:
        return False
    return any(
        jailbreak.parse_version(low) <= running <= jailbreak.parse_version(high)
        for low, high in _COMPAT["support"].get(chip, ())
    )


def test_schema_3_remains_safe_for_released_v1_2_clients():
    assert _legacy_v1_2_supported("iPad11,1", "26.0.1") is True
    assert _legacy_v1_2_supported("iPhone11,8", "18.7.1") is True
    assert _legacy_v1_2_supported("iPhone12,1", "26.1") is False
    assert _legacy_v1_2_supported("iPhone17,1", "26.0") is False


def test_beta_only_support_is_not_encoded_as_a_numeric_26_1_range():
    beta_version = jailbreak.parse_version("26.1")
    assert beta_version is not None
    for ranges in _COMPAT["support"].values():
        for low_text, high_text in ranges:
            low = jailbreak.parse_version(low_text)
            high = jailbreak.parse_version(high_text)
            assert low is not None and high is not None
            assert not low <= beta_version <= high


# --------------------------------------------------------------------------- #
# Version parsing
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize(
    "text, expected",
    [("16.7.15", (16, 7, 15)), ("26.0", (26, 0, 0)), ("18", (18, 0, 0)), ("  17.3.1  ", (17, 3, 1))],
)
def test_parse_version(text, expected):
    assert jailbreak.parse_version(text) == expected


def test_parse_version_rejects_junk():
    assert jailbreak.parse_version(None) is None
    assert jailbreak.parse_version("") is None
    assert jailbreak.parse_version("beta") is None


# --------------------------------------------------------------------------- #
# The advisor (against the real shipped data)
# --------------------------------------------------------------------------- #
def _advise(product_type, version, build=None):
    return jailbreak.advise(product_type, version, _COMPAT, build)


def test_a13_reaches_ios_26():
    advice = _advise("iPhone12,1", "26.0.1")
    assert advice["outcome"] == jailbreak.SUPPORTED
    assert advice["can_install"] is True
    assert advice["max_supported"] == "26.1 beta 3"


def test_a11_is_supported_up_to_its_ceiling():
    advice = _advise("iPhone10,2", "16.7.15")  # iPhone 8 Plus
    assert advice["outcome"] == jailbreak.SUPPORTED
    assert advice["can_install"] is True
    assert advice["max_supported"] == "16.7.16"


def test_a10_iphone_uses_its_real_device_ceiling():
    advice = _advise("iPhone9,1", "16.7.15")  # impossible on iPhone 7
    assert advice["outcome"] == jailbreak.UNSUPPORTED_VERSION
    assert advice["max_supported"] == "15.8.8"


def test_a10_ipad_has_continuous_support_through_18():
    advice = _advise("iPad7,11", "16.3")
    assert advice["outcome"] == jailbreak.SUPPORTED
    assert advice["max_supported"] == "18.7.1"


def test_a12_iphone_uses_its_device_ceiling():
    advice = _advise("iPhone11,8", "18.7.1")  # iPhone XR
    assert advice["outcome"] == jailbreak.SUPPORTED
    assert advice["max_supported"] == "18.7.1"

    impossible_firmware = _advise("iPhone11,8", "26.0")
    assert impossible_firmware["outcome"] == jailbreak.UNSUPPORTED_VERSION
    assert impossible_firmware["max_supported"] == "18.7.1"


@pytest.mark.parametrize(
    "product_type",
    [
        "iPad11,1",  # iPad mini (5th gen), A12
        "iPad11,3",  # iPad Air (3rd gen), A12
        "iPad11,6",  # iPad (8th gen), A12
        "iPad8,1",   # iPad Pro 11-inch (1st gen), A12X
        "iPad8,9",   # iPad Pro 11-inch (2nd gen), A12Z
        "iPad12,1",  # iPad (9th gen), A13
    ],
)
def test_a12_family_and_a13_ipads_reach_ipados_26(product_type):
    advice = _advise(product_type, "26.0.1")
    assert advice["outcome"] == jailbreak.SUPPORTED
    assert advice["can_install"] is True
    assert advice["max_supported"] == "26.1 beta 3"


@pytest.mark.parametrize(
    "product_type, version, ceiling",
    [
        ("iPad5,1", "15.0", "15.8.8"),      # A8 iPad mini 4
        ("iPhone8,1", "15.8.8", "15.8.8"),  # A9 iPhone 6s
        ("iPad6,11", "16.7.16", "16.7.16"), # A9 iPad (5th gen)
        ("iPad7,3", "17.7.11", "17.7.11"),  # A10X iPad Pro
        ("iPad7,5", "17.7.11", "17.7.11"),  # A10 iPad (6th gen)
        ("iPad7,11", "18.7.1", "18.7.1"),   # A10 iPad (7th gen)
    ],
)
def test_legacy_device_specific_ceilings(product_type, version, ceiling):
    advice = _advise(product_type, version)
    assert advice["outcome"] == jailbreak.SUPPORTED
    assert advice["max_supported"] == ceiling


@pytest.mark.parametrize(
    "product_type, version",
    [
        ("iPhone7,2", "12.5.7"),  # A8 iPhone never reached iOS 15
        ("iPod7,1", "12.5.7"),    # A8 iPod never reached iOS 15
        ("iPad14,8", "26.0"),     # M2 Air shipped after 17.3.1
        ("iPad15,7", "26.0"),     # A16 iPad shipped after 17.3.1
        ("iPad16,1", "26.0"),     # A17 Pro iPad shipped after 17.3.1
    ],
)
def test_devices_that_never_ran_supported_firmware_are_refused(product_type, version):
    advice = _advise(product_type, version)
    assert advice["outcome"] == jailbreak.UNSUPPORTED_VERSION
    assert advice["can_install"] is False
    assert "max_supported" not in advice
    assert "cannot run" in advice["summary"]


@pytest.mark.parametrize(
    "product_type",
    [
        "iPad11,1",  # A12
        "iPad8,1",   # A12X
        "iPad8,9",   # A12Z
        "iPhone12,1",  # A13
    ],
)
@pytest.mark.parametrize(
    "build, label",
    [
        ("23B5044l", "26.1 beta 1"),
        ("23B5059e", "26.1 beta 2"),
        ("23B5064e", "26.1 beta 3"),
    ],
)
def test_exact_ios_26_1_beta_builds_are_supported(product_type, build, label):
    advice = _advise(product_type, "26.1", build)
    assert advice["outcome"] == jailbreak.SUPPORTED
    assert advice["can_install"] is True
    assert advice["max_supported"] == "26.1 beta 3"
    assert label in advice["summary"]


@pytest.mark.parametrize("product_type", ["iPad11,1", "iPad8,1", "iPad8,9", "iPhone12,1"])
@pytest.mark.parametrize("build", [None, "23B85", "23B5073a"])
def test_ios_26_1_final_missing_or_unknown_build_is_refused(product_type, build):
    advice = _advise(product_type, "26.1", build)
    assert advice["outcome"] == jailbreak.UNSUPPORTED_VERSION
    assert advice["can_install"] is False
    assert advice["max_supported"] == "26.1 beta 3"


def test_beta_build_does_not_apply_to_wrong_product_version():
    advice = _advise("iPhone12,1", "26.2", "23B5064e")
    assert advice["outcome"] == jailbreak.UNSUPPORTED_VERSION


def test_a12_iphone_is_excluded_from_ios_26_beta_rules():
    advice = _advise("iPhone11,8", "26.1", "23B5064e")
    assert advice["outcome"] == jailbreak.UNSUPPORTED_VERSION
    assert advice["max_supported"] == "18.7.1"


def test_a17_pro_caps_at_17_3_1():
    assert _advise("iPhone16,1", "17.3.1")["outcome"] == jailbreak.SUPPORTED
    too_new = _advise("iPhone16,1", "18.0")
    assert too_new["outcome"] == jailbreak.UNSUPPORTED_VERSION
    assert "supports up to iOS 17.3.1" in too_new["summary"]


def test_newest_chips_have_no_jailbreak():
    for product_type in (
        "iPhone17,1",  # A18 Pro
        "iPhone18,5",  # A19
        "iPad15,3",    # M3
        "iPad16,3",    # M4
        "iPad17,1",    # M5
    ):
        advice = _advise(product_type, "26.0")
        assert advice["outcome"] == jailbreak.NO_JAILBREAK
        assert advice["can_install"] is False


def test_unknown_device_is_reported_not_guessed():
    advice = _advise("iPhone99,9", "26.0")
    assert advice["outcome"] == jailbreak.UNKNOWN_DEVICE
    assert advice["can_install"] is False


def test_a_supported_chip_below_its_range_is_refused():
    assert _advise("iPhone12,1", "14.0")["outcome"] == jailbreak.UNSUPPORTED_VERSION


def test_a_new_ios_is_a_data_edit_not_a_code_change():
    """The whole point: extend the fetched list and the advisor follows, no code change."""
    compat = json.loads(json.dumps(_COMPAT))  # deep copy
    compat["support"]["A13"] = [["15.0", "18.7.1"], ["26.0", "26.2.0"]]
    advice = jailbreak.advise("iPhone12,1", "26.2", compat)
    assert advice["outcome"] == jailbreak.SUPPORTED
    assert advice["max_supported"] == "26.2"


# --------------------------------------------------------------------------- #
# fetch_compat
# --------------------------------------------------------------------------- #
class _FakeResponse:
    def __init__(self, payload, *, status_ok=True):
        self._payload = payload
        self._status_ok = status_ok

    def raise_for_status(self):
        if not self._status_ok:
            import requests
            raise requests.HTTPError("boom")

    def json(self):
        return self._payload


def test_fetch_compat_returns_the_document(monkeypatch):
    monkeypatch.setattr(
        jailbreak.requests, "get", lambda *a, **k: _FakeResponse(_COMPAT)
    )
    document = jailbreak.fetch_compat()
    assert document["support"]["A13"]


@pytest.mark.parametrize(
    "mutate",
    [
        lambda document: document.update(schema=2),
        lambda document: document["support"].update(A13=[["26.0", "18.7.1"]]),
        lambda document: document["build_support"][0].update(build=""),
        lambda document: document["build_support"][0].update(chips=["UNKNOWN"]),
    ],
)
def test_fetch_compat_rejects_malformed_schema_3_rules(monkeypatch, mutate):
    document = json.loads(json.dumps(_COMPAT))
    mutate(document)
    monkeypatch.setattr(
        jailbreak.requests, "get", lambda *a, **k: _FakeResponse(document)
    )
    with pytest.raises(jailbreak.JailbreakError):
        jailbreak.fetch_compat()


def test_fetch_compat_raises_on_network_failure(monkeypatch):
    import requests

    def boom(*a, **k):
        raise requests.ConnectionError("no net")

    monkeypatch.setattr(jailbreak.requests, "get", boom)
    with pytest.raises(jailbreak.JailbreakError):
        jailbreak.fetch_compat()


def test_fetch_compat_raises_on_malformed_document(monkeypatch):
    monkeypatch.setattr(
        jailbreak.requests, "get", lambda *a, **k: _FakeResponse({"nonsense": True})
    )
    with pytest.raises(jailbreak.JailbreakError):
        jailbreak.fetch_compat()


# --------------------------------------------------------------------------- #
# Asset selection
# --------------------------------------------------------------------------- #
def test_pick_asset_prefers_plain_ipa_over_tipa():
    assets = [
        {"name": "Dopamine.tipa", "browser_download_url": "u1", "size": 1},
        {"name": "Dopamine.ipa", "browser_download_url": "u2", "size": 2},
    ]
    assert jailbreak._pick_asset(assets)["name"] == "Dopamine.ipa"


def test_pick_asset_returns_none_when_only_tipa():
    assert jailbreak._pick_asset([{"name": "Dopamine.tipa", "browser_download_url": "u"}]) is None


# --------------------------------------------------------------------------- #
# download() bundle-id sanity (regression: Dopamine's real id is com.opa334.FuckYou)
# --------------------------------------------------------------------------- #
def _stub_download_boundaries(monkeypatch, tmp_path, bundle_id):
    monkeypatch.setattr(
        jailbreak,
        "latest_release",
        lambda: {"version": "3.0", "asset_name": "Dopamine.ipa", "url": "https://x/i.ipa", "bytes": 4},
    )

    def stream(url, destination, total, progress):
        destination.write_bytes(b"ipa!")
        return 4

    monkeypatch.setattr(jailbreak, "_stream", stream)
    monkeypatch.setattr(jailbreak.ipa_module, "inspect", lambda _p: {"bundle_id": bundle_id})


def test_download_accepts_dopamines_real_bundle_id(monkeypatch, tmp_path):
    # Dopamine's own id is com.opa334.FuckYou - it must NOT be rejected as "not Dopamine".
    _stub_download_boundaries(monkeypatch, tmp_path, "com.opa334.FuckYou")
    result = jailbreak.download(str(tmp_path))
    assert result["path"].endswith("Dopamine.ipa")


def test_download_rejects_a_non_app_payload(monkeypatch, tmp_path):
    _stub_download_boundaries(monkeypatch, tmp_path, "")
    with pytest.raises(jailbreak.JailbreakError):
        jailbreak.download(str(tmp_path))


# --------------------------------------------------------------------------- #
# CLI wiring (network / device / sideload stubbed)
# --------------------------------------------------------------------------- #
@pytest.fixture
def boundaries(monkeypatch, tmp_path):
    """Stub the compat fetch, the device read, and the sideload; parsing stays real."""
    state: dict[str, object] = {
        "calls": [],
        "device_info": {
            "ProductType": "iPhone12,1",
            "ProductVersion": "16.7.15",
            "BuildVersion": "20H380",
            "UniqueDeviceID": "checked-device",
        },
    }

    def fetch_compat():
        state["calls"].append("fetch_compat")
        return _COMPAT

    def get_device_info(serial=None, prefer_usb=True):
        state["calls"].append("device_info")
        return state["device_info"]

    def download(directory=None, *, on_progress=None):
        state["calls"].append("download")
        path = tmp_path / "Dopamine.ipa"
        path.write_bytes(b"ipa!")
        return {"version": "3.0", "asset_name": "Dopamine.ipa", "path": str(path)}

    def run_sideload(ipa_path, udid=None, **kwargs):
        state["calls"].append("run_sideload")
        state["sideload_ipa"] = ipa_path
        state["sideload_udid"] = udid
        state["sideload_kwargs"] = kwargs
        return {"status": "installed", "bundle_id": "com.opa334.dopamine", "name": "Dopamine"}

    monkeypatch.setattr(jailbreak, "fetch_compat", fetch_compat)
    monkeypatch.setattr(cli.device, "get_device_info", get_device_info)
    monkeypatch.setattr(jailbreak, "download", download)
    from ipaside_engine import sideload as sideload_module

    monkeypatch.setattr(sideload_module, "run_sideload", run_sideload)
    return state


def _run(*args: str) -> int:
    parsed = cli.build_parser().parse_args(["jailbreak", "--json", *args])
    return cli.dispatch(parsed)


def test_advise_fetches_the_list_then_reads_the_device(boundaries, capsys):
    assert _run() == 0
    assert boundaries["calls"] == ["fetch_compat", "device_info"]
    payload = json.loads(capsys.readouterr().out)
    assert payload["outcome"] == jailbreak.SUPPORTED
    assert payload["build_version"] == "20H380"


def test_advise_reports_a_fetch_failure_cleanly(monkeypatch, capsys):
    def boom():
        raise jailbreak.JailbreakError("Couldn't fetch the jailbreak compatibility list.")

    monkeypatch.setattr(jailbreak, "fetch_compat", boom)
    assert _run() == 1
    out = capsys.readouterr().out
    assert "compatibility list" in out
    assert "Traceback" not in out


def test_download_only_fetches(boundaries):
    assert _run("--download") == 0
    assert boundaries["calls"] == ["download"]
    assert "run_sideload" not in boundaries["calls"]


def test_install_downloads_then_sideloads(boundaries):
    assert _run("--install") == 0
    calls = boundaries["calls"]
    assert calls.index("fetch_compat") < calls.index("device_info")
    assert calls.index("device_info") < calls.index("download")
    assert calls.index("download") < calls.index("run_sideload")
    assert boundaries["sideload_udid"] == "checked-device"


@pytest.mark.parametrize(
    "device_info",
    [
        {
            "ProductType": "iPhone17,1",
            "ProductVersion": "26.0",
            "BuildVersion": "23A341",
            "UniqueDeviceID": "unsupported-device",
        },
        {
            "ProductType": "iPhone12,1",
            "ProductVersion": "26.1",
            "BuildVersion": "23B85",
            "UniqueDeviceID": "unsupported-device",
        },
    ],
)
def test_install_refuses_unsupported_device_before_download(
    boundaries, capsys, device_info
):
    boundaries["device_info"] = device_info
    assert _run("--install") == 1
    assert boundaries["calls"] == ["fetch_compat", "device_info"]
    payload = json.loads(capsys.readouterr().out)
    assert payload["status"] == "error"


def test_install_keeps_the_jailbreak_extensions(boundaries):
    assert _run("--install") == 0
    assert boundaries["sideload_kwargs"]["remove_extensions"] is False


def test_signed_output_options_reach_the_sideload(boundaries):
    assert _run("--install", "--keep-signed", "--signed-dir", r"D:\signed") == 0
    assert boundaries["sideload_kwargs"]["keep_signed"] is True
    assert boundaries["sideload_kwargs"]["signed_dir"] == r"D:\signed"
