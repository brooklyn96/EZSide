# Releasing iPASide

Releases are published deliberately, from a build that has been verified against
a real device. CI builds on tags as well, so a release is always proven to build
on a clean machine, but it never uploads to a release — see the note in
`.github/workflows/ci.yml` for why.

## Why not automate the upload

There is no iPhone on a GitHub runner, so a CI-built installer has never been
installed, launched, or driven against a device. The installer is unsigned and
users have to click through SmartScreen to run it, so shipping a binary nobody
has executed is the wrong trade.

There is also a correctness reason. Uploads overwrite same-named assets, so if
both CI and a person could publish, one would silently replace the other's
installer and rewrite `SHA256SUMS.txt`. The in-app updater is fail-closed on a
checksum mismatch, so a release whose checksum file describes a different binary
than the one attached leaves users unable to update at all. Exactly one build may
reach a release.

## Steps

**1. Land everything and align the version.** The version appears in
`src/iPASide.Flutter/pubspec.yaml`, `src/iPASide.Flutter/lib/app_version.dart`,
and the `-Version` argument below. Date the `CHANGELOG.md` entry.

**2. Build clean.** Delete `dist/engine` so the shipped engine is rebuilt from
current source — the build script skips the engine if it already exists, which
means a stale engine will otherwise be packaged — and `flutter clean` so the
runner is relinked:

```powershell
Remove-Item dist\engine, dist\installer -Recurse -Force -ErrorAction SilentlyContinue
Push-Location src\iPASide.Flutter; flutter clean; Pop-Location
pwsh packaging\build-installer.ps1 -Version 1.0.0
```

Watch for `payload: N files` and any warning about orphaned plugin DLLs. The
build refuses to package files it cannot account for, so an unexplained failure
there is telling you something real about the build output.

**3. Verify on hardware.** With an iPhone connected and trusted:

- Uninstall any existing copy, so you are testing a first install rather than an
  upgrade, then install the new artifact silently and confirm the log says
  `install verified`.
- Launch the installed exe — not a dev build — and check cold start, that the
  device and Apple ID appear, and that Apps lists real icons.
- Close it and confirm the process exits with code **0**. A non-zero exit means
  a crash on shutdown; `0xC000041D` specifically has happened before.
- Confirm no `python.exe` running `ipaside_engine` survives the close.
- Sideload something end to end.
- Uninstall and confirm `%LOCALAPPDATA%\iPASide` survives, then reinstall.

**4. Tag and publish.**

```powershell
git tag -a v1.0.0 -m "iPASide 1.0.0 - ..."
git push origin v1.0.0
gh release create v1.0.0 --title "iPASide 1.0.0" --notes-file <notes> `
  dist\installer\iPASide-Setup-1.0.0-x64.exe dist\installer\SHA256SUMS.txt
```

`SHA256SUMS.txt` is not optional. The updater refuses to install anything it
cannot verify against it, so a release without it strands every existing user.

**5. Verify the published bytes.** Download the release and confirm the hash
matches its own checksum file, so what users get is provably what you tested:

```powershell
gh release download v1.0.0
(Get-FileHash iPASide-Setup-1.0.0-x64.exe -Algorithm SHA256).Hash.ToLower()
Get-Content SHA256SUMS.txt
```

## Re-cutting a release

While a version has no real users, it is cleaner to replace it than to stack a
patch on top of a build with a known defect:

```powershell
gh release delete v1.0.0 --yes --cleanup-tag
git tag -d v1.0.0; git fetch --prune --prune-tags origin
```

Then re-tag and publish as above. Check the download count first — if anyone has
pulled the artifact, ship a new version instead, because the updater compares
versions and a silently changed release will never reach them.
