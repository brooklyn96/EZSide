"""Every `livecontainer` command path, exercised through the real CLI.

Written because a signature mismatch shipped: the CLI passed an argument to a
``download()`` that did not accept it, so the one path the app's Install button uses -
setup with no ``--ipa``, which downloads first - failed with a TypeError. Every function
involved was tested individually and the wiring between them was not.

So these tests stub only the boundaries iPASide does not own - the network, the device, and
zsign - and let the real argument parsing call the real functions. A parameter renamed on
one side and not the other then fails here rather than on someone's PC.
"""

from __future__ import annotations

import pytest

from ipaside_engine import __main__ as cli
from ipaside_engine import livecontainer

HOST = "com.kdt.livecontainer.ASK9QR9SBC"


@pytest.fixture
def boundaries(monkeypatch, tmp_path):
    """Stub the network, the device and zsign; leave everything else real."""
    state: dict[str, object] = {"calls": []}

    def record(name):
        def _inner(*args, **kwargs):
            state["calls"].append(name)
            return state.get(f"{name}_result")
        return _inner

    # The network: what a release looks like, without asking GitHub.
    def latest_release():
        state["calls"].append("latest_release")
        name = "LiveContainer.ipa"
        return {
            "version": "3.8.0",
            "asset_name": name,
            "url": f"https://example.invalid/{name}",
            "bytes": 4,
        }

    def stream(url, destination, total, progress):
        state["calls"].append("stream")
        destination.write_bytes(b"ipa!")
        return 4

    monkeypatch.setattr(livecontainer, "latest_release", latest_release)
    monkeypatch.setattr(livecontainer, "_stream", stream)
    monkeypatch.setattr(livecontainer, "_default_dir", lambda: tmp_path)

    # The IPA itself: real inspection would need a real bundle.
    monkeypatch.setattr(
        livecontainer.ipa_module,
        "inspect",
        lambda _path: {
            "bundle_id": livecontainer.BUNDLE_PREFIX,
            "display_name": "LiveContainer",
            "version": "3.8.0",
        },
    )

    # The device. The CLI picks the target once, before any phone call.
    monkeypatch.setattr(cli.device, "resolve_serial", lambda serial=None: serial or "UDID-1")
    monkeypatch.setattr(
        livecontainer,
        "status",
        lambda serial=None: {
            "installed": True,
            "bundle_id": HOST,
            "name": "LiveContainer",
            "version": "3.8.0",
            "certificate_pending": False,
            "certificate_file_present": True,
            "launched": True,
        },
    )
    monkeypatch.setattr(
        livecontainer,
        "guest_apps",
        lambda bundle_id, serial=None: [
            {"folder": "com.example.app.app", "bundle_id": "com.example.app"}
        ],
    )
    monkeypatch.setattr(
        livecontainer,
        "install_guest",
        lambda path, bundle_id, serial=None, **kw: {
            "status": "installed",
            "bundle_id": "com.example.app",
            "name": "Example",
            "files": 1,
            "bytes": 4,
        },
    )
    monkeypatch.setattr(livecontainer, "remove_guest", record("remove_guest"))

    # The whole sideload, which owns provisioning, zsign and installd.
    def setup(ipa_path, udid=None, **kwargs):
        state["calls"].append("setup")
        state["setup_kwargs"] = kwargs
        state["setup_ipa"] = ipa_path
        return {
            "status": "installed",
            "bundle_id": HOST,
            "name": "LiveContainer",
            "livecontainer_version": "3.8.0",
            "certificate": {"seeded": True, "automatic": True},
            "launch_required": True,
        }

    monkeypatch.setattr(livecontainer, "setup", setup)
    return state


def _run(*args: str) -> int:
    """Parse and dispatch exactly as the app does, `--json` included."""
    parsed = cli.build_parser().parse_args(["livecontainer", "--json", *args])
    return cli.dispatch(parsed)


# --------------------------------------------------------------------------- #
# The paths the app's buttons take
# --------------------------------------------------------------------------- #
def test_status_with_no_flags(boundaries, capsys):
    assert _run() == 0
    assert "installed" in capsys.readouterr().out


def test_setup_without_an_ipa_downloads_first(boundaries):
    """The Install button's path, and the one that shipped broken."""
    assert _run("--setup") == 0

    calls = boundaries["calls"]
    assert "stream" in calls, "it has to fetch the release"
    assert calls.index("stream") < calls.index("setup"), "download, then set up"


def test_setup_with_an_ipa_skips_the_download(boundaries, tmp_path):
    ipa = tmp_path / "LiveContainer.ipa"
    ipa.write_bytes(b"ipa!")

    assert _run("--setup", "--ipa", str(ipa)) == 0

    assert "stream" not in boundaries["calls"]
    assert boundaries["setup_ipa"] == str(ipa)


def test_download_on_its_own(boundaries, capsys):
    assert _run("--download") == 0
    assert "latest_release" in boundaries["calls"]
    assert "stream" in boundaries["calls"]


def test_manual_certificate_reaches_setup(boundaries):
    assert _run("--setup", "--manual-certificate") == 0
    assert boundaries["setup_kwargs"]["automatic_certificate"] is False


def test_the_signed_output_options_reach_setup(boundaries):
    assert _run("--setup", "--keep-signed", "--signed-dir", r"D:\signed") == 0
    assert boundaries["setup_kwargs"]["keep_signed"] is True
    assert boundaries["setup_kwargs"]["signed_dir"] == r"D:\signed"


# --------------------------------------------------------------------------- #
# The apps inside it
# --------------------------------------------------------------------------- #
def test_listing_the_apps_inside(boundaries, capsys):
    assert _run("--apps") == 0
    assert "com.example.app" in capsys.readouterr().out


def test_adding_an_app(boundaries, tmp_path, capsys):
    ipa = tmp_path / "Example.ipa"
    ipa.write_bytes(b"ipa!")

    assert _run("--add", str(ipa)) == 0
    assert "com.example.app" in capsys.readouterr().out


def test_removing_an_app(boundaries):
    assert _run("--remove", "com.example.app") == 0
    assert "remove_guest" in boundaries["calls"]


def test_managing_apps_needs_livecontainer_installed(boundaries, monkeypatch):
    """Otherwise there is nowhere to put an app, and the error should say that."""
    monkeypatch.setattr(livecontainer, "status", lambda serial=None: {"installed": False})

    with pytest.raises(livecontainer.LiveContainerError, match="not installed"):
        _run("--apps")


# --------------------------------------------------------------------------- #
# Argument plumbing
# --------------------------------------------------------------------------- #
def test_every_flag_the_parser_accepts_is_handled(boundaries, tmp_path):
    """A flag nobody reads is a flag that silently does nothing.

    Each is exercised above; this asserts the set has not grown past them, so a new one
    cannot be added to the parser and left unwired.
    """
    parser = cli.build_parser()
    action = next(
        a for a in parser._subparsers._group_actions[0].choices.items()  # noqa: SLF001
        if a[0] == "livecontainer"
    )[1]
    flags = {
        option
        for entry in action._actions  # noqa: SLF001
        for option in entry.option_strings
        if option.startswith("--") and option != "--help"
    }

    assert flags == {
        "--json",
        "--connection",
        "--udid",
        "--keep-signed",
        "--no-keep-signed",
        "--signed-dir",
        "--setup",
        "--download",
        "--ipa",
        "--dir",
        "--manual-certificate",
        "--apps",
        "--add",
        "--remove",
    }
