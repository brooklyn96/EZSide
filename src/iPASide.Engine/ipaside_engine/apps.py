"""Installed-app inventory and IPA installation.

Wraps pymobiledevice3's ``InstallationProxyService`` for listing, installing,
and removing apps. Installation streams progress via a callback so the UI can
show a live progress bar.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any, Callable

from . import lockdown
from ._asyncutil import maybe_await, run
from .errors import EngineError

ProgressCallback = Callable[[dict[str, Any]], None]


async def _list_installed_async(serial: str | None, app_type: str) -> dict[str, Any]:
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    client = await lockdown.create(serial)
    try:
        proxy = InstallationProxyService(lockdown=client)
        try:
            apps = await maybe_await(proxy.get_apps(application_type=app_type))
        finally:
            await maybe_await(proxy.close())
    finally:
        await lockdown.close(client)

    result: dict[str, Any] = {}
    for bundle_id, meta in (apps or {}).items():
        result[bundle_id] = {
            "name": meta.get("CFBundleDisplayName") or meta.get("CFBundleName"),
            "version": meta.get("CFBundleShortVersionString"),
            "build": meta.get("CFBundleVersion"),
        }
    return result


def list_installed(serial: str | None = None, app_type: str = "User") -> dict[str, Any]:
    """List installed apps. ``app_type`` is ``User``, ``System``, or ``Any``."""
    return run(_list_installed_async(serial, app_type))


async def _icons_async(
    serial: str | None, bundle_ids: list[str] | None, app_type: str
) -> dict[str, str]:
    import base64

    from pymobiledevice3.services.springboard import SpringBoardServicesService

    client = await lockdown.create(serial)
    try:
        if bundle_ids is None:
            from pymobiledevice3.services.installation_proxy import (
                InstallationProxyService,
            )

            proxy = InstallationProxyService(lockdown=client)
            try:
                listed = await maybe_await(proxy.get_apps(application_type=app_type))
            finally:
                await maybe_await(proxy.close())
            bundle_ids = sorted(listed or {})

        springboard = SpringBoardServicesService(lockdown=client)
        try:
            icons: dict[str, str] = {}
            for bundle_id in bundle_ids:
                try:
                    data = await springboard.get_icon_pngdata(bundle_id)
                except Exception:  # noqa: BLE001 - one unreadable icon must not lose the rest
                    continue
                if data:
                    encoded = base64.b64encode(data).decode("ascii")
                    icons[bundle_id] = f"data:image/png;base64,{encoded}"
            return icons
        finally:
            await maybe_await(springboard.close())
    finally:
        await lockdown.close(client)


def icons(
    bundle_ids: list[str] | None = None,
    serial: str | None = None,
    app_type: str = "User",
) -> dict[str, str]:
    """Home-screen icons as PNG data URIs, keyed by bundle id.

    SpringBoard serves one icon per round trip, so this is deliberately a second
    pass after the (fast) inventory rather than part of it - the list should not
    wait on ~100 sequential fetches. Apps whose icon cannot be read are simply
    absent from the result.
    """
    return run(_icons_async(serial, bundle_ids, app_type))


# 4 MiB per AFC write: frequent, low-overhead byte-level upload progress. pymobiledevice3's
# own install_from_local writes the whole IPA in a single call with no progress, so we do the
# upload ourselves to report it live (the upload is the long part of an install).
_UPLOAD_CHUNK = 1 << 22


async def _install_async(
    ipa_path: str, serial: str | None, progress: ProgressCallback | None
) -> None:
    import uuid

    from pymobiledevice3.services.afc import AfcService
    from pymobiledevice3.services.installation_proxy import (
        TEMP_REMOTE_BASEDIR,
        InstallationProxyService,
    )

    report: ProgressCallback = progress or (lambda _u: None)
    src = Path(ipa_path)
    total = src.stat().st_size

    client = await lockdown.create(serial)
    try:
        proxy = InstallationProxyService(lockdown=client)
        try:
            remote = f"{TEMP_REMOTE_BASEDIR}/{uuid.uuid4()}.ipa"
            async with AfcService(client) as afc:
                await afc.makedirs(TEMP_REMOTE_BASEDIR)
                # Phase 1 - copy the signed IPA to the device, reporting bytes transferred.
                report({"phase": "upload", "percent": 0, "sent": 0, "total": total})
                handle = await afc.fopen(remote, "w")
                try:
                    sent = 0
                    with src.open("rb") as fh:
                        while True:
                            chunk = fh.read(_UPLOAD_CHUNK)
                            if not chunk:
                                break
                            await afc.fwrite(handle, chunk)
                            sent += len(chunk)
                            report({
                                "phase": "upload",
                                "percent": int(sent * 100 / total) if total else 100,
                                "sent": sent,
                                "total": total,
                            })
                finally:
                    await afc.fclose(handle)
                # Phase 2 - installd extracts/verifies/installs, reporting each sub-step.
                try:
                    await _watch_install(proxy, remote, report)
                finally:
                    await afc.rm_single(remote, force=True)
        finally:
            await maybe_await(proxy.close())
    finally:
        await lockdown.close(client)


class InstallLimitError(EngineError):
    """The device will not take another app, said the way a person would say it."""


# installd's wording when the free-profile ceiling is reached. It appends a Python-ish
# set of the apps occupying the slots, which is genuinely useful and unreadable as-is.
_FREE_PROFILE_LIMIT = "maximum number of installed apps using a free developer profile"


def _installed_ids(description: str) -> list[str]:
    """The `TEAMID.bundle.id` entries installd names as occupying the slots."""
    return re.findall(r'"([A-Z0-9]{10}\.[^"]+)"', description or "")


def _readable_install_error(error: str, description: str | None) -> str | None:
    """A sentence for the install failures worth explaining, or None to pass through.

    Only the free-profile ceiling so far, because it is the one users meet and the one
    whose raw form is worst: a `set` literal of tuples inside an exception message. It is
    also routinely misunderstood — the count is per device across every free Apple ID, so
    the usual advice to sign in with a second account does not help, and saying so here
    saves someone an afternoon.
    """
    if not description or _FREE_PROFILE_LIMIT not in description:
        return None

    occupied = _installed_ids(description)
    lines = [
        "Your iPhone already has the most apps a free Apple ID can install at once "
        f"({len(occupied) or 3}). Delete one to make room."
    ]
    if occupied:
        lines.append("Currently using the slots:")
        for entry in occupied:
            team, _, bundle = entry.partition(".")
            lines.append(f"  - {bundle}  (team {team})")
        teams = {entry.split(".", 1)[0] for entry in occupied}
        if len(teams) > 1:
            lines.append(
                "These come from more than one Apple ID, which is the point: iOS counts "
                "every app signed by any free account, so signing in with another one "
                "does not add slots. Only a paid developer account lifts this."
            )
        else:
            lines.append(
                "iOS counts every app signed by any free account, so signing in with "
                "another Apple ID does not add slots. Only a paid developer account "
                "lifts this."
            )
    return "\n".join(lines)


async def _watch_install(proxy: Any, remote_path: str, report: ProgressCallback) -> None:
    """Send the Install command and stream installd's ``PercentComplete`` + ``Status`` sub-steps.

    pymobiledevice3's own watcher forwards only the percent and drops the ``Status`` string, so we
    drive the exchange directly to surface each phase (extracting, verifying, installing, ...).
    """
    from pymobiledevice3.exceptions import AppInstallError

    await proxy.service.send_plist(
        {"Command": "Install", "ClientOptions": {}, "PackagePath": remote_path}
    )
    while True:
        response = await proxy.service.recv_plist()
        if not response:
            break
        error = response.get("Error")
        if error:
            description = response.get("ErrorDescription")
            readable = _readable_install_error(error, description)
            if readable:
                raise InstallLimitError(readable)
            raise AppInstallError(f"{error}: {description}")
        status = response.get("Status")
        percent = response.get("PercentComplete")
        if status or percent is not None:
            report({"phase": "install", "percent": percent, "status": status})
        if status == "Complete":
            return
    raise AppInstallError("installd closed the connection before completing the install")


def install(
    ipa_path: str, serial: str | None = None, progress: ProgressCallback | None = None
) -> None:
    """Install (or upgrade) a signed IPA, staging it via AFC + installd."""
    return run(_install_async(ipa_path, serial, progress))


async def _uninstall_async(bundle_id: str, serial: str | None) -> None:
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    client = await lockdown.create(serial)
    try:
        proxy = InstallationProxyService(lockdown=client)
        try:
            await maybe_await(proxy.uninstall(bundle_id))
        finally:
            await maybe_await(proxy.close())
    finally:
        await lockdown.close(client)


def uninstall(bundle_id: str, serial: str | None = None) -> None:
    """Uninstall an app by bundle identifier."""
    return run(_uninstall_async(bundle_id, serial))


class ProfileInstallError(EngineError):
    """The device did not take a provisioning profile."""


def _profile_key(plist: dict[str, Any]) -> tuple[str | None, str | None]:
    """``(team id, application-identifier)`` of a profile's plist."""
    teams = plist.get("TeamIdentifier") or []
    entitlements = plist.get("Entitlements") or {}
    return (teams[0] if teams else None), entitlements.get("application-identifier")


async def _install_profile_async(profile: bytes, serial: str | None) -> str:
    import io

    from pymobiledevice3.services.misagent import MisagentService, ProvisioningProfile

    try:
        new = ProvisioningProfile(profile).plist
    except Exception as exc:  # noqa: BLE001 - not a profile at all
        raise ProfileInstallError(f"Not a readable provisioning profile: {exc}") from exc
    uuid = new.get("UUID")
    team, app_identifier = _profile_key(new)
    if not uuid or not team or not app_identifier:
        raise ProfileInstallError("The provisioning profile has no UUID, team or app identifier.")

    client = await lockdown.create(serial)
    try:
        misagent = MisagentService(lockdown=client)
        try:
            await misagent.install(io.BytesIO(profile))
            listed = [p.plist for p in await misagent.copy_all()]
            # Only once the new profile is listed: until then the old one is all that
            # keeps the app launching, so a refused install must leave it in place.
            if uuid not in {p.get("UUID") for p in listed}:
                raise ProfileInstallError(
                    f"The device accepted provisioning profile {uuid} but does not list it."
                )
            # AltServer's rule: remove older versions of the profile just installed -
            # same team, same app - so they do not pile up. Another team's profiles,
            # and this team's for other apps, are never touched. Best effort: the new
            # profile is already installed, so a failed removal is not a failed refresh.
            for old in listed:
                if old.get("UUID") != uuid and _profile_key(old) == (team, app_identifier):
                    try:
                        await misagent.remove(old["UUID"])
                    except Exception as exc:  # noqa: BLE001 - the device said no
                        # A plain line, not a progress event: it is a note for the log.
                        print(f"Could not remove an old provisioning profile: {exc}",
                              file=sys.stderr, flush=True)
        finally:
            await maybe_await(misagent.close())
    finally:
        await lockdown.close(client)
    return uuid


def install_profile(profile: bytes, serial: str | None = None) -> str:
    """Install a provisioning profile on the device and return its UUID.

    Installs it, checks it is listed, and only then removes older profiles for the same
    app on the same team. Raises when the device refuses it or does not list it
    afterwards; the old profiles are then still installed.
    """
    return run(_install_profile_async(profile, serial))
