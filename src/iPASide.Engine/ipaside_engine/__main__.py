"""Command-line entry point for the iPASide Engine.

Human-readable by default; pass ``--json`` for machine-readable output (this is
how the desktop shell consumes the engine).
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import datetime
import getpass
import io
import json
import os
import sys
import threading
from pathlib import Path
from typing import Any

from . import (
    __version__,
    account,
    anisette,
    anisette_remote,
    apple_support,
    apps,
    developer,
    developer_mode,
    device,
    doctor,
    gsa,
    ipa,
    livecontainer,
    lockdown,
    pairing,
    provision,
    refresh,
    sideload,
    signing,
    tweak,
)
from ._asyncutil import run
from .errors import EngineError

_STATUS_GLYPH = {"ok": "[ OK ]", "warn": "[WARN]", "fail": "[FAIL]"}


def _enable_fault_handler() -> None:
    """Dump every thread to stderr if a native library aborts the process.

    Anisette drives the Unicorn emulator. A segfault or a Windows fail-fast
    there is not a Python exception, so the serve loop cannot turn it into a
    result frame. The desktop app keeps stderr and shows the last lines.
    """
    import faulthandler

    try:
        faulthandler.enable(file=sys.stderr, all_threads=True)
    except (AttributeError, OSError, RuntimeError, ValueError):
        return


def _force_utf8() -> None:
    """Force UTF-8 stdout/stderr.

    Device names, app names, and Apple account data routinely contain non-ASCII
    characters (e.g. curly quotes, RTL marks). Windows consoles default to a
    legacy code page (cp1252) that raises ``UnicodeEncodeError`` on those, so we
    switch the streams to UTF-8 up front.
    """
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            try:
                reconfigure(encoding="utf-8")
            except (ValueError, OSError):
                pass


def _json_default(obj: Any) -> str:
    """Serialize plist-native types (dates, data) that JSON can't handle."""
    if isinstance(obj, (datetime.datetime, datetime.date)):
        return obj.isoformat()
    if isinstance(obj, (bytes, bytearray)):
        return base64.b64encode(bytes(obj)).decode()
    return str(obj)


def _emit(args: argparse.Namespace, payload: Any) -> None:
    """Print a JSON payload (only used on the --json path)."""
    print(json.dumps(payload, indent=2, default=_json_default))


def _print_doctor(report: dict[str, Any]) -> None:
    print("EZSide doctor")
    print("=" * 60)
    for check in report["checks"]:
        glyph = _STATUS_GLYPH.get(check["status"], "[    ]")
        print(f"{glyph}  {check['name']}")
        print(f"        {check['detail']}")
    print("=" * 60)
    overall = report["overall"]
    print(f"Overall: {_STATUS_GLYPH.get(overall, '')} {overall.upper()}")


def _cmd_doctor(args: argparse.Namespace) -> int:
    report = doctor.run_doctor()
    if args.json:
        _emit(args, report)
    else:
        _print_doctor(report)
    return 1 if report["overall"] == "fail" else 0


def _cmd_devices(args: argparse.Namespace) -> int:
    devices = device.list_devices()
    if args.json:
        _emit(args, devices)
        return 0
    if not devices:
        print("No iOS devices visible. Plug in via USB, unlock, and tap 'Trust'.")
        return 0
    for dev in devices:
        print(
            f"{dev.get('serial', '?')}  "
            f"{dev.get('connection_type', '?')}  "
            f"(id={dev.get('device_id', '?')})"
        )
    return 0


def _cmd_device_info(args: argparse.Namespace) -> int:
    info = device.get_device_info(args.udid)
    if args.json:
        _emit(args, info)
    else:
        if not info:
            print("No device info available (is a device connected and trusted?).")
        for key, value in info.items():
            print(f"{key}: {value}")
    return 0


def _cmd_apps(args: argparse.Namespace) -> int:
    installed = apps.list_installed(args.udid, app_type=args.type)
    if args.json:
        _emit(args, installed)
        return 0
    if not installed:
        print("No apps found.")
        return 0
    for bundle_id, meta in sorted(installed.items()):
        name = meta.get("name") or ""
        version = meta.get("version") or ""
        print(f"{bundle_id:<45} {name}  {version}")
    print(f"\n{len(installed)} app(s).")
    return 0


def _cmd_developer_mode(args: argparse.Namespace) -> int:
    if args.enable:
        if not args.yes:
            msg = "Refusing to enable Developer Mode without --yes (this reboots the device)."
            if args.json:
                _emit(args, {"ok": False, "reason": msg})
            else:
                print(msg)
            return 2
        result = developer_mode.enable(args.udid)
        if args.json:
            _emit(args, result)
        else:
            print(result.get("note", "Developer Mode enable triggered."))
        return 0

    state = developer_mode.status(args.udid)
    if args.json:
        _emit(args, state)
    else:
        enabled = state.get("enabled")
        label = {True: "enabled", False: "disabled", None: "unknown"}.get(enabled, "unknown")
        print(f"Developer Mode: {label}")
        if state.get("reason"):
            print(f"  {state['reason']}")
        if state.get("product_version"):
            print(f"  iOS {state['product_version']}")
    return 0


def _cmd_install(args: argparse.Namespace) -> int:
    def progress(update: dict[str, Any]) -> None:
        percent = update.get("percent")
        phase = update.get("phase")
        status = update.get("status")
        label = status or phase or ""
        # Progress goes to stderr so stdout stays a single clean JSON result
        # for programmatic callers (the desktop app); CLI users still see it.
        if args.json:
            print(json.dumps({"event": "progress", "phase": phase, "percent": percent, "status": status}),
                  file=sys.stderr, flush=True)
        else:
            print(f"  {percent if percent is not None else '?'}%  {label}",
                  file=sys.stderr, flush=True)

    apps.install(args.ipa, args.udid, progress=progress)
    if args.json:
        _emit(args, {"ok": True, "installed": args.ipa})
    else:
        print("Install complete.")
    return 0


def _cmd_app_icons(args: argparse.Namespace) -> int:
    found = apps.icons(args.bundle_id or None, args.udid, app_type=args.type)
    if args.json:
        _emit(args, found)
        return 0
    if not found:
        print("No icons available.")
        return 0
    for bundle_id in sorted(found):
        print(f"{bundle_id}  ({len(found[bundle_id])} chars)")
    return 0


def _cmd_uninstall(args: argparse.Namespace) -> int:
    # Locked, so a refresh running in the other process cannot find the app gone
    # halfway through and reinstall it.
    with refresh.operation_lock():
        apps.uninstall(args.bundle_id, args.udid)
    if args.json:
        _emit(args, {"ok": True, "uninstalled": args.bundle_id})
    else:
        print(f"Uninstalled {args.bundle_id}.")
    return 0


def _cmd_anisette(args: argparse.Namespace) -> int:
    if args.set_servers is not None:
        # Settings -> Anisette. Order is priority; an empty value restores the built-in list.
        chosen = anisette_remote.save_servers(
            [part for part in str(args.set_servers).split(",")]
        )
        if not chosen and not args.json:
            print("Anisette server list cleared; the built-in servers are used again.")
    if args.clear_servers:
        anisette_remote.clear_servers()
        if not args.json:
            print("Anisette server list cleared; the built-in servers are used again.")

    if args.refresh:
        headers = anisette.get_headers()
        if args.json:
            _emit(args, headers)
        else:
            print("Anisette headers generated:")
            for key in sorted(headers):
                value = str(headers[key])
                preview = value[:16] + ("..." if len(value) > 16 else "")
                print(f"  {key}: {preview}")
        return 0

    state = anisette.status()
    if args.json:
        _emit(args, state)
    else:
        print(f"Anisette package: {state['package_version'] or 'NOT INSTALLED'}")
        print(f"Provisioning state cached: {state['state_cached']}")
        print(f"  {state['state_path']}")
        servers = state.get("servers") or []
        if servers:
            print("Services, in order:")
            for index, server in enumerate(servers, start=1):
                print(f"  {index}. {server}")
    return 0


def _cmd_apple_support(args: argparse.Namespace) -> int:
    """Report Apple's device stack, or fetch / start what USB needs.

    Status by default, each action behind its own flag, the way ``anisette`` and
    ``signed`` are shaped. The installer is downloaded and verified but never run:
    the engine hands back a path it has proved is Apple's, and the app launches it.
    """
    if args.download:
        result = apple_support.download_itunes(args.dir, on_progress=_progress_to_stderr())
        if args.json:
            _emit(args, result)
        else:
            print("Downloaded and verified Apple's iTunes installer.")
            print(f"  file:   {result['path']} ({_mb(result['bytes'])})")
            print(f"  signer: {result['signer']}")
            print("  Run it to install Apple Mobile Device Service.")
        return 0

    if args.start_service:
        result = apple_support.start_service()
        if args.json:
            _emit(args, result)
        else:
            outcome = "started" if result["started"] else "not started"
            print(f"Apple Mobile Device Service: {outcome}")
            print(f"  {result['detail']}")
        return 0

    report = apple_support.status()
    if args.json:
        _emit(args, report)
        return 0
    print(f"Apple device support: {report['state']}")
    print(f"  {report['detail']}")
    if report["itunes_installed"]:
        version = report["itunes_version"]
        print(f"  iTunes {version} is installed" if version else "  iTunes is installed")
    return 0


def _cmd_teams(args: argparse.Namespace) -> int:
    teams = developer.list_teams()
    if args.json:
        _emit(args, teams)
        return 0
    if not teams:
        print("No development teams found for this account.")
        return 0
    for team in teams:
        print(
            f"{team.get('teamId')}  {team.get('name')}  "
            f"({team.get('type')}, status={team.get('status')})"
        )
    print(f"{len(teams)} team(s).")
    return 0


def _cmd_provision(args: argparse.Namespace) -> int:
    try:
        # Provisioning registers a UDID with Apple and burns a device slot, so it
        # must not guess which phone it means any more than a sideload does.
        udid = device.resolve_serial(args.udid)
    except device.DeviceError as exc:
        if args.json:
            _emit(args, {"status": "error", "error": str(exc)})
        else:
            print(f"error: {exc}")
        return 2

    try:
        bundle = provision.ensure_signing_assets(
            args.bundle_id,
            udid,
            app_name=args.app_name or args.bundle_id,
            device_name=args.device_name or "EZSide device",
        )
    except (gsa.GsaError, developer.DeveloperServicesError) as exc:
        if args.json:
            _emit(args, {"status": "error", "error": str(exc)})
        else:
            print(f"Provisioning failed: {exc}")
        return 1

    if args.json:
        _emit(args, bundle)
    else:
        print(f"Provisioned signing assets for {bundle['bundle_id']}")
        print(f"  team:        {bundle['team_name']} ({bundle['team_id']})")
        print(f"  device:      {bundle['udid']}")
        print(f"  App ID:      {bundle['app_id_id']}")
        print(f"  certificate: serial {bundle['certificate_serial']}")
        print(f"  identity:    {bundle['p12_path']}")
        print(f"  profile:     {bundle['profile_path']}")
    return 0


def _cmd_sign(args: argparse.Namespace) -> int:
    try:
        # Locked, so the bundle's password and the .p12 it names are read as one pair
        # even while the other process re-provisions.
        with refresh.operation_lock():
            bundle = provision.load_bundle()
            result = signing.sign_ipa(
                args.ipa,
                args.output,
                p12_path=bundle["p12_path"],
                p12_password=bundle["p12_password"],
                profile_path=bundle["profile_path"],
                bundle_id=args.bundle_id or bundle["bundle_id"],
                remove_extensions=args.remove_extensions,
                remove_uisd=args.remove_device_restrictions,
                legacy_sha1=args.legacy_sha1,
            )
    except (gsa.GsaError, signing.SigningError) as exc:
        if args.json:
            _emit(args, {"status": "error", "error": str(exc)})
        else:
            print(f"Signing failed: {exc}")
        return 1

    if args.json:
        _emit(args, {"status": "signed", "output": result["output"]})
    else:
        print(f"Signed -> {result['output']}")
    return 0


def _progress_to_stderr(bundle_id: str | None = None):
    """Return an on_progress callback that streams JSON progress events on stderr."""
    def emit(phase_name: str, percent: Any = None, step: str | None = None) -> None:
        event = {"event": "progress", "phase": phase_name, "percent": percent, "step": step}
        if bundle_id:
            event["bundle_id"] = bundle_id
        print(json.dumps(event), file=sys.stderr, flush=True)
    return emit


_SIDELOAD_ERRORS = (
    gsa.GsaError,
    developer.DeveloperServicesError,
    signing.SigningError,
    sideload.SideloadError,
    ValueError,
)


def _cmd_sideload(args: argparse.Namespace) -> int:
    """One-shot: provision -> sign -> install, streaming phases/progress on stderr."""
    try:
        result = sideload.run_sideload(
            args.ipa,
            args.udid,
            bundle_id=args.bundle_id,
            allow_other_platform=args.allow_other_platform,
            display_name=args.name,
            bundle_version=args.set_version,
            dylibs=args.dylib,
            weak_dylibs=args.weak_dylibs,
            inject_into_extensions=args.inject_extensions,
            remove_extensions=args.remove_extensions,
            remove_uisd=args.remove_device_restrictions,
            enable_file_sharing=args.enable_file_sharing,
            keep_signed=args.keep_signed,
            signed_dir=args.signed_dir,
            on_progress=_progress_to_stderr(),
        )
    except _SIDELOAD_ERRORS as exc:
        if args.json:
            _emit(args, {"status": "error", "error": str(exc)})
        else:
            print(f"Sideload failed: {exc}")
        return 1

    if args.json:
        _emit(args, result)
    else:
        print(f"Sideloaded {result['name']} ({result['bundle_id']}). "
              "Trust the developer on your device to launch it.")
    return 0


def _livecontainer_host(args: argparse.Namespace) -> str:
    """The installed LiveContainer's bundle id, or a ``LiveContainerError`` saying why not."""
    state = livecontainer.status(args.udid)
    if not state.get("installed"):
        raise livecontainer.LiveContainerError(
            "LiveContainer is not installed on this device. Run `livecontainer --setup` "
            "first; apps run inside it, so it has to be there before one can be added."
        )
    return str(state["bundle_id"])


def _cmd_livecontainer(args: argparse.Namespace) -> int:
    """Report on LiveContainer, set it up, or manage the apps running inside it."""
    if args.add or args.remove or args.apps or not (args.download or args.setup):
        # One target for every phone call below (status, then the guest call): without
        # --udid each would pick from the inventory on its own, possibly another phone.
        args.udid = device.resolve_serial(args.udid)
    if args.add:
        host = _livecontainer_host(args)
        result = livecontainer.install_guest(
            args.add, host, args.udid, on_progress=_progress_to_stderr()
        )
        if args.json:
            _emit(args, result)
            return 0
        print(f"Added {result['name']} to LiveContainer ({result['bundle_id']}).")
        print(
            "It is not installed on the phone, so it uses none of your three app slots. "
            "Open LiveContainer and it will sign it on first launch."
        )
        return 0

    if args.remove:
        host = _livecontainer_host(args)
        livecontainer.remove_guest(args.remove, host, args.udid)
        if args.json:
            _emit(args, {"status": "removed", "bundle_id": args.remove})
        else:
            print(f"Removed {args.remove} from LiveContainer.")
        return 0

    if args.apps:
        host = _livecontainer_host(args)
        guests = livecontainer.guest_apps(host, args.udid)
        if args.json:
            _emit(args, guests)
            return 0
        if not guests:
            print("No apps inside LiveContainer yet. Add one with --add <ipa>.")
            return 0
        print(f"{len(guests)} app(s) inside LiveContainer, using no app slots:")
        for guest in guests:
            print(f"  {guest['bundle_id']}")
        return 0

    if args.download and not args.setup:
        result = livecontainer.download(
            args.dir, on_progress=_progress_to_stderr()
        )
        if args.json:
            _emit(args, result)
        else:
            print(f"Downloaded {result['asset_name']} ({result['version']}) to {result['path']}")
        return 0

    if args.setup:
        ipa_path = args.ipa
        if not ipa_path:
            ipa_path = livecontainer.download(
                args.dir, on_progress=_progress_to_stderr()
            )["path"]
        result = livecontainer.setup(
            ipa_path,
            args.udid,
            keep_signed=args.keep_signed,
            signed_dir=args.signed_dir,
            automatic_certificate=not args.manual_certificate,
            on_progress=_progress_to_stderr(),
        )
        if args.json:
            _emit(args, result)
            return 0

        certificate = result["certificate"]
        print(f"Installed LiveContainer ({result['bundle_id']}).")
        if certificate.get("automatic"):
            print(
                "Open it once and it will import the signing certificate itself, "
                "then JIT-less mode is ready."
            )
        elif certificate.get("seeded"):
            print(certificate["instructions"])
        else:
            print(f"The certificate could not be delivered: {certificate.get('error')}")
            print(certificate["instructions"])
        return 0

    result = livecontainer.status(args.udid)
    if args.json:
        _emit(args, result)
        return 0

    if not result["installed"]:
        print("LiveContainer is not installed. Run with --setup to install it.")
        return 0
    print(f"LiveContainer {result.get('version') or ''} ({result['bundle_id']})")
    if result.get("certificate_pending"):
        print("  A certificate import is waiting; open LiveContainer to complete it.")
    elif not result.get("launched"):
        print("  Installed but never opened.")
    else:
        print("  Set up. Its certificate is stored in the shared app group.")
    guests = livecontainer.guest_apps(str(result["bundle_id"]), args.udid)
    print(f"  {len(guests)} app(s) inside it, using no app slots.")
    for guest in guests:
        print(f"      {guest['bundle_id']}")
    return 0


def _cmd_installs(args: argparse.Namespace) -> int:
    records = refresh.records()
    if args.json:
        _emit(args, records)
        return 0
    if not records:
        print("No sideloaded apps recorded yet.")
        return 0
    for record in records:
        days = record.get("days_left")
        if record.get("expired"):
            state = "EXPIRED"
        elif days is not None:
            state = f"{days:g} days left"
        else:
            state = "unknown"
        print(f"{record['bundle_id']:<45} {record.get('name', '')}  [{state}]")
    return 0


#: `refresh` ran, and at least one app in it failed. The JSON summary is still complete.
EXIT_PARTIAL_FAILURE = 2


def _team_serials() -> dict[str, str | None]:
    """team id -> serial of the certificate EZSide holds for it now, for every recorded team.

    Read from the local certificate cache of the account that provisions under the team
    (no Apple call); None when no signed-in account is known for it, or it has none.
    """
    serials: dict[str, str | None] = {}
    for team_id in {r.get("team_id") for r in refresh.records()} - {None, ""}:
        account = gsa.account_for_team(team_id)
        serials[team_id] = provision.cached_serial(account) if account else None
    return serials


def _stale_records(
    teams: set[str] | None, start: dict[str, str | None]
) -> list[tuple[dict[str, Any], str]]:
    """``(record, current serial)`` for each record its team's current certificate did not sign.

    A record that names another serial was signed by a certificate that is gone. One
    without a serial (an older record) is included only when the team's certificate
    changed in this run (``start`` is how it began), because then whatever signed it has
    just been revoked. ``teams`` limits the look to those teams; None means every team.
    """
    now = _team_serials()
    stale = []
    for r in refresh.records():
        team_id = r.get("team_id")
        serial = now.get(team_id) if team_id else None
        if not serial or (teams is not None and team_id not in teams):
            continue
        if r.get("cert_serial") == serial:
            continue
        if not r.get("cert_serial") and start.get(team_id) == serial:
            continue
        stale.append((r, serial))
    return stale


def _phone_error(udid: str | None, probes: dict[str, Exception | None]) -> Exception | None:
    """Why the phone a record names cannot be reached now, or None when it answered.

    Asked before an app's Apple calls, so a phone that is asleep or off the network costs
    nothing but one connection attempt. ``probes`` keeps the answer for the whole run:
    every due app on one phone shares one probe, and a record with no UDID is not probed.
    """
    if not udid:
        return None
    if udid not in probes:
        try:
            run(lockdown.probe(udid))
            probes[udid] = None
        except Exception as exc:  # reported per app, like any other refresh failure
            probes[udid] = exc
    return probes[udid]


def _refresh_busy(args: argparse.Namespace, busy: Exception) -> int:
    """The unattended run's answer when another EZSide operation holds the lock.

    Not a failure: the hourly run simply tries again next hour, so it gives up at once
    with nothing refreshed and the usual busy sentence as a message.
    """
    if args.json:
        _emit(args, {"status": "done", "count": 0, "refreshed": [], "message": str(busy)})
    else:
        print(busy)
    return 0


def _cmd_refresh(args: argparse.Namespace) -> int:
    with contextlib.ExitStack() as stack:
        try:
            # An unattended run never waits for the lock; any other waits as before.
            stack.enter_context(refresh.operation_lock(wait=not args.unattended))
        except refresh.OperationBusy as busy:
            if not args.unattended:
                raise
            return _refresh_busy(args, busy)
        if args.bundle_id:
            targets = [r for r in refresh.records() if r["bundle_id"] == args.bundle_id]
            if not targets:
                msg = f"'{args.bundle_id}' is not a recorded sideload."
                _emit(args, {"status": "error", "error": msg}) if args.json else print(msg)
                return 1
        elif args.all:
            targets = refresh.records()
        else:
            targets = refresh.due(args.within)

        # A new certificate revokes the old one, and with it every app it signed, due or
        # not. So after each round the run looks again, from the local certificate cache,
        # for records the team's current certificate did not sign - including ones this
        # run already refreshed on an older one, and including when the refresh that
        # issued the new certificate then failed - and re-signs them too. A run for one
        # app looks only at its own team; any other run at every team.
        teams = {t.get("team_id") for t in targets} if args.bundle_id else None
        start = _team_serials()
        by_app: dict[str, dict[str, Any]] = {}  # one entry per app, latest outcome
        attempted: set[tuple[str, str | None]] = set()  # (bundle id, serial it was for)
        failed: set[str] = set()
        probes: dict[str, Exception | None] = {}  # udid -> why it is unreachable, or None
        batch: list[tuple[dict[str, Any], str | None]] = [(t, None) for t in targets]
        while True:
            for entry, serial in batch:
                attempted.add((entry["bundle_id"], serial))
                gone = _phone_error(entry.get("udid"), probes)
                if gone is not None:
                    # No Apple call for an app whose phone cannot be reached. An unattended
                    # run is retried every hour, so it stays quiet while the app still has
                    # a day or more left and only reports one that is close to expiry; an
                    # unknown expiry is treated as close. An app whose certificate is
                    # gone (stale) does not launch, whatever its profile says, so it is
                    # never waited for.
                    days = entry.get("days_left")
                    waiting = (args.unattended and isinstance(gone, device.DeviceError)
                               and days is not None and days >= 1.0
                               and serial is None
                               and entry["bundle_id"] not in
                               {r["bundle_id"] for r, _ in _stale_records(None, start)})
                    failed.add(entry["bundle_id"])
                    by_app[entry["bundle_id"]] = {
                        "bundle_id": entry["bundle_id"],
                        "status": "deferred" if waiting else "error",
                        "refresh_mode": None, "error": str(gone),
                    }
                    continue
                try:
                    res = sideload.refresh_record(
                        entry,
                        on_progress=_progress_to_stderr(entry["bundle_id"]),
                        keep_signed=args.keep_signed,
                        signed_dir=args.signed_dir,
                        # A stale app is re-signed: its certificate is gone.
                        resign=args.resign or serial is not None,
                    )
                    outcome = {"status": "installed", "expires_at": res.get("expires_at"),
                               "refresh_mode": res.get("refresh_mode"), "error": None}
                except Exception as exc:  # keep going; report per-app outcome
                    failed.add(entry["bundle_id"])
                    outcome = {"status": "error", "refresh_mode": None, "error": str(exc)}
                by_app[entry["bundle_id"]] = {"bundle_id": entry["bundle_id"], **outcome}
            # A failed app is not retried in the same run; a new (app, serial) pair at
            # most once, so the loop ends.
            batch = [
                (r, s) for r, s in _stale_records(teams, start)
                if r["bundle_id"] not in failed and (r["bundle_id"], s) not in attempted
            ]
            if not batch:
                break

    results = list(by_app.values())
    summary = {"status": "done", "count": len(results), "refreshed": results}
    if args.json:
        _emit(args, summary)
    else:
        if not results:
            print("Nothing to refresh.")
        for res in results:
            suffix = f" ({res['error']})" if res.get("error") else ""
            mode = f" [{res['refresh_mode']}]" if res.get("refresh_mode") else ""
            print(f"{res['bundle_id']}: {res['status']}{mode}{suffix}")
    any_failed = any(res["status"] == "error" for res in results)
    return EXIT_PARTIAL_FAILURE if any_failed else 0


def _mb(count: int) -> str:
    return f"{count / (1 << 20):.1f} MB"


def _cmd_signed(args: argparse.Namespace) -> int:
    if args.clean:
        result = sideload.clean_signed(args.dir)
        if args.json:
            _emit(args, result)
        else:
            print(f"Removed {result['removed']} signed IPA(s), freeing "
                  f"{_mb(result['bytes_freed'])}, from {result['directory']}")
        return 0

    report = sideload.signed_status(args.dir)
    if args.json:
        _emit(args, report)
        return 0
    print(f"Signed IPAs kept: {report['count']} ({_mb(report['bytes'])})")
    print(f"  {report['directory']}")
    for item in report["files"]:
        print(f"  {item['name']}  {_mb(item['bytes'])}  {item['modified']}")
    return 0


def _cmd_forget(args: argparse.Namespace) -> int:
    removed = refresh.forget(args.bundle_id)
    if args.json:
        _emit(args, {"ok": removed, "bundle_id": args.bundle_id})
    else:
        print("Removed from registry." if removed else "Not in the registry.")
    return 0


def _cmd_slots(args: argparse.Namespace) -> int:
    """What one Apple ID's developer account holds. Reporting only; see revoke-cert."""
    report = account.overview(args.email)
    if args.json:
        _emit(args, report)
        return 0

    team = report["team"]
    print(f"Apple ID {report['account']}")
    print(f"Team {team['name']} ({team['id']}) - {team['type']}")

    print()
    print(f"Certificates ({len(report['certificates'])}):")
    for cert in report["certificates"]:
        # Whose it is decides whether revoking it is housekeeping or sabotage.
        if cert["in_use_here"]:
            owner = "EZSide (this machine - signing with it now)"
        elif cert["ours"]:
            owner = "EZSide (another machine)"
        else:
            owner = cert["machine"] or "unknown"
        print(f"  {cert['serial']}  expires {cert['expires']}")
        print(f"      {cert['type']}  -  {owner}")

    print()
    # Deliberately not printed as "N/10": the ten is a ceiling on new registrations over a
    # rolling week, and this is how many exist. Shown as one fraction it reads as spare
    # capacity that may already be spent, which is exactly how somebody gets surprised.
    print(f"App IDs registered: {report['registered_app_ids']}")
    for app_id in report["app_ids"]:
        print(f"  {app_id['identifier']:<45} {app_id['name'] or ''}")
    print(
        f"  (Apple also allows about {report['weekly_app_id_limit']} *new* identifiers "
        "per 7 days, counted separately from the list above.)"
    )

    print()
    print(f"Devices ({len(report['devices'])}):")
    for device_entry in report["devices"]:
        print(f"  {device_entry['udid']}  {device_entry['name'] or ''}")
    return 0


def _cmd_delete_app_id(args: argparse.Namespace) -> int:
    result = account.delete_app_id(args.app_id, args.email)
    if args.json:
        _emit(args, result)
        return 0
    print(f"Deleted {result['identifier'] or result['deleted']}.")
    # Said every time, because the obvious reading is the wrong one: the identifier is
    # free to re-use, but Apple's ~10 per week counts registrations, not what exists.
    print(
        "That frees the identifier, but not one of this week's registrations - Apple "
        "counts those over a rolling seven days."
    )
    return 0


def _cmd_revoke_cert(args: argparse.Namespace) -> int:
    """Revoke a certificate, having said whose it was."""
    result = account.revoke_certificate(args.serial, args.email)
    if args.json:
        _emit(args, result)
        return 0
    print(f"Revoked {result['revoked']} ({result['machine'] or 'unknown machine'}).")
    if result["invalidates_local_apps"]:
        print(
            "That is the certificate EZSide signs with on this machine, so the apps it "
            "installed will stop opening. Sideload or refresh one to get a new one, and "
            "LiveContainer will be handed the replacement automatically."
        )
    elif not result["was_ours"]:
        print(
            "That certificate belonged to another tool, so anything it signed will stop "
            "opening until that tool issues itself a new one."
        )
    return 0


def _cmd_inspect(args: argparse.Namespace) -> int:
    try:
        report = ipa.inspect(args.ipa)
    except ipa.IpaError as exc:
        # ipa.inspect phrases these; --json callers want the same text in a field.
        if args.json:
            _emit(args, {"status": "error", "error": str(exc)})
        else:
            print(str(exc))
        return 1
    if args.json:
        _emit(args, report)
        return 0
    print(f"App: {report['display_name']}  ({report['bundle_id']})")
    print(f"  bundle: {report['app_bundle']}   executable: {report['executable']}")
    print(
        f"  version: {report['version']} (build {report['build']})   "
        f"min iOS: {report['minimum_os']}   built-with SDK: {report['platform_sdk']}"
    )
    print(
        f"  frameworks: {len(report['frameworks'])}   "
        f"app extensions: {len(report['extensions'])}   watch app: {report['has_watch_app']}"
    )
    print(
        f"  embedded provision: {report['has_embedded_provision']}   "
        f"FairPlay hint (SC_Info): {report['has_sc_info']}"
    )
    if report["extensions"]:
        print("  extensions (stripped for free accounts):")
        for ext in report["extensions"]:
            print(f"    - {ext}")
    return 0


def _cmd_prepare(args: argparse.Namespace) -> int:
    report = ipa.prepare(
        args.ipa,
        args.output,
        strip_extensions=args.strip_extensions,
        remove_device_restrictions=args.remove_device_restrictions,
        bundle_id=args.bundle_id,
        display_name=args.name,
        bundle_version=args.set_version,
        compresslevel=args.compress,
        keep_workdir=args.keep_dir,
    )
    if args.json:
        _emit(args, report)
        return 0
    print(f"Prepared {report['app_bundle']}")
    print(f"  removed: {', '.join(report['removed']) if report['removed'] else 'nothing'}")
    print(f"  Info.plist changes: {report['info_plist_changes'] or 'none'}")
    encrypted = report["encrypted"]
    print(f"  FairPlay encrypted: {encrypted}")
    if encrypted:
        print("  WARNING: the main binary is still encrypted; it must be decrypted")
        print("           before signing or iOS will kill it on launch.")
    print(f"  remaining frameworks: {len(report['remaining_frameworks'])}")
    if report["output"]:
        print(f"  output IPA: {report['output']}")
    if report["workdir"]:
        print(f"  workdir kept: {report['workdir']}")
    return 0


def _read_credentials(args: argparse.Namespace) -> tuple[str | None, str | None]:
    """Resolve (email, password) from a creds file, env var, or prompt.

    The password is never taken from the command line (it would leak into shell
    history and process listings).
    """
    if args.creds_file:
        data = json.loads(Path(args.creds_file).read_text(encoding="utf-8"))
        return data.get("email"), data.get("password")
    email = args.email
    password = os.environ.get("IPASIDE_APPLE_PASSWORD")
    if email and not password:
        password = getpass.getpass("Apple ID password: ")
    return email, password


def _cmd_login(args: argparse.Namespace) -> int:
    if args.logout:
        # --logout alone signs every account out; with --email, only that one, so a
        # second Apple ID can be dropped without disturbing the rest.
        result = gsa.logout(args.email if args.email else None)
        if args.json:
            _emit(args, result)
        else:
            removed = ", ".join(result.get("removed") or []) or "nothing"
            print(f"Signed out: {removed}.")
            if result.get("active"):
                print(f"Active account is now {result['active']}.")
        return 0

    if args.use:
        result = gsa.use_account(args.use)
        if args.json:
            _emit(args, result)
        else:
            print(f"Now using {result['email']}.")
        return 0

    if args.accounts:
        state = gsa.accounts()
        if args.json:
            _emit(args, state)
        elif not state["accounts"]:
            print("No Apple IDs signed in.")
        else:
            for account in state["accounts"]:
                mark = "*" if account["active"] else " "
                team = account.get("team_id") or "-"
                print(f" {mark} {account['email']:38s} team {team}")
            print(f"{len(state['accounts'])} account(s); * is the one in use.")
        return 0

    if args.status:
        state = gsa.status()
        if args.json:
            _emit(args, state)
        elif state["authenticated"]:
            others = state.get("account_count", 1) - 1
            extra = f", {others} other signed in" if others > 0 else ""
            print(f"Signed in as {state.get('email')} (adsid {state.get('adsid')}){extra}.")
        else:
            print("Not signed in.")
        return 0

    email, password = _read_credentials(args)
    if not email or not password:
        print("error: provide --creds-file, or --email plus IPASIDE_APPLE_PASSWORD.")
        return 2

    try:
        if args.code:
            result = gsa.complete_2fa(email, password, args.code)
        else:
            result = gsa.begin_login(email, password)
    except gsa.GsaError as exc:
        if args.json:
            _emit(args, {"status": "error", "error": str(exc)})
        else:
            print(f"Login failed: {exc}")
        return 1

    if args.json:
        _emit(args, result)
        return 0
    if result["status"] == "2fa_required":
        print(f"Two-factor authentication required (method: {result['method']}).")
        if result.get("notice"):
            print(result["notice"])
        elif result["method"] == "sms":
            print("A verification code was sent to your trusted phone number.")
        else:
            print("A verification code was sent to your trusted device(s).")
        print("Re-run the same command adding:  --code <the 6-digit code>")
    else:
        print(f"Authenticated. adsid: {result.get('adsid')}")
    return 0


def _cmd_version(args: argparse.Namespace) -> int:
    if args.json:
        _emit(args, {"version": __version__})
    else:
        print(f"EZSide Engine {__version__}")
    return 0


def _cmd_resolve_tweak(args: argparse.Namespace) -> int:
    """Resolve a .deb or .dylib to the injectable dylib(s) it provides."""
    try:
        dylibs = tweak.resolve(args.path)
    except Exception as exc:
        if args.json:
            _emit(args, {"status": "error", "error": str(exc)})
        else:
            print(f"error: {exc}")
        return 1
    if args.json:
        _emit(args, {"dylibs": dylibs})
    else:
        for item in dylibs:
            arches = ",".join(item["arches"]) or "?"
            print(f"{item['name']}  [{arches}]  {item['path']}")
    return 0


# --------------------------------------------------------------------------- #
# Persistent server mode
#
# `serve` keeps one warm engine process alive so the desktop app doesn't pay the
# Python-startup + import cost on every action. It speaks newline-delimited JSON
# over stdio: one request object per stdin line, and per line on stdout either a
# progress frame or a final result frame, both tagged with the request id.
#
# Unsolicited ``{"type":"event","name":"devices","data":[...]}`` frames are also
# written on this channel when usbmux reports Attached/Detached. They carry no
# request id. Stdout writes are locked because the Listen thread and a command
# can emit at the same time.
# --------------------------------------------------------------------------- #
class _StdoutChannel:
    """Thread-safe NDJSON writer for the serve stdout channel."""

    def __init__(self, stream: Any) -> None:
        self._stream = stream
        self._lock = threading.Lock()

    def write_frame(self, frame: dict[str, Any]) -> None:
        line = json.dumps(frame, default=_json_default) + "\n"
        with self._lock:
            self._stream.write(line)
            self._stream.flush()


class _ProgressWriter(io.TextIOBase):
    """A stderr stand-in that forwards each line written during a command as an
    id-tagged progress frame (commands stream progress via ``print(..., file=sys.stderr)``)."""

    def __init__(self, write_frame: Any, request_id: Any) -> None:
        self._write_frame = write_frame
        self._id = request_id
        self._pending = ""

    def write(self, text: str) -> int:
        self._pending += text
        while "\n" in self._pending:
            line, self._pending = self._pending.split("\n", 1)
            line = line.strip()
            if line:
                self._write_frame({"id": self._id, "type": "progress", "line": line})
        return len(text)

    def flush(self) -> None:  # pragma: no cover - nothing buffered downstream
        pass


def _run_request(request: dict[str, Any], write_frame: Any) -> None:
    """Run one command for the server: capture its JSON result, stream progress."""
    request_id = request.get("id")
    raw_args = list(request.get("args") or [])
    env = request.get("env") or {}

    saved_env: dict[str, str | None] = {}
    for key, value in env.items():
        if isinstance(value, str):
            saved_env[key] = os.environ.get(key)
            os.environ[key] = value

    out_buffer = io.StringIO()
    old_stdout, old_stderr = sys.stdout, sys.stderr
    ok, data, error = False, None, None
    try:
        namespace = build_parser().parse_args([*raw_args, "--json"])
        if namespace.command == "serve":
            raise ValueError("nested serve is not allowed")
        sys.stdout = out_buffer
        sys.stderr = _ProgressWriter(write_frame, request_id)
        # A partial refresh failure still produced a complete result; the app reads the
        # per-app statuses in it, so it is not a failed request. Exit 2 from any other
        # command (login without credentials, provision without a device) is a failure.
        code = dispatch(namespace) or 0
        ok = code == 0 or (namespace.command == "refresh" and code == EXIT_PARTIAL_FAILURE)
        text = out_buffer.getvalue().strip()
        if text:
            try:
                data = json.loads(text)
            except json.JSONDecodeError:
                data = None
        if not ok:
            error = (data.get("error") if isinstance(data, dict) else None) or text or "engine error"
    except SystemExit as exc:
        error = f"invalid request (argument error: {exc.code})"
    except Exception as exc:  # never let one bad command kill the server
        error = str(exc)
    finally:
        sys.stdout, sys.stderr = old_stdout, old_stderr
        for key, previous in saved_env.items():
            if previous is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = previous

    write_frame({"id": request_id, "type": "result", "ok": ok, "data": data, "error": error})


def _cmd_serve(args: argparse.Namespace) -> int:
    channel = _StdoutChannel(sys.stdout)
    reconfigure = getattr(sys.stdin, "reconfigure", None)
    if reconfigure is not None:
        try:
            reconfigure(encoding="utf-8")
        except (ValueError, OSError):
            pass
    stop = threading.Event()
    watcher = threading.Thread(
        target=device.run_usbmux_watch,
        args=(channel.write_frame, stop),
        name="usbmux-listen",
        daemon=True,
    )
    channel.write_frame({"type": "ready", "version": __version__})
    watcher.start()
    try:
        for raw_line in sys.stdin:
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                request = json.loads(raw_line)
            except json.JSONDecodeError:
                continue
            if request.get("type") == "shutdown":
                break
            _run_request(request, channel.write_frame)
    finally:
        stop.set()
    return 0


def _pairing_udid(args: argparse.Namespace) -> str:
    """The device a pairing command is about.

    ``--udid`` is enough: the lockdown record and any stored pairing file live
    on this PC, so export and import must not refuse to run because the phone is
    unplugged. Creating Remote Pairing keys still talks to the device, and fails
    later if it cannot be reached.
    """
    if args.udid:
        return args.udid.strip()
    return device.resolve_serial(None)


def _print_pairing_status(report: dict[str, Any]) -> None:
    print(f"Pairing file for {report.get('udid') or '?'}")
    source = report.get("source") or "none"
    if source == "imported":
        print(f"  Source: imported ({report.get('imported_path')})")
    elif source == "lockdown":
        print("  Source: this PC's USB pairing record")
    else:
        print("  Source: none")
    print(f"  USB lockdown keys: {'yes' if report.get('has_lockdown') else 'no'}")
    print(f"  Remote Pairing keys: {'yes' if report.get('has_rppairing') else 'no'}")
    if report.get("error"):
        print(f"  {report['error']}")
    elif report.get("note"):
        print(f"  {report['note']}")


def _cmd_pairing(args: argparse.Namespace) -> int:
    udid = _pairing_udid(args)
    if args.pairing_create:
        result = pairing.create_remote_pairing(udid, udid, force=True)
        if args.json:
            _emit(args, result)
            return 0
        if result.get("created"):
            print(f"Created Remote Pairing keys for {udid}")
        else:
            print(f"Remote Pairing keys already present for {udid}")
        if result.get("path"):
            print(f"  Stored at {result['path']}")
        if result.get("note"):
            print(f"  {result['note']}")
        return 1 if result.get("error") or not result.get("has_rppairing") else 0
    if args.pairing_export:
        result = pairing.export_to(udid, args.pairing_export)
        if args.json:
            _emit(args, result)
            return 0
        print(f"Wrote {result['bytes']} bytes to {result['path']}")
        if result.get("note"):
            print(result["note"])
        return 0
    if args.pairing_import:
        result = pairing.import_from(udid, args.pairing_import)
        if args.json:
            _emit(args, result)
            return 0
        print(f"Imported pairing file for {udid}")
        print(f"  Stored at {result['path']}")
        if result.get("note"):
            print(f"  {result['note']}")
        return 0
    report = pairing.inspect_record(udid)
    if args.json:
        _emit(args, report)
        return 0
    _print_pairing_status(report)
    return 1 if report.get("error") else 0


_HANDLERS = {
    "doctor": _cmd_doctor,
    "devices": _cmd_devices,
    "device-info": _cmd_device_info,
    "apps": _cmd_apps,
    "app-icons": _cmd_app_icons,
    "developer-mode": _cmd_developer_mode,
    "anisette": _cmd_anisette,
    "apple-support": _cmd_apple_support,
    "login": _cmd_login,
    "teams": _cmd_teams,
    "provision": _cmd_provision,
    "sign": _cmd_sign,
    "sideload": _cmd_sideload,
    "pairing": _cmd_pairing,
    "livecontainer": _cmd_livecontainer,
    "installs": _cmd_installs,
    "refresh": _cmd_refresh,
    "signed": _cmd_signed,
    "forget": _cmd_forget,
    "slots": _cmd_slots,
    "delete-app-id": _cmd_delete_app_id,
    "revoke-cert": _cmd_revoke_cert,
    "inspect": _cmd_inspect,
    "prepare": _cmd_prepare,
    "install": _cmd_install,
    "uninstall": _cmd_uninstall,
    "version": _cmd_version,
    "resolve-tweak": _cmd_resolve_tweak,
    "serve": _cmd_serve,
}


def dispatch(args: argparse.Namespace) -> int:
    # --connection is applied through the environment rather than passed down,
    # because every device command reaches the same chokepoint (lockdown.create)
    # and threading a parameter through eight call chains to reach it would be a
    # lot of plumbing for one policy. The app sets the same variable per request,
    # which serve saves and restores around each command.
    connection = getattr(args, "connection", None)
    if connection:
        os.environ[lockdown.CONNECTION_ENV] = connection
    return _HANDLERS[args.command](args)


def build_parser() -> argparse.ArgumentParser:
    # Shared parents so options are accepted before or after the subcommand.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="emit machine-readable JSON output")

    # How to reach a device, separate from which one, because the two are not always
    # asked together: `refresh` reinstalls onto the device each record remembers, so it
    # takes no --udid, but the transport is a preference about this PC and applies to it
    # all the same.
    transport = argparse.ArgumentParser(add_help=False)
    transport.add_argument(
        "--connection",
        choices=("auto", "usb", "wifi"),
        default=None,
        help="transport to use (default: auto - prefer USB, fall back to Wi-Fi)",
    )

    # Every device-targeted command shares this, sideload included. Declaring --udid
    # on a subparser instead is what let sideload miss --connection when it was added.
    target = argparse.ArgumentParser(add_help=False, parents=[transport])
    target.add_argument(
        "--udid", default=None, help="target device UDID (default: the one connected device)"
    )

    # Shared by every command that signs an IPA (sideload + refresh), so the headless
    # auto-refresh run honours the same setting the UI sideloads with.
    signed_output = argparse.ArgumentParser(add_help=False)
    signed_output.add_argument(
        "--keep-signed", action=argparse.BooleanOptionalAction, default=False,
        help="keep the signed .ipa after installing instead of deleting it",
    )
    signed_output.add_argument(
        "--signed-dir", default=None,
        help="folder for the signed .ipa + signing scratch (default: the app's signed folder)",
    )

    parser = argparse.ArgumentParser(
        prog="ipaside_engine",
        description="EZSide Engine - iOS device + Apple services core.",
        parents=[common],
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("doctor", parents=[common], help="check the environment for sideloading readiness")
    sub.add_parser("devices", parents=[common], help="list connected iOS devices")
    sub.add_parser("device-info", parents=[common, target], help="show details for one device")
    sub.add_parser("version", parents=[common], help="print the engine version")
    sub.add_parser("serve", parents=[common], help="run a persistent engine server (JSON over stdio)")

    resolve_tweak_parser = sub.add_parser(
        "resolve-tweak", parents=[common], help="list the injectable dylib(s) in a .deb or .dylib"
    )
    resolve_tweak_parser.add_argument("path", help="path to a .deb or .dylib")

    apps_parser = sub.add_parser("apps", parents=[common, target], help="list installed apps")
    apps_parser.add_argument(
        "--type", default="User", choices=["User", "System", "Any"], help="app type filter"
    )

    icons_parser = sub.add_parser(
        "app-icons", parents=[common, target], help="home-screen icons for installed apps"
    )
    icons_parser.add_argument(
        "bundle_id", nargs="*", help="bundle ids to fetch (default: every app of --type)"
    )
    icons_parser.add_argument(
        "--type", default="User", choices=["User", "System", "Any"], help="app type filter"
    )

    dev_parser = sub.add_parser(
        "developer-mode", parents=[common, target], help="show or enable iOS Developer Mode"
    )
    dev_parser.add_argument("--enable", action="store_true", help="enable Developer Mode (reboots)")
    dev_parser.add_argument("--yes", action="store_true", help="confirm the reboot required by --enable")

    ani_parser = sub.add_parser(
        "anisette", parents=[common], help="show anisette status or generate headers"
    )
    ani_parser.add_argument(
        "--refresh", action="store_true", help="generate anisette headers (provisions on first use)"
    )
    ani_parser.add_argument(
        "--set-servers",
        metavar="URLS",
        default=None,
        help="comma-separated service URLs, first one first; empty restores the built-in list",
    )
    ani_parser.add_argument(
        "--clear-servers",
        action="store_true",
        help="forget the saved service list and use the built-in servers again",
    )

    apple_parser = sub.add_parser(
        "apple-support",
        parents=[common],
        help="show Apple's device-service status, or download/start what USB needs",
    )
    apple_parser.add_argument(
        "--download",
        action="store_true",
        help="download Apple's current iTunes installer and verify it is signed by Apple",
    )
    apple_parser.add_argument(
        "--start-service",
        action="store_true",
        help="start Apple Mobile Device Service (prompts for administrator rights)",
    )
    apple_parser.add_argument(
        "--dir",
        default=None,
        help="folder for the downloaded installer (default: the app's downloads folder)",
    )

    login_parser = sub.add_parser(
        "login", parents=[common], help="sign in to an Apple ID (GrandSlam SRP + anisette)"
    )
    login_parser.add_argument("--email", default=None, help="Apple ID email")
    login_parser.add_argument(
        "--creds-file", default=None, help="JSON file with {email, password}"
    )
    login_parser.add_argument("--code", default=None, help="2FA code (second step)")
    login_parser.add_argument("--status", action="store_true", help="show the account in use")
    login_parser.add_argument(
        "--accounts", action="store_true", help="list every signed-in Apple ID"
    )
    login_parser.add_argument(
        "--use", default=None, metavar="EMAIL",
        help="switch to an already signed-in Apple ID",
    )
    login_parser.add_argument(
        "--logout", action="store_true",
        help="sign out every account, or just --email if given",
    )

    sub.add_parser("teams", parents=[common], help="list Apple developer teams for the account")

    provision_parser = sub.add_parser(
        "provision",
        parents=[common],
        help="provision cert + device + App ID + profile for a bundle id",
    )
    provision_parser.add_argument("--bundle-id", required=True, help="app bundle identifier")
    provision_parser.add_argument(
        "--udid", default=None, help="device UDID (default: the one connected device)"
    )
    provision_parser.add_argument("--app-name", default=None, help="App ID display name")
    provision_parser.add_argument("--device-name", default=None, help="device display name")

    inspect_parser = sub.add_parser(
        "inspect", parents=[common], help="analyze an IPA without extracting it"
    )
    inspect_parser.add_argument("ipa", help="path to an .ipa file")

    sign_parser = sub.add_parser(
        "sign", parents=[common], help="sign an IPA with the provisioned identity (zsign)"
    )
    sign_parser.add_argument("ipa", help="path to the input .ipa file")
    sign_parser.add_argument("--output", "-o", required=True, help="path to the signed .ipa")
    sign_parser.add_argument("--bundle-id", default=None, help="override bundle id (default: provisioned)")
    sign_parser.add_argument(
        "--legacy-sha1",
        action="store_true",
        help="also add a SHA-1 signature, which iOS 10 and earlier need (sideload does this automatically)",
    )
    sign_parser.add_argument(
        "--remove-extensions", action=argparse.BooleanOptionalAction, default=True,
        help="remove app extensions + watch app (free-account requirement)",
    )
    sign_parser.add_argument(
        "--remove-device-restrictions", action=argparse.BooleanOptionalAction, default=True,
        help="remove UISupportedDevices",
    )

    sideload_parser = sub.add_parser(
        "sideload", parents=[common, target, signed_output],
        help="provision + sign + install an IPA in one step",
    )
    sideload_parser.add_argument("ipa", help="path to the .ipa file")
    sideload_parser.add_argument("--bundle-id", default=None, help="override bundle id (default: the app's own)")
    sideload_parser.add_argument("--name", default=None, help="app display name (CFBundleDisplayName)")
    sideload_parser.add_argument("--set-version", default=None, help="override CFBundleShortVersionString")
    sideload_parser.add_argument("--dylib", action="append", default=None, help="inject a dylib/tweak (repeatable)")
    sideload_parser.add_argument("--weak-dylibs", action="store_true", help="inject dylibs as LC_LOAD_WEAK_DYLIB")
    sideload_parser.add_argument(
        "--allow-other-platform", action="store_true",
        help="attempt an .ipa built for tvOS/watchOS anyway (very unlikely to install)",
    )
    sideload_parser.add_argument("--inject-extensions", action="store_true", help="also inject dylibs into app extensions")
    sideload_parser.add_argument("--enable-file-sharing", action="store_true", help="enable Files app / iTunes file sharing")
    sideload_parser.add_argument(
        "--remove-extensions", action=argparse.BooleanOptionalAction, default=True,
        help="remove app extensions + watch app (free-account requirement)",
    )
    sideload_parser.add_argument(
        "--remove-device-restrictions", action=argparse.BooleanOptionalAction, default=True,
        help="remove UISupportedDevices",
    )

    pairing_parser = sub.add_parser(
        "pairing",
        parents=[common, target],
        help="export, import, or create this PC's pairing file",
    )
    pairing_actions = pairing_parser.add_mutually_exclusive_group()
    pairing_actions.add_argument(
        "--export",
        dest="pairing_export",
        default=None,
        metavar="PATH",
        help="write the pairing file to PATH (XML plist)",
    )
    pairing_actions.add_argument(
        "--import",
        dest="pairing_import",
        default=None,
        metavar="PATH",
        help="store a pairing plist from another tool (optional; EZSide can create one)",
    )
    pairing_actions.add_argument(
        "--create",
        dest="pairing_create",
        action="store_true",
        help="create Remote Pairing keys over USB (no other app required)",
    )

    lc_parser = sub.add_parser(
        "livecontainer", parents=[common, target, signed_output],
        help="install LiveContainer and hand it the signing certificate",
    )
    lc_parser.add_argument(
        "--setup", action="store_true",
        help="sign + install LiveContainer, then give it the certificate",
    )
    lc_parser.add_argument(
        "--download", action="store_true", help="download the latest LiveContainer IPA"
    )
    lc_parser.add_argument(
        "--ipa", default=None,
        help="LiveContainer .ipa to use (default: download the latest release)",
    )
    lc_parser.add_argument(
        "--dir", default=None,
        help="folder for the downloaded IPA (default: the app's downloads folder)",
    )
    lc_parser.add_argument(
        "--manual-certificate", action="store_true",
        help="leave the .p12 for LiveContainer's own Settings instead of importing it",
    )
    lc_parser.add_argument(
        "--apps", action="store_true",
        help="list the apps running inside LiveContainer (these use no app slots)",
    )
    lc_parser.add_argument(
        "--add", default=None, metavar="IPA",
        help="put an .ipa inside LiveContainer instead of installing it on the phone",
    )
    lc_parser.add_argument(
        "--remove", default=None, metavar="BUNDLE_ID",
        help="remove an app from inside LiveContainer",
    )

    sub.add_parser("installs", parents=[common], help="list apps EZSide has sideloaded (with expiry)")

    # transport, not target: a refresh reinstalls onto the device its record names, so
    # --udid would be meaningless, but the transport preference still has to be honoured
    # or the unattended daily run would go over the air after the user asked for USB.
    refresh_parser = sub.add_parser(
        "refresh", parents=[common, transport, signed_output],
        help="re-sign + reinstall sideloaded apps before they expire",
    )
    refresh_parser.add_argument("--bundle-id", default=None, help="refresh a single recorded app")
    refresh_parser.add_argument("--all", action="store_true", help="refresh every recorded app")
    refresh_parser.add_argument(
        "--within", type=float, default=2.0,
        help="with neither --all nor --bundle-id, refresh apps expiring within N days",
    )
    refresh_parser.add_argument(
        "--resign", action="store_true",
        help="always re-sign and reinstall, never just install a new profile",
    )
    refresh_parser.add_argument(
        "--unattended", action="store_true",
        help="the scheduled run: an app whose phone is not reachable is deferred, "
             "not failed, while it still has a day or more left",
    )

    signed_parser = sub.add_parser(
        "signed", parents=[common], help="show or clean up the signed IPAs EZSide has kept"
    )
    signed_parser.add_argument(
        "--clean", action="store_true", help="delete the signed IPAs in the folder"
    )
    signed_parser.add_argument(
        "--dir", default=None,
        help="folder to report on or clean (default: the app's signed folder)",
    )

    forget_parser = sub.add_parser(
        "forget", parents=[common], help="remove an app from the sideload registry"
    )
    forget_parser.add_argument("bundle_id", help="installed bundle id to forget")

    slots_parser = sub.add_parser(
        "slots", parents=[common],
        help="show or tidy up an Apple ID's certificates, App IDs and devices",
    )
    slots_parser.add_argument(
        "--email", default=None,
        help="which signed-in Apple ID to report on (default: the active one)",
    )

    revoke_parser = sub.add_parser(
        "revoke-cert", parents=[common],
        help="revoke a development certificate (stops the apps it signed from opening)",
    )
    revoke_parser.add_argument("serial", help="serial number, from `slots`")
    revoke_parser.add_argument(
        "--email", default=None,
        help="which signed-in Apple ID owns it (default: the active one)",
    )

    delete_app_id_parser = sub.add_parser(
        "delete-app-id", parents=[common],
        help="delete a registered app identifier (frees the name, not the weekly quota)",
    )
    delete_app_id_parser.add_argument("app_id", help="the appIdId to delete (from `slots`)")
    delete_app_id_parser.add_argument(
        "--email", default=None,
        help="which signed-in Apple ID owns it (default: the active one)",
    )

    prepare_parser = sub.add_parser(
        "prepare", parents=[common], help="strip/patch an IPA for sideloading (before signing)"
    )
    prepare_parser.add_argument("ipa", help="path to an .ipa file")
    prepare_parser.add_argument(
        "--output", "-o", default=None, help="write a prepared .ipa (omit to only report)"
    )
    prepare_parser.add_argument(
        "--strip-extensions",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="remove app extensions + watch app (required for free Apple IDs)",
    )
    prepare_parser.add_argument(
        "--remove-device-restrictions",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="remove UISupportedDevices so the app installs on this device",
    )
    prepare_parser.add_argument("--bundle-id", default=None, help="new CFBundleIdentifier")
    prepare_parser.add_argument("--name", default=None, help="new CFBundleDisplayName")
    prepare_parser.add_argument("--set-version", default=None, help="new CFBundleShortVersionString")
    prepare_parser.add_argument(
        "--compress",
        type=int,
        default=0,
        help="zip level 0=store (fast, default; zsign re-zips) .. 9=smallest",
    )
    prepare_parser.add_argument(
        "--keep-dir", action="store_true", help="keep the extracted/prepared work directory"
    )

    install_parser = sub.add_parser(
        "install", parents=[common, target], help="install a signed IPA onto the device"
    )
    install_parser.add_argument("ipa", help="path to a signed .ipa file")

    uninstall_parser = sub.add_parser(
        "uninstall", parents=[common, target], help="uninstall an app by bundle id"
    )
    uninstall_parser.add_argument("bundle_id", help="bundle identifier to remove")

    return parser


def main(argv: list[str] | None = None) -> int:
    _force_utf8()
    _enable_fault_handler()
    args = build_parser().parse_args(argv)
    try:
        return dispatch(args)
    except EngineError as exc:
        # An EngineError is a situation, not a bug: the phone is unplugged, Apple
        # said no, the IPA is encrypted. Its message is written to be read, so print
        # that and nothing else. Anything not descended from EngineError keeps its
        # traceback, because then a stack is exactly what is wanted.
        if getattr(args, "json", False):
            _emit(args, {"status": "error", "error": str(exc)})
        else:
            print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        # A downstream consumer closed the pipe early (e.g. `| head`). Exit
        # quietly instead of dumping a traceback.
        try:
            sys.stdout.close()
        except OSError:
            pass
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
