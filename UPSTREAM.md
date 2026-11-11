# Upstream

EZSide is based on [iPASide](https://github.com/pwnapplehat/iPASide) by pwnapplehat (MIT License, see `LICENSE`).

| Item | Value |
|---|---|
| Upstream repository | https://github.com/pwnapplehat/iPASide |
| Imported commit | `fcddc6258f76601ea45afaec5f5c1cc6ed89bc85` (release 1.2.15, 2026-11-11), taken as a port of `5de46b9` and `fcddc62` (`8334cc8..fcddc62` minus `f31250e`) on top of `8334cc8dfe1632c18de7119ca140d38bd12f3f75` (release 1.2.14, 2026-10-29). The pairing Wi-Fi Sync change `f31250e` was left out: EZSide already turns on Wi-Fi Sync when a device is connected over USB |
| Import method | `git archive` of `cda4a0c` (release 1.2.13), committed as one import commit (no upstream history); `8334cc8`, `5de46b9` and `fcddc62` ported by hand |

## Taking upstream fixes

1. Fetch upstream into a separate clone: `git clone https://github.com/pwnapplehat/iPASide.git`.
2. Diff from the last imported commit to the new upstream commit: `git diff <last-imported> <new> > upstream.patch`.
3. Apply in this repo on a branch: `git apply -3 upstream.patch`, resolve conflicts, keep EZSide changes.
4. Update the "Imported commit" row above in the same commit.
