"""The command-line surface for kept signed IPAs: the --keep-signed/--signed-dir
options shared by `sideload` and `refresh`, and the `signed` status/clean command.

These are the flags and JSON keys the desktop app drives the engine with, so they are
checked as a contract rather than through the sideload internals.
"""

import json

import pytest

from ipaside_engine import __main__ as cli


def _parse(argv):
    return cli.build_parser().parse_args(argv)


def test_sideload_neither_keeps_nor_redirects_by_default():
    args = _parse(["sideload", "app.ipa"])
    assert args.keep_signed is False
    assert args.signed_dir is None


def test_sideload_takes_keep_signed_and_signed_dir():
    args = _parse(["sideload", "app.ipa", "--keep-signed", "--signed-dir", r"D:\ipas"])
    assert args.keep_signed is True
    assert args.signed_dir == r"D:\ipas"
    assert _parse(["sideload", "app.ipa", "--no-keep-signed"]).keep_signed is False


def test_refresh_takes_the_same_two_options():
    args = _parse(["refresh", "--all", "--keep-signed", "--signed-dir", "out"])
    assert args.keep_signed is True
    assert args.signed_dir == "out"
    default = _parse(["refresh"])
    assert default.keep_signed is False
    assert default.signed_dir is None


def test_sideload_command_forwards_both_options(monkeypatch):
    seen = {}

    def fake_run_sideload(ipa, _udid, **kwargs):
        seen.update(kwargs, ipa=ipa)
        return {"name": "Example", "bundle_id": "com.example.app", "signed_ipa": None}

    monkeypatch.setattr(cli.sideload, "run_sideload", fake_run_sideload)

    assert cli.dispatch(_parse([
        "sideload", "app.ipa", "--keep-signed", "--signed-dir", "out", "--json",
    ])) == 0
    assert seen["keep_signed"] is True
    assert seen["signed_dir"] == "out"


def test_refresh_command_forwards_both_options(monkeypatch, capsys):
    seen = {}

    def fake_refresh_record(_entry, on_progress=None, **kwargs):
        seen.update(kwargs)
        return {"expires_at": "2030-01-01T00:00:00+00:00"}

    monkeypatch.setattr(cli.refresh, "records", lambda: [{"bundle_id": "com.example.app"}])
    monkeypatch.setattr(cli.sideload, "refresh_record", fake_refresh_record)

    assert cli.dispatch(_parse([
        "refresh", "--all", "--keep-signed", "--signed-dir", "out", "--json",
    ])) == 0
    # _cmd_refresh reports per-app failures instead of raising, so prove it really ran.
    assert json.loads(capsys.readouterr().out)["refreshed"][0]["status"] == "installed"
    assert seen["keep_signed"] is True
    assert seen["signed_dir"] == "out"


def test_signed_reports_by_default(monkeypatch, capsys):
    seen = {}

    def fake_status(directory=None):
        seen["directory"] = directory
        return {"directory": "D", "count": 1, "bytes": 42, "files": [
            {"name": "app_Signed.ipa", "bytes": 42, "modified": "2026-07-25T12:00:00+00:00"},
        ]}

    monkeypatch.setattr(cli.sideload, "signed_status", fake_status)
    monkeypatch.setattr(cli.sideload, "clean_signed", lambda *_a, **_k: pytest.fail("must not clean"))

    assert cli.dispatch(_parse(["signed", "--dir", "D", "--json"])) == 0
    assert seen["directory"] == "D"
    payload = json.loads(capsys.readouterr().out)
    assert payload["count"] == 1
    assert payload["files"][0]["name"] == "app_Signed.ipa"


def test_signed_clean_removes_and_reports_what_it_freed(monkeypatch, capsys):
    seen = {}

    def fake_clean(directory=None):
        seen["directory"] = directory
        return {"directory": "D", "removed": 2, "bytes_freed": 99}

    monkeypatch.setattr(cli.sideload, "clean_signed", fake_clean)
    monkeypatch.setattr(cli.sideload, "signed_status", lambda *_a, **_k: pytest.fail("must not report"))

    assert cli.dispatch(_parse(["signed", "--clean", "--dir", "D", "--json"])) == 0
    assert seen["directory"] == "D"
    assert json.loads(capsys.readouterr().out) == {
        "directory": "D", "removed": 2, "bytes_freed": 99,
    }


def test_signed_defaults_to_the_apps_own_folder():
    args = _parse(["signed"])
    assert args.clean is False
    assert args.dir is None
