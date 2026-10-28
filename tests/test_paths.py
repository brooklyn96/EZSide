"""data_dir() resolution order: IPASIDE_DATA_DIR, installed layout, per-user default."""

import sys
from pathlib import Path

import pytest

from ipaside_engine import paths


def _fake_install(root: Path) -> Path:
    """Lay out ``<root>/app/engine/python/python.exe``; return the interpreter path.

    ``root`` is the install folder: ``app`` holds the program, ``data`` is its sibling.
    """
    exe = root / "app" / "engine" / "python" / "python.exe"
    exe.parent.mkdir(parents=True)
    exe.write_bytes(b"")
    return exe


@pytest.fixture
def not_installed(monkeypatch, tmp_path):
    """The engine runs from a venv, with its package outside any installed layout."""
    monkeypatch.delenv(paths.DATA_DIR_ENV, raising=False)
    monkeypatch.setattr(sys, "executable", str(tmp_path / "venv" / "Scripts" / "python.exe"))
    monkeypatch.setattr(paths, "resource_dir", lambda: tmp_path / "src" / "ipaside_engine")


def test_default_is_localappdata(not_installed, isolated_data):
    assert paths.data_dir() == isolated_data / "EZSide"


def test_installed_layout_uses_data_next_to_the_program(
    not_installed, monkeypatch, tmp_path, isolated_data
):
    app = tmp_path / "D" / "EZSide"
    monkeypatch.setattr(sys, "executable", str(_fake_install(app)))

    assert paths.installed_app_dir() == app / "app"
    assert paths.data_dir() == app / "data"
    assert (app / "data").is_dir()
    assert not (app / "app" / "data").exists()
    assert not (isolated_data / "EZSide").exists()


def test_installed_layout_is_found_from_the_package_when_executable_is_unhelpful(
    not_installed, monkeypatch, tmp_path
):
    app = tmp_path / "EZSide"
    _fake_install(app)
    monkeypatch.setattr(sys, "executable", "")
    monkeypatch.setattr(
        paths, "resource_dir",
        lambda: app / "app" / "engine" / "python" / "Lib" / "site-packages" / "ipaside_engine",
    )

    assert paths.data_dir() == app / "data"


def test_env_override_beats_the_installed_layout(not_installed, monkeypatch, tmp_path):
    monkeypatch.setattr(sys, "executable", str(_fake_install(tmp_path / "EZSide")))
    custom = tmp_path / "elsewhere" / "state"
    monkeypatch.setenv(paths.DATA_DIR_ENV, str(custom))

    assert paths.data_dir() == custom
    assert custom.is_dir()
    assert paths.installs_file() == custom / "sideloads.json"


def test_suite_isolation_holds_under_an_installed_interpreter(monkeypatch, tmp_path, isolated_data):
    """Conftest defaults only: running the suite with the installed python must not
    resolve to the real install's data folder."""
    inst = tmp_path / "inst"
    monkeypatch.setattr(sys, "executable", str(_fake_install(inst)))

    assert paths.installed_app_dir() == inst / "app"  # the trap is really armed
    data = paths.data_dir()
    assert data == isolated_data / "EZSide"
    assert inst not in data.parents
    assert not (inst / "data").exists()


def test_relative_env_override_is_made_absolute(not_installed, monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv(paths.DATA_DIR_ENV, "rel-data")

    assert paths.data_dir() == tmp_path / "rel-data"
    assert paths.data_dir().is_absolute()


def test_blank_env_override_is_ignored(not_installed, monkeypatch, isolated_data):
    monkeypatch.setenv(paths.DATA_DIR_ENV, "   ")

    assert paths.data_dir() == isolated_data / "EZSide"


def test_a_python_folder_without_the_interpreter_is_not_an_install(
    not_installed, monkeypatch, tmp_path, isolated_data
):
    (tmp_path / "EZSide" / "app" / "engine" / "python").mkdir(parents=True)
    monkeypatch.setattr(
        sys, "executable",
        str(tmp_path / "EZSide" / "app" / "engine" / "python" / "python.exe"),
    )

    assert paths.installed_app_dir() is None
    assert paths.data_dir() == isolated_data / "EZSide"


def test_every_derived_path_follows_the_data_dir(not_installed, monkeypatch, tmp_path):
    monkeypatch.setenv(paths.DATA_DIR_ENV, str(tmp_path / "data"))
    root = tmp_path / "data"

    for folder in (
        paths.anisette_dir(), paths.session_dir(), paths.accounts_dir(),
        paths.signing_dir(), paths.signed_dir(), paths.tweaks_dir(), paths.downloads_dir(),
    ):
        assert root in folder.parents
    assert paths.autorefresh_log().parent == root
