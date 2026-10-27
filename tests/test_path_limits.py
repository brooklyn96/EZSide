"""Where sign-time scratch goes, and why Windows' path limit decides it.

zsign writes `<binary>.archo.N` beside every Mach-O it re-signs, using file APIs capped
at MAX_PATH. An app with frameworks nested inside frameworks is ~180 characters deep on
its own, so the scratch directory's path is what decides whether it can be signed - and
when it does not fit, zsign dies on an fopen with both streams empty and a -1 exit.

The numbers here come from two measured runs against LiveContainer+SideStore: one that
failed at a 264-character path and one that succeeded at 248.
"""

from __future__ import annotations

import zipfile
from pathlib import Path

import pytest

from ipaside_engine import ipa, sideload

# Longest entry in LiveContainer+SideStore.ipa, whose nesting is
# SideStoreApp.framework/Frameworks/KeychainAccess_<hash>_PackageProduct.framework/...
DEEP = 178

# Longest entry in a large but flat app (Instagram). This one signs today with the
# scratch beside the signed output, so it must keep doing so.
FLAT = 160


def _ipa(tmp_path: Path, *names: str) -> Path:
    """An archive with the given entry names; only their lengths matter here."""
    path = tmp_path / "app.ipa"
    with zipfile.ZipFile(path, "w") as archive:
        for name in names:
            archive.writestr(name, b"x")
    return path


# --------------------------------------------------------------------------- #
# Measuring how deep an IPA is
# --------------------------------------------------------------------------- #
def test_deepest_entry_is_the_longest_path(tmp_path):
    path = _ipa(
        tmp_path,
        "Payload/A.app/Info.plist",
        "Payload/A.app/Frameworks/B.framework/Frameworks/C.framework/C",
        "Payload/A.app/A",
    )
    longest = "Payload/A.app/Frameworks/B.framework/Frameworks/C.framework/C"
    assert ipa.deepest_entry(str(path)) == len(longest)


def test_deepest_entry_of_an_empty_archive_is_zero(tmp_path):
    path = tmp_path / "empty.ipa"
    with zipfile.ZipFile(path, "w"):
        pass
    assert ipa.deepest_entry(str(path)) == 0


@pytest.mark.parametrize("contents", [b"", b"not a zip at all"])
def test_deepest_entry_of_an_unreadable_file_is_zero(tmp_path, contents):
    """Sizing a directory name is not the place to reject a bad IPA."""
    path = tmp_path / "broken.ipa"
    path.write_bytes(contents)
    assert ipa.deepest_entry(str(path)) == 0


def test_deepest_entry_of_a_missing_file_is_zero(tmp_path):
    assert ipa.deepest_entry(str(tmp_path / "nope.ipa")) == 0


# --------------------------------------------------------------------------- #
# Choosing where the scratch goes
# --------------------------------------------------------------------------- #
def test_a_flat_app_keeps_its_scratch_beside_the_signed_output():
    """The disk the user chose is where the heavy I/O belongs, when it fits."""
    target = Path(r"C:\Users\somebody\AppData\Local\iPASide\signed")
    assert sideload._scratch_root(target, FLAT) == target


def test_a_deeply_nested_app_moves_its_scratch_somewhere_shorter():
    target = Path(r"C:\Users\somebody\AppData\Local\iPASide\signed")
    assert sideload._scratch_root(target, DEEP) != target


def test_an_unmeasured_ipa_changes_nothing():
    """Zero means the IPA could not be read; that is not a reason to relocate."""
    target = Path(r"C:\Users\somebody\AppData\Local\iPASide\signed")
    assert sideload._scratch_root(target, 0) == target


def test_a_short_target_holds_even_a_deep_app():
    assert sideload._scratch_root(Path(r"D:\s"), DEEP) == Path(r"D:\s")


# --------------------------------------------------------------------------- #
# The constants, against what was actually observed
# --------------------------------------------------------------------------- #
def test_the_path_that_zsign_signed_is_not_refused():
    """248 characters worked on hardware, so nothing here may reject it.

    Asserted as arithmetic rather than by creating a directory: pytest's own tmp_path is
    ~97 characters, so a filesystem version of this would be measuring the test runner.
    """
    # The successful run's scratch was 36 characters with a 178-deep bundle.
    assert 36 + sideload._ZSIGN_HEADROOM + DEEP <= sideload._MAX_PATH


def test_the_path_that_zsign_died_on_would_be_caught():
    """264 characters failed, so a scratch that long must not be chosen."""
    # The failing run's scratch was 52 characters with a 178-deep bundle.
    assert 52 + sideload._ZSIGN_HEADROOM + DEEP > sideload._MAX_PATH


def test_headroom_matches_what_zsign_actually_appends():
    # zsign_folder_<11 digits> + two separators + ".archo.0"
    assert sideload._ZSIGN_HEADROOM == 1 + len("zsign_folder_29225216684") + 1 + len(".archo.0")


def test_the_scratch_prefix_stays_short():
    """Every character here is one an app bundle cannot use."""
    assert len(sideload.SCRATCH_PREFIX) <= 6


# --------------------------------------------------------------------------- #
# When nothing fits
# --------------------------------------------------------------------------- #
def test_an_impossible_path_is_refused_with_a_reason(tmp_path, monkeypatch):
    """A long user name plus a deep bundle can leave no room anywhere.

    Better to say so than to let zsign fail on an fopen with nothing to report.
    """
    long_temp = tmp_path / ("t" * 120)
    long_temp.mkdir()
    monkeypatch.setattr(sideload.tempfile, "gettempdir", lambda: str(long_temp))

    with pytest.raises(sideload.SideloadError) as excinfo:
        sideload._open_signed_dir(str(long_temp), 200)

    message = str(excinfo.value)
    assert "nested too deeply" in message
    assert "200 characters" in message
    assert "Settings" in message, "the message should say what to do about it"


def test_a_refused_run_leaves_no_scratch_behind(tmp_path, monkeypatch):
    long_temp = tmp_path / ("t" * 120)
    long_temp.mkdir()
    monkeypatch.setattr(sideload.tempfile, "gettempdir", lambda: str(long_temp))

    before = set(long_temp.iterdir())
    with pytest.raises(sideload.SideloadError):
        sideload._open_signed_dir(str(long_temp), 200)
    assert set(long_temp.iterdir()) == before


# --------------------------------------------------------------------------- #
# The folder itself
# --------------------------------------------------------------------------- #
def test_the_scratch_is_created_and_is_empty(tmp_path):
    target, scratch = sideload._open_signed_dir(str(tmp_path), 40)
    assert target == tmp_path.resolve()
    assert scratch.is_dir()
    assert not list(scratch.iterdir())


def test_two_runs_get_separate_scratch_folders(tmp_path):
    _a, first = sideload._open_signed_dir(str(tmp_path), 40)
    _b, second = sideload._open_signed_dir(str(tmp_path), 40)
    assert first != second
