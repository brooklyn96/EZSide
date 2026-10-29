# Upstream

EZSide is based on [iPASide](https://github.com/pwnapplehat/iPASide) by pwnapplehat (MIT License, see `LICENSE`).

| Item | Value |
|---|---|
| Upstream repository | https://github.com/pwnapplehat/iPASide |
| Imported commit | `8334cc8dfe1632c18de7119ca140d38bd12f3f75` (release 1.2.14, 2026-10-29), taken as a port of that one commit on top of `cda4a0c329147bf65f4b55ee2c90f3de3a04f537` (release 1.2.13, 2026-10-27) |
| Import method | `git archive` of `cda4a0c`, committed as one import commit (no upstream history); `8334cc8` ported by hand |

## Taking upstream fixes

1. Fetch upstream into a separate clone: `git clone https://github.com/pwnapplehat/iPASide.git`.
2. Diff from the last imported commit to the new upstream commit: `git diff <last-imported> <new> > upstream.patch`.
3. Apply in this repo on a branch: `git apply -3 upstream.patch`, resolve conflicts, keep EZSide changes.
4. Update the "Imported commit" row above in the same commit.
