"""zsign command construction (flag mapping for the advanced options)."""

from ipaside_engine import signing


class _FakeProc:
    returncode = 0
    stdout = "signed ok"
    stderr = ""


def _capture_cmd(monkeypatch):
    captured = {}
    monkeypatch.setattr(signing, "resolve_zsign", lambda: "zsign")

    def fake_run(cmd, **_kwargs):
        captured["cmd"] = cmd
        return _FakeProc()

    monkeypatch.setattr(signing.subprocess, "run", fake_run)
    return captured


def test_sign_ipa_maps_all_advanced_flags(monkeypatch):
    captured = _capture_cmd(monkeypatch)
    signing.sign_ipa(
        "in.ipa", "out.ipa",
        p12_path="id.p12", p12_password="pw", profile_path="p.mobileprovision",
        bundle_id="com.x", display_name="X App", bundle_version="9.9",
        dylibs=["a.dylib", "b.dylib"], weak_dylibs=True, inject_into_extensions=True,
        enable_file_sharing=True, remove_extensions=True, remove_uisd=False,
    )
    cmd = captured["cmd"]
    assert cmd[0] == "zsign"
    assert cmd[-1] == "in.ipa"  # input is always last
    assert cmd[cmd.index("-b") + 1] == "com.x"
    assert cmd[cmd.index("-n") + 1] == "X App"
    assert cmd[cmd.index("-r") + 1] == "9.9"
    assert cmd.count("-l") == 2 and "a.dylib" in cmd and "b.dylib" in cmd
    assert "-w" in cmd            # weak
    assert "-P" in cmd            # inject into extensions
    assert "-S" in cmd            # file sharing
    assert "-E" in cmd            # remove extensions
    assert "-U" not in cmd        # remove_uisd=False -> no flag


def test_sign_ipa_minimal_has_no_optional_flags(monkeypatch):
    captured = _capture_cmd(monkeypatch)
    signing.sign_ipa(
        "in.ipa", "out.ipa",
        p12_path="id.p12", p12_password="pw", profile_path="p.mobileprovision",
        remove_extensions=False, remove_watch=False, remove_uisd=False,
    )
    cmd = captured["cmd"]
    for flag in ("-b", "-n", "-r", "-l", "-w", "-P", "-S", "-E", "-W", "-U", "-t", "-e"):
        assert flag not in cmd


def test_sign_ipa_passes_explicit_entitlements(monkeypatch):
    # -e replaces the profile's entitlements wholesale, which is how LiveContainer gets
    # its 128 expanded keychain groups instead of the profile's bare wildcard.
    captured = _capture_cmd(monkeypatch)
    signing.sign_ipa(
        "in.ipa", "out.ipa",
        p12_path="id.p12", p12_password="pw", profile_path="p.mobileprovision",
        entitlements=r"C:\scratch\entitlements.plist",
    )
    cmd = captured["cmd"]
    assert cmd[cmd.index("-e") + 1] == r"C:\scratch\entitlements.plist"


def test_resolve_helper_dylib_honours_the_env_override(monkeypatch, tmp_path):
    dylib = tmp_path / "iPASideCertImport.dylib"
    dylib.write_bytes(b"\xcf\xfa\xed\xfe")
    monkeypatch.setenv("IPASIDE_CERT_IMPORT_DYLIB", str(dylib))
    assert signing.resolve_helper_dylib() == str(dylib)


def test_resolve_helper_dylib_is_none_when_not_shipped(monkeypatch, tmp_path):
    """A build without the dylib falls back to a manual import rather than failing."""
    monkeypatch.delenv("IPASIDE_CERT_IMPORT_DYLIB", raising=False)
    monkeypatch.setattr(signing.paths, "resource_dir", lambda: tmp_path)
    monkeypatch.setattr(signing.sys, "executable", str(tmp_path / "python.exe"))
    assert signing.resolve_helper_dylib() is None


def test_sign_ipa_passes_the_temp_folder_to_zsign(monkeypatch):
    # zsign unpacks and re-zips the whole app in its temp folder, so -t is what keeps
    # a sideload's heavy I/O on the disk the user chose instead of the system drive.
    captured = _capture_cmd(monkeypatch)
    signing.sign_ipa(
        "in.ipa", "out.ipa",
        p12_path="id.p12", p12_password="pw", profile_path="p.mobileprovision",
        temp_folder=r"D:\scratch\ipaside_sign_ab12",
    )
    cmd = captured["cmd"]
    assert cmd[cmd.index("-t") + 1] == r"D:\scratch\ipaside_sign_ab12"


def test_sign_ipa_raises_on_zsign_failure(monkeypatch):
    monkeypatch.setattr(signing, "resolve_zsign", lambda: "zsign")

    class Bad:
        returncode = 1
        stdout = ""
        stderr = "boom"

    monkeypatch.setattr(signing.subprocess, "run", lambda cmd, **k: Bad())
    try:
        signing.sign_ipa("in.ipa", "out.ipa", p12_path="p", p12_password="w", profile_path="m")
        assert False, "expected SigningError"
    except signing.SigningError as exc:
        assert "boom" in str(exc)
