"""LiveContainer setup: sign it with what it needs, then hand it the certificate.

LiveContainer runs other apps inside itself, which is how it gets past the three-app
limit a free Apple ID imposes: the phone sees one installed app no matter how many are
loaded into it. To sign those guest apps on device it needs JIT-less mode, and JIT-less
mode needs two things that an ordinary sideload does not provide.

**Entitlements the profile does not spell out.** A free profile grants ``TEAMID.*`` for
keychain access, but LiveContainer looks for 128 explicit
``TEAMID.com.kdt.livecontainer.shared.N`` groups, plus a shared app group. The wildcard
legally covers the explicit entries, so signing with the expanded list is accepted -
which is what :func:`build_entitlements` produces, and why this needs a signing profile
rather than plain defaults. App groups also have to be attached to the App ID before the
provisioning profile is downloaded; :mod:`ipaside_engine.provision` handles that.

**Its own signing certificate.** LiveContainer reads the certificate from the app group's
``UserDefaults`` suite, and that container cannot be written from a PC: house_arrest's AFC
session lists directories through ``..`` but refuses to open or stat anything outside the
app's own container. Normally the user imports the ``.p12`` by hand through LiveContainer's
Settings. Instead we leave an import request in its ``Documents`` - which *is* writable,
because LiveContainer declares ``UIFileSharingEnabled`` - and inject a small dylib that
performs the import on first launch. See tools/lc-cert-import/.

If that dylib is not present in the build, everything still works; the certificate simply
has to be imported by hand, and :func:`setup` says so in its result.
"""

from __future__ import annotations

import asyncio
import plistlib
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, Callable

import requests

from . import apps, ipa as ipa_module, lockdown, provision, signing
from .errors import EngineError

#: LiveContainer's own identifier; the team id is appended for a free account.
BUNDLE_PREFIX = "com.kdt.livecontainer"

#: How many explicit keychain access groups LiveContainer expects. It derives guest-app
#: keychain groups by index, so a short list silently breaks apps that use the keychain.
KEYCHAIN_GROUPS = 128

#: LiveContainer looks for the app group of an AltStore-family store and uses the first it
#: can reach, so both are provisioned and signed in - it decides which at runtime.
_GROUP_PREFIXES = (
    "group.com.SideStore.SideStore.",
    "group.com.rileytestut.AltStore.",
)

#: Where the release comes from, and the only place iPASide will download it from.
RELEASES_URL = "https://api.github.com/repos/LiveContainer/LiveContainer/releases/latest"
PROJECT_URL = "https://github.com/LiveContainer/LiveContainer"

#: Written into LiveContainer's Documents for the injected dylib to consume.
REQUEST_NAME = "iPASide-cert-import.plist"
CERTIFICATE_NAME = "iPASide-certificate.p12"

#: Where LiveContainer keeps the apps it runs inside itself, under its own Documents.
#: Reachable over house_arrest, which is what lets iPASide put an app there directly.
GUEST_APPS_DIR = "/Documents/Applications"

#: Name of the signing profile :mod:`ipaside_engine.sideload` resolves for LiveContainer.
SIGNING_PROFILE = "livecontainer"

_TIMEOUTS = (20, 60)
_CHUNK_BYTES = 1 << 20

# (phase, percent, step) - the same shape sideload reports, so a UI can render both.
ProgressFn = Callable[[str, Any, "str | None"], None]


class LiveContainerError(EngineError):
    """LiveContainer could not be set up."""


def bundle_id_for(team_id: str) -> str:
    """LiveContainer's team-scoped bundle id, which is what its app groups key off."""
    return f"{BUNDLE_PREFIX}.{team_id}"


def app_group_identifiers(team_id: str) -> list[str]:
    """The app groups LiveContainer looks for, in the order it prefers them."""
    return [f"{prefix}{team_id}" for prefix in _GROUP_PREFIXES]


def build_entitlements(team_id: str, bundle_id: str) -> dict[str, Any]:
    """LiveContainer's entitlements with the build variables resolved.

    Deliberately narrower than LiveContainer's own build entitlements: HealthKit and
    ``com.apple.developer.kernel.increased-memory-limit`` are omitted because a free
    profile does not grant them, and asking for an entitlement the profile lacks makes
    the whole signature invalid rather than partially granted. Everything JIT-less mode
    needs - identifier, ``get-task-allow``, app groups, keychain groups - is here.
    """
    prefix = f"{team_id}."
    return {
        "application-identifier": f"{team_id}.{bundle_id}",
        "com.apple.developer.team-identifier": team_id,
        "com.apple.security.application-groups": app_group_identifiers(team_id),
        "get-task-allow": True,
        "keychain-access-groups": (
            [f"{prefix}{BUNDLE_PREFIX}.shared"]
            + [f"{prefix}{BUNDLE_PREFIX}.shared.{n}" for n in range(1, KEYCHAIN_GROUPS)]
        ),
    }


def is_livecontainer(info: dict[str, Any]) -> bool:
    """Whether an inspected IPA is LiveContainer."""
    return str(info.get("bundle_id") or "").startswith(BUNDLE_PREFIX)


# --------------------------------------------------------------------------- #
# Getting hold of the IPA
# --------------------------------------------------------------------------- #
def latest_release() -> dict[str, Any]:
    """Describe LiveContainer's newest release, without downloading it.

    Only the plain build (``LiveContainer.ipa``) is ever chosen; the build that bundles
    SideStore is deliberately not offered.
    """
    try:
        response = requests.get(RELEASES_URL, timeout=_TIMEOUTS)
        response.raise_for_status()
        release = response.json()
    except (requests.RequestException, ValueError) as exc:
        raise LiveContainerError(
            "Could not reach GitHub to check for the latest LiveContainer release. "
            "Check your connection, or download the IPA yourself and pick it."
        ) from exc

    asset = _pick_asset(release.get("assets") or [])
    if asset is None:
        raise LiveContainerError(
            f"LiveContainer {release.get('tag_name') or 'latest'} has no plain .ipa "
            f"attached. Download one from {PROJECT_URL}/releases and pick the file."
        )
    return {
        "version": release.get("tag_name"),
        "name": release.get("name"),
        "published_at": release.get("published_at"),
        "notes_url": release.get("html_url"),
        "asset_name": asset.get("name"),
        "url": asset.get("browser_download_url"),
        "bytes": asset.get("size"),
    }


def _pick_asset(assets: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Choose the plain LiveContainer build from a release's assets.

    A release carries `LiveContainer.ipa` and `LiveContainer+SideStore.ipa`; only the
    first is wanted. Any asset naming a variant we cannot provision - the SideStore build,
    and the TrollStore builds, which expect entitlements a free profile will never grant -
    is skipped, so a download cannot silently pick something else.
    """
    excluded = ("sidestore", "trollstore", "jb", "jailbreak", "debug")
    usable = [
        a for a in assets
        if str(a.get("name", "")).lower().endswith(".ipa")
        and not any(word in str(a.get("name", "")).lower() for word in excluded)
    ]
    # Shortest name wins: "LiveContainer.ipa" over "LiveContainer.Something.ipa".
    return min(usable, key=lambda a: len(str(a.get("name", "")))) if usable else None


def download(
    directory: str | None = None,
    *,
    on_progress: ProgressFn | None = None,
) -> dict[str, Any]:
    """Download the plain LiveContainer IPA and return where it landed."""
    progress: ProgressFn = on_progress or (lambda *_args: None)
    release = latest_release()

    target_dir = Path(directory).expanduser().resolve() if directory else _default_dir()
    try:
        target_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise LiveContainerError(
            f"Cannot write to {target_dir}: {exc.strerror or exc}"
        ) from exc
    destination = target_dir / str(release["asset_name"])

    progress("download", 0, f"Downloading LiveContainer {release['version']}\u2026")
    written = _stream(str(release["url"]), destination, release.get("bytes") or 0, progress)

    expected = release.get("bytes") or 0
    if expected and written != expected:
        destination.unlink(missing_ok=True)
        raise LiveContainerError(
            f"The LiveContainer download ended early ({written} of {expected} bytes) "
            "and was discarded. Check your connection and try again."
        )

    # An .ipa that is not LiveContainer would sign happily and then make no sense, so
    # confirm what was downloaded before handing the path back.
    info = ipa_module.inspect(str(destination))
    if not is_livecontainer(info):
        destination.unlink(missing_ok=True)
        raise LiveContainerError(
            f"{release['asset_name']} is {info.get('bundle_id')}, not LiveContainer. "
            "The release layout may have changed; download it yourself and pick it."
        )

    return {**release, "path": str(destination), "bytes_written": written}


def _default_dir() -> Path:
    from . import paths

    return paths.downloads_dir()


def _stream(url: str, destination: Path, total: int, progress: ProgressFn) -> int:
    try:
        response = requests.get(url, stream=True, timeout=_TIMEOUTS, allow_redirects=True)
    except requests.RequestException as exc:
        raise LiveContainerError(
            "Could not download LiveContainer. Check your internet connection."
        ) from exc

    with response:
        if response.status_code != 200:
            raise LiveContainerError(
                f"GitHub did not serve the LiveContainer IPA (HTTP {response.status_code})."
            )
        written = 0
        try:
            with destination.open("wb") as handle:
                for chunk in response.iter_content(chunk_size=_CHUNK_BYTES):
                    if not chunk:
                        continue
                    handle.write(chunk)
                    written += len(chunk)
                    percent = round(written * 100 / total) if total else None
                    progress("download", percent, _downloaded_step(written, total))
        except (requests.RequestException, OSError) as exc:
            destination.unlink(missing_ok=True)
            raise LiveContainerError(
                f"The LiveContainer download failed after {written} bytes "
                "and was discarded."
            ) from exc
    return written


def _downloaded_step(written: int, total: int) -> str:
    mb = 1 << 20
    if total:
        return f"Downloading LiveContainer \u00b7 {written // mb} / {total // mb} MB"
    return f"Downloading LiveContainer \u00b7 {written // mb} MB"


# --------------------------------------------------------------------------- #
# Handing over the certificate
# --------------------------------------------------------------------------- #
def _import_request(bundle: dict[str, Any]) -> bytes:
    """The plist tools/lc-cert-import/ reads on first launch."""
    return plistlib.dumps(
        {
            "AppGroupID": app_group_identifiers(bundle["team_id"])[0],
            "CertificateData": Path(bundle["p12_path"]).read_bytes(),
            "CertificatePassword": bundle["p12_password"],
        },
        fmt=plistlib.FMT_BINARY,
    )


async def _write_documents(
    bundle_id: str,
    serial: str | None,
    files: dict[str, bytes],
) -> list[str]:
    """Write files into an installed app's /Documents over house_arrest.

    /Documents is created first: on a fresh install a guest app's container does not
    exist until that app has been opened once, and writing early is what stops it
    having to ask for the file at all.
    """
    from pymobiledevice3.services.house_arrest import HouseArrestService

    written: list[str] = []
    client = await lockdown.create(serial)
    try:
        async with await HouseArrestService.create(client, bundle_id) as service:
            await service.makedirs("/Documents")
            for name, payload in files.items():
                target = f"/Documents/{name}"
                await service.set_file_contents(target, payload)
                written.append(target)
    finally:
        await lockdown.close(client)
    return written


async def _list_dir(bundle_id: str, serial: str | None, path: str) -> list[str]:
    """One directory listing from inside an app's container."""
    from pymobiledevice3.services.house_arrest import HouseArrestService

    client = await lockdown.create(serial)
    try:
        async with await HouseArrestService.create(client, bundle_id) as service:
            return list(await service.listdir(path))
    finally:
        await lockdown.close(client)


async def _remove_tree(bundle_id: str, serial: str | None, path: str) -> None:
    """Remove a directory and everything under it, depth first.

    AFC has no recursive delete, and refuses to remove a directory that still has
    contents, so the walk has to happen here.
    """
    from pymobiledevice3.services.house_arrest import HouseArrestService

    client = await lockdown.create(serial)
    try:
        async with await HouseArrestService.create(client, bundle_id) as service:
            await _remove_recursive(service, path)
    finally:
        await lockdown.close(client)


async def _remove_recursive(service: Any, path: str) -> None:
    try:
        entries = await service.listdir(path)
    except Exception:  # noqa: BLE001 - a file, or already gone
        await service.rm_single(path)
        return

    for entry in entries:
        if entry in (".", ".."):
            continue
        await _remove_recursive(service, f"{path}/{entry}")
    await service.rm_single(path)


async def _push_bundle(
    bundle_id: str,
    serial: str | None,
    target: str,
    files: dict[str, bytes],
    total: int,
    progress: ProgressFn,
) -> None:
    """Copy an unzipped app bundle into LiveContainer, reporting bytes as they land."""
    from pymobiledevice3.services.house_arrest import HouseArrestService

    client = await lockdown.create(serial)
    try:
        async with await HouseArrestService.create(client, bundle_id) as service:
            # Replacing rather than merging: files left over from an older version of the
            # same app would otherwise stay behind and be signed along with the new one.
            try:
                await service.listdir(target)
            except Exception:  # noqa: BLE001 - not there yet, which is the normal case
                pass
            else:
                await _remove_recursive(service, target)

            # Every directory once, up front. AFC creates no parents on write, and doing
            # it per file turns one round trip into thousands.
            await service.makedirs(target)
            directories = sorted(
                {str(PurePosixPath(rel).parent) for rel in files} - {".", ""}
            )
            for directory in directories:
                await service.makedirs(f"{target}/{directory}")

            written = 0
            reported = -1
            count = len(files)
            for index, (rel, payload) in enumerate(sorted(files.items()), 1):
                await service.set_file_contents(f"{target}/{rel}", payload)
                written += len(payload)
                percent = round(written * 100 / total) if total else 0

                # Only when the number moves. An app bundle is hundreds of files, and a
                # frame per file floods the progress stream to say the same thing.
                if percent == reported and index != count:
                    continue
                reported = percent
                progress(
                    "upload",
                    percent,
                    # File counts as well as megabytes, because a bundle's size is
                    # usually concentrated in one or two files: the byte percentage can
                    # sit still through hundreds of small ones and look stalled.
                    f"Copying into LiveContainer \u00b7 {index} / {count} files \u00b7 "
                    f"{written // (1 << 20)} / {total // (1 << 20)} MB",
                )
    finally:
        await lockdown.close(client)


def seed_certificate(
    bundle: dict[str, Any], serial: str | None = None, *, automatic: bool | None = None
) -> dict[str, Any]:
    """Put the signing certificate where LiveContainer can pick it up.

    Always writes the bare ``.p12``, which is what LiveContainer's own
    Settings -> Import Certificate reads. It is rewritten on every install and refresh
    and the dylib leaves it alone, so the manual route stays available on the device even
    if the stored certificate is later removed or rejected.

    ``automatic`` also writes the request the injected dylib consumes. Left as None it
    follows whether this build actually ships that dylib - claiming the certificate will
    import itself when nothing is there to do it would be worse than saying nothing.
    """
    if automatic is None:
        automatic = signing.resolve_helper_dylib() is not None

    files = {CERTIFICATE_NAME: Path(bundle["p12_path"]).read_bytes()}
    if automatic:
        files[REQUEST_NAME] = _import_request(bundle)

    try:
        asyncio.run(_write_documents(bundle["bundle_id"], serial, files))
    except Exception as exc:  # noqa: BLE001 - any transport failure means the same thing
        # Not fatal: LiveContainer is installed and usable, it just cannot sign guest
        # apps until a certificate reaches it. Say exactly that instead of failing the
        # whole setup after the app is already on the phone.
        return {
            "seeded": False,
            "automatic": False,
            "error": str(exc),
            "instructions": _manual_instructions(bundle),
        }

    return {
        "seeded": True,
        "automatic": automatic,
        "password": bundle["p12_password"],
        "instructions": None if automatic else _manual_instructions(bundle),
    }


def _manual_instructions(bundle: dict[str, Any]) -> str:
    return (
        "In LiveContainer, open Settings \u2192 Import Certificate, choose "
        f"On My iPhone \u2192 LiveContainer \u2192 {CERTIFICATE_NAME}, and enter the "
        f"password {bundle['p12_password']}."
    )


# --------------------------------------------------------------------------- #
# Apps that run inside LiveContainer
# --------------------------------------------------------------------------- #
def guest_apps(bundle_id: str, serial: str | None = None) -> list[dict[str, Any]]:
    """The apps installed inside LiveContainer, which cost no app slot of their own."""
    try:
        names = asyncio.run(_list_dir(bundle_id, serial, GUEST_APPS_DIR))
    except Exception:  # noqa: BLE001 - a locked or busy device is not a failure here
        return []
    return [
        {"folder": name, "bundle_id": name[: -len(".app")]}
        for name in sorted(names)
        if name.endswith(".app")
    ]


def install_guest(
    ipa_path: str,
    bundle_id: str,
    serial: str | None = None,
    *,
    on_progress: ProgressFn | None = None,
) -> dict[str, Any]:
    """Put an app inside LiveContainer, without installing it on the phone.

    This is the whole point of LiveContainer: the phone counts one installed app however
    many are loaded into it, so an app placed here does not use one of the three slots a
    free Apple ID allows.

    All it takes is the unzipped bundle in the right place. LiveContainer's own importer
    does no more than move it there and then patch and sign it, and the patch is triggered
    by the absence of its revision marker - so an app written here is picked up, patched
    and signed by LiveContainer itself. Nothing about its private format is reproduced,
    and it is not signed here: LiveContainer signs guest apps on device with the
    certificate iPASide gave it.
    """
    progress: ProgressFn = on_progress or (lambda *_args: None)

    info = ipa_module.inspect(ipa_path)
    guest_id = info.get("bundle_id")
    if not guest_id:
        raise LiveContainerError(
            f"{Path(ipa_path).name} has no bundle identifier, so LiveContainer would have "
            "nowhere to put it."
        )
    if info.get("has_sc_info"):
        raise LiveContainerError(
            f"{Path(ipa_path).name} is App Store-encrypted (FairPlay). LiveContainer "
            "cannot run it any more than a sideload could; use a decrypted IPA."
        )

    progress("read", None, f"Reading {Path(ipa_path).name}\u2026")
    files = _bundle_files(ipa_path)
    total = sum(len(data) for data in files.values())

    target = f"{GUEST_APPS_DIR}/{guest_id}.app"
    progress("upload", 0, f"Copying into LiveContainer\u2026")
    asyncio.run(_push_bundle(bundle_id, serial, target, files, total, progress))

    return {
        "status": "installed",
        "bundle_id": guest_id,
        "name": info.get("display_name") or guest_id,
        "version": info.get("version"),
        "icon": info.get("icon"),
        "files": len(files),
        "bytes": total,
        "host": bundle_id,
    }


def remove_guest(guest_id: str, bundle_id: str, serial: str | None = None) -> None:
    """Delete an app from inside LiveContainer."""
    asyncio.run(_remove_tree(bundle_id, serial, f"{GUEST_APPS_DIR}/{guest_id}.app"))


def _bundle_files(ipa_path: str) -> dict[str, bytes]:
    """The contents of an IPA's ``.app``, keyed by path relative to the bundle."""
    with zipfile.ZipFile(ipa_path) as archive:
        names = archive.namelist()
        app_dir = next(
            (
                name.split("/")[1]
                for name in names
                if name.startswith("Payload/") and name.split("/")[1].endswith(".app")
            ),
            None,
        )
        if app_dir is None:
            raise LiveContainerError(
                f"{Path(ipa_path).name} has no Payload/<App>.app inside, so it is not "
                "an app bundle LiveContainer can run."
            )
        prefix = f"Payload/{app_dir}/"
        return {
            name[len(prefix):]: archive.read(name)
            for name in names
            if name.startswith(prefix) and not name.endswith("/")
        }


# --------------------------------------------------------------------------- #
# The whole flow
# --------------------------------------------------------------------------- #
def setup(
    ipa_path: str,
    udid: str | None = None,
    *,
    keep_signed: bool = False,
    signed_dir: str | None = None,
    automatic_certificate: bool = True,
    on_progress: ProgressFn | None = None,
) -> dict[str, Any]:
    """Sign and install LiveContainer, then give it the certificate.

    Runs through the ordinary sideload path with LiveContainer's signing profile, so it
    is recorded for auto-refresh like any other app and re-signed with the same
    entitlements when its profile expires.
    """
    from . import sideload  # imported here: sideload resolves our signing profile

    progress: ProgressFn = on_progress or (lambda *_args: None)

    info = ipa_module.inspect(ipa_path)
    if not is_livecontainer(info):
        raise LiveContainerError(
            f"{Path(ipa_path).name} is {info.get('bundle_id') or 'not an app'}, not "
            f"LiveContainer. Download it from {PROJECT_URL}/releases."
        )

    # The signing profile injects this and delivers the certificate afterwards; we only
    # read it here to report which route the user is on.
    helper = signing.resolve_helper_dylib()

    result = sideload.run_sideload(
        ipa_path,
        udid,
        # Its extensions are kept, unlike an ordinary sideload: LiveProcess.appex is how
        # LiveContainer runs a guest app alongside another, and stripping it removes that
        # without any visible sign that something was taken away.
        remove_extensions=False,
        remove_uisd=False,
        keep_signed=keep_signed,
        signed_dir=signed_dir,
        profile=SIGNING_PROFILE,
        on_progress=progress,
    )

    # The certificate is delivered by the profile's post-install step, so that a refresh
    # does it too rather than only a first install. Asking for a manual import re-does the
    # certificate with the request left out, which is cheap - a few KB over USB.
    outcome = result.get("post_install") or {}
    certificate = outcome.get("certificate", outcome)
    if not automatic_certificate and certificate.get("seeded"):
        certificate = seed_certificate(
            provision.load_bundle(), result.get("udid"), automatic=False
        )

    return {
        **result,
        "livecontainer_version": info.get("version"),
        "certificate": certificate,
        "helper_dylib": helper,
        "launch_required": bool(certificate.get("automatic")),
    }


def status(serial: str | None = None) -> dict[str, Any]:
    """Report whether LiveContainer is installed and whether it holds a certificate.

    The certificate itself lives in the app group, which cannot be read from here, so the
    honest answer is drawn from what *is* visible in Documents. A pending request means
    the dylib has not run yet; its absence means the certificate was stored. The ``.p12``
    is expected to be there either way - it is left behind on purpose so a manual import
    is always possible - so it says nothing about whether setup finished.
    """
    installed = apps.list_installed(serial)
    entry = next(
        (
            {"bundle_id": key, **value}
            for key, value in installed.items()
            if key.startswith(BUNDLE_PREFIX)
        ),
        None,
    )
    if entry is None:
        return {"installed": False}

    documents: list[str] = []
    try:
        documents = asyncio.run(_list_documents(entry["bundle_id"], serial))
    except Exception:  # noqa: BLE001 - a locked or busy device is not a failure here
        documents = []

    return {
        "installed": True,
        "bundle_id": entry["bundle_id"],
        "name": entry.get("name"),
        "version": entry.get("version"),
        "certificate_pending": REQUEST_NAME in documents,
        "certificate_file_present": CERTIFICATE_NAME in documents,
        # LiveContainer creates these on first launch, so their absence means it has
        # been installed but never opened.
        "launched": "Applications" in documents,
    }


async def _list_documents(bundle_id: str, serial: str | None) -> list[str]:
    from pymobiledevice3.services.house_arrest import HouseArrestService

    client = await lockdown.create(serial)
    try:
        async with await HouseArrestService.create(client, bundle_id) as service:
            return list(await service.listdir("/Documents"))
    finally:
        await lockdown.close(client)
