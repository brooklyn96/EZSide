"""Tests for .deb tweak extraction and Mach-O arch detection.

Builds synthetic .debs (ar -> data.tar.* -> a fake Mach-O dylib) so the extractor
is exercised end to end without shipping real binaries, plus a fat-binary arch
check. The real InstaXhAT .debs (data.tar.lzma) are verified separately live.
"""

import struct
from pathlib import Path

import pytest

from _helpers import make_deb, thin_macho
from ipaside_engine import ipa, tweak


@pytest.mark.parametrize("comp", ["gz", "xz", "bz2"])
def test_extract_deb_rootless(tmp_path, isolated_data, comp):
    deb = tmp_path / f"com.example.tweak-{comp}.deb"
    make_deb(deb, thin_macho(), member="var/jb/Library/MobileSubstrate/DynamicLibraries/Demo.dylib", comp=comp)
    items = tweak.resolve(str(deb))
    assert len(items) == 1
    assert items[0]["name"] == "Demo.dylib"
    assert items[0]["arches"] == ["arm64"]
    assert items[0]["from_deb"] == deb.name
    assert Path(items[0]["path"]).read_bytes() == thin_macho()


def test_extract_deb_rootful_arm64e(tmp_path, isolated_data):
    deb = tmp_path / "rootful.deb"
    make_deb(deb, thin_macho(cpusubtype=2), member="Library/MobileSubstrate/DynamicLibraries/Root.dylib", comp="gz")
    items = tweak.resolve(str(deb))
    assert items[0]["name"] == "Root.dylib"
    assert items[0]["arches"] == ["arm64e"]  # cpusubtype 2 == arm64e


def test_resolve_plain_dylib_passthrough(tmp_path):
    dylib = tmp_path / "Plain.dylib"
    dylib.write_bytes(thin_macho())
    assert tweak.resolve(str(dylib)) == [
        {"path": str(dylib), "name": "Plain.dylib", "arches": ["arm64"], "from_deb": None}
    ]


def test_deb_without_dylib_errors(tmp_path, isolated_data):
    deb = tmp_path / "docs.deb"
    make_deb(deb, b"just a readme", member="var/jb/usr/share/readme.txt", comp="gz")
    with pytest.raises(ValueError, match="no .dylib"):
        tweak.resolve(str(deb))


def test_unsupported_tweak_type(tmp_path):
    other = tmp_path / "notes.txt"
    other.write_text("nope")
    with pytest.raises(ValueError, match="unsupported"):
        tweak.resolve(str(other))


def test_macho_arches_fat(tmp_path):
    fat = struct.pack(">II", 0xCAFEBABE, 2)  # FAT_MAGIC, 2 slices
    fat += struct.pack(">IIIII", 0x0100000C, 0, 0, 0, 0)  # arm64
    fat += struct.pack(">IIIII", 0x0100000C, 2, 0, 0, 0)  # arm64e
    path = tmp_path / "fat.dylib"
    path.write_bytes(fat)
    assert ipa.macho_arches(path) == {"arm64", "arm64e"}
