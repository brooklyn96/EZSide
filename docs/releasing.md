# Releasing EZSide

GitHub Actions is the only thing that publishes EZSide releases. Pushing a `v*`
tag makes the CI workflow (`.github/workflows/ci.yml`) build the installer and
publish it to the GitHub release for that tag, with `SHA256SUMS.txt` next to it.
Nobody uploads to a release by hand: uploads overwrite same-named assets, and an
installer whose checksum file describes a different binary leaves the in-app
updater (fail-closed on a checksum mismatch) unable to update at all.

## Steps

**1. Bump the version in the three places that must match.**

- `src/iPASide.Flutter/pubspec.yaml` (`version: X.Y.Z+N`)
- `src/iPASide.Flutter/lib/app_version.dart` (`kAppVersion`)
- `packaging/build-installer.ps1` (default `-Version`)

`src/iPASide.Engine/ipaside_engine/__init__.py` (`__version__`) carries the same
number. Date the `CHANGELOG.md` entry, and commit.

**2. Tag and push the tag.**

```powershell
git tag -a vX.Y.Z -m "EZSide X.Y.Z"
git push origin vX.Y.Z
```

**3. CI publishes.** The workflow runs the engine and app tests, builds the
installer on a clean machine, then the `release` job creates (or updates) the
release for the tag with `EZSide-Setup-X.Y.Z-x64.exe` and `SHA256SUMS.txt`.
Watch the run under the repository's Actions tab.

## After the release

Download the published installer and confirm its hash matches its own checksum
file:

```powershell
gh release download vX.Y.Z --repo brooklyn96/EZSide
(Get-FileHash EZSide-Setup-X.Y.Z-x64.exe -Algorithm SHA256).Hash.ToLower()
Get-Content SHA256SUMS.txt
```

A CI-built installer has never been driven against a real iPhone by CI itself, so
install it on a device before telling anyone about the release. The data folder
`%LOCALAPPDATA%\EZSide` must survive an uninstall.

## Re-cutting a release

Only while a version has no real users: delete the release and its tag, then tag
again.

```powershell
gh release delete vX.Y.Z --yes --cleanup-tag
git tag -d vX.Y.Z; git fetch --prune --prune-tags origin
```

If anyone has downloaded it, ship a new version instead: the updater compares
versions, so a silently changed release never reaches them.
