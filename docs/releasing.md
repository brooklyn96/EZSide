# Releasing EZSide

GitHub Actions is the only thing that publishes EZSide releases. Pushing a `v*`
tag makes the CI workflow (`.github/workflows/ci.yml`) build the installer and
publish it to the GitHub release for that tag, with `SHA256SUMS.txt` next to it.
Nobody uploads to a release by hand: uploads overwrite same-named assets, and an
installer whose checksum file describes a different binary leaves the in-app
updater (fail-closed on a checksum mismatch) unable to update at all.

## Steps

**1. Bump the version, then make the tag equal it.**

The tag (without the `v`) must equal the version in:

- `src/iPASide.Flutter/pubspec.yaml` (`version: X.Y.Z+N`, the part before `+`)
- `src/iPASide.Engine/ipaside_engine/__init__.py` (`__version__`)

CI fails the run before building anything when either differs from the tag. Keep
`src/iPASide.Flutter/lib/app_version.dart` (`kAppVersion`) equal to the pubspec
version too (a test checks that). The default `-Version` in
`packaging/build-installer.ps1` is only for local builds; CI ignores it. Date the
`CHANGELOG.md` entry, and commit.

A tag containing `-` (for example `v1.1.0-beta1`) is published as a pre-release.

**2. Test the branch build, then tag.**

The release goes straight to every installed EZSide: the in-app updater sees it as
soon as the release job finishes. So before tagging, download the `EZSide-installer`
artifact from the branch's CI run and install it on a device. Then tag and push the
tag.

```powershell
git tag -a vX.Y.Z -m "EZSide X.Y.Z"
git push origin vX.Y.Z
```

**3. CI publishes.** The workflow runs the engine and app tests, builds the
installer on a clean machine, then the `release` job creates the
release for the tag with `EZSide-Setup-X.Y.Z-x64.exe` and `SHA256SUMS.txt`. It
refuses to overwrite: if the release already has assets, the run fails.
Watch the run under the repository's Actions tab.

## After the release

Download the published installer and confirm its hash matches its own checksum
file:

```powershell
gh release download vX.Y.Z --repo brooklyn96/EZSide
(Get-FileHash EZSide-Setup-X.Y.Z-x64.exe -Algorithm SHA256).Hash.ToLower()
Get-Content SHA256SUMS.txt
```

CI has never driven an installer against a real iPhone, which is why the device
test happens before the tag (step 2): once published, users get it immediately. The
data folder (`<install folder>\data`; dev runs: `%LOCALAPPDATA%\EZSide`) must survive an
uninstall unless the user answers Yes to the "also delete EZSide data" question.

## Re-cutting a release

Only while a version has no real users: delete the release and its tag, then tag
again.

```powershell
gh release delete vX.Y.Z --yes --cleanup-tag
git tag -d vX.Y.Z; git fetch --prune --prune-tags origin
```

If anyone has downloaded it, ship a new version instead: the updater compares
versions, so a silently changed release never reaches them.
