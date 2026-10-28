"""Device enumeration, identity, and target selection.

Lists iOS devices visible to usbmuxd (USB and network), decides *which* of them a
command with no explicit UDID means, and reads a curated, stable subset of lockdown
values for a chosen device.
"""

from __future__ import annotations

import asyncio
import json
import sys
import threading
import time
from collections.abc import Awaitable, Callable
from typing import Any

from . import lockdown, paths, wifi_direct
from ._asyncutil import maybe_await, run
from .errors import EngineError


#: How often, in seconds, the Listen watcher looks again for remembered phones that
#: usbmux does not list, so one that comes into or leaves Wi-Fi range shows.
DIRECT_RECHECK = 60.0
#: How long, in seconds, the watcher keeps showing a remembered phone after the LAN
#: last answered for it: an idle iPhone goes quiet for about a minute at a time, and
#: a row that comes and goes would move the app's selection to another phone.
GRACE = 180.0


class DeviceError(EngineError):
    """No device to act on, or no way to tell which one was meant."""


def mux_device_to_entry(dev: Any) -> dict[str, Any]:
    """One ``devices`` row from a pymobiledevice3 ``MuxDevice`` (or test double)."""
    return {
        "serial": getattr(dev, "serial", None),
        "connection_type": getattr(dev, "connection_type", None),
        "device_id": getattr(dev, "devid", getattr(dev, "device_id", None)),
    }


def listing_signature(entries: list[dict[str, Any]]) -> tuple[tuple[Any, ...], ...]:
    """Identity of a usbmux listing: serial, transport, and mux handle per row."""
    return tuple(
        (entry.get("serial"), entry.get("connection_type"), entry.get("device_id"))
        for entry in entries
    )


async def _list_devices_async() -> list[dict[str, Any]]:
    from pymobiledevice3 import usbmux

    devices = await maybe_await(usbmux.list_devices())
    entries = [mux_device_to_entry(dev) for dev in devices]
    return entries + await _direct_rows({entry["serial"] for entry in entries})


async def _direct_rows(listed: set[Any]) -> list[dict[str, Any]]:
    """``Network`` rows for remembered phones usbmux misses but the LAN answers for.

    Each phone is looked for in a thread of its own (``wifi_direct.locate``: its last
    address, and a sweep at most every few minutes), so neither the event loop nor the
    other phones wait on it. A phone usbmux lists in any way gets no second row.
    """
    missing = [u for u in await asyncio.to_thread(wifi_direct.remembered) if u not in listed]
    found = await asyncio.gather(
        *(asyncio.to_thread(wifi_direct.locate, udid) for udid in missing)
    )
    return [
        {"serial": udid, "connection_type": "Network", "device_id": None}
        for udid, ip in zip(missing, found)
        if ip is not None
    ]


def _merged(usb: list[dict[str, Any]], direct: list[dict[str, Any]]) -> list[dict[str, Any]]:
    listed = {entry.get("serial") for entry in usb}
    return usb + [row for row in direct if row["serial"] not in listed]


def list_devices() -> list[dict[str, Any]]:
    """List every iOS device visible to usbmuxd (USB and network), plus remembered
    phones that answer on the LAN although usbmux does not list them."""
    return run(_list_devices_async())


def _targetable_udids(entries: list[dict[str, Any]]) -> list[str]:
    """The distinct devices in a usbmux listing, in the order first seen.

    usbmux reports one entry *per transport*, so a phone that is plugged in and also
    reachable over Wi-Fi is listed twice under the same serial. That is one device
    with two ways in, not two devices. Entries with no serial are dropped: whatever
    they are, they cannot be named as a target. (``doctor`` groups the same way for
    display, but keeps placeholders for unusable entries so it can still show them.)
    """
    udids: list[str] = []
    for entry in entries:
        serial = entry.get("serial")
        if serial and str(serial) not in udids:
            udids.append(str(serial))
    return udids


def _choose_udid(entries: list[dict[str, Any]]) -> str:
    """The one device in ``entries``, or a ``DeviceError`` explaining the problem.

    Deliberately refuses to pick when there is a real choice to make. Taking the
    first entry means the phone iPASide acts on is decided by usbmux's ordering,
    which nothing tells the user about - so an install can land on the wrong phone.
    """
    udids = _targetable_udids(entries)
    if not udids:
        raise DeviceError("No device connected; connect an iPhone (or pass --udid).")
    if len(udids) > 1:
        raise DeviceError(
            f"More than one device is connected ({', '.join(udids)}). "
            "Pass --udid to choose one, or disconnect the others."
        )
    return udids[0]


def resolve_serial(serial: str | None = None) -> str:
    """The UDID to act on: the one given, or the single connected device.

    An explicit serial is taken at face value - the caller has already chosen, and
    re-checking it would only add a usbmux round trip and a new way to fail.
    """
    if serial:
        return serial
    return _choose_udid(list_devices())


async def resolve_serial_async(serial: str | None = None) -> str:
    """``resolve_serial`` for callers already inside the event loop."""
    if serial:
        return serial
    return _choose_udid(await _list_devices_async())


# Fields surfaced for a connected device. Kept small and stable so the UI can
# rely on them; the raw lockdown value bag has hundreds of keys.
_INFO_KEYS = (
    "DeviceName",
    "ProductType",
    "ProductVersion",
    "BuildVersion",
    "UniqueDeviceID",
    "SerialNumber",
    "CPUArchitecture",
    "DeviceClass",
    "HardwareModel",
    "ProductName",
)


async def _get_device_info_async(serial: str | None, prefer_usb: bool) -> dict[str, Any]:
    client = await lockdown.create(serial, prefer_usb=prefer_usb)
    try:
        values = await lockdown.all_values(client)
        return {key: values[key] for key in _INFO_KEYS if key in values}
    finally:
        await lockdown.close(client)


def get_device_info(serial: str | None = None, prefer_usb: bool = True) -> dict[str, Any]:
    """Return a curated lockdown value bag for one device (USB preferred)."""
    return run(_get_device_info_async(serial, prefer_usb))


async def _wait_until_stopped(stop: threading.Event) -> None:
    # In short waits, not one open-ended ``stop.wait``: a thread-pool worker cannot be
    # cancelled, so an unbounded wait would keep ``asyncio.run`` from closing its loop
    # whenever the watcher ends without ``stop`` being set (a cancelled task, a test).
    while not stop.is_set():
        await asyncio.to_thread(stop.wait, 0.5)


def _announce(message: str) -> None:
    """One progress-style line on the process's own stderr.

    Written to ``sys.__stderr__`` rather than ``sys.stderr``: while ``serve`` runs a
    request it swaps ``sys.stderr`` for a writer that turns every line into that
    request's progress frame, and a Wi-Fi sync note from the Listen thread has nothing
    to do with whatever the user happens to be installing at that moment.
    """
    event = {"event": "progress", "phase": "wifi-sync", "percent": None, "step": message}
    print(json.dumps(event), file=sys.__stderr__ or sys.stderr, flush=True)


async def _enable_wifi_sync(serial: str) -> None:
    """Turn on "Show this iPhone when on Wi-Fi" for a phone that is on the cable.

    That is the lockdown switch (``EnableWifiConnections``) iTunes flips; while it is
    off the phone stops advertising itself over the network, so it vanishes from the
    list the moment it is unplugged. It is only ever written when it is not already
    on, and only over USB - a Wi-Fi connection is no place to change Wi-Fi settings.

    It never starts pairing: that stays with the app's own device-info request, and two
    pairing loops on one phone could leave a pair record that no longer matches it. A
    phone this PC is not paired with yet is skipped without a word.

    Never raises: a locked or untrusted phone or a lockdown error just means no Wi-Fi
    sync this time, and that must not take the watcher down with it.
    """
    from pymobiledevice3.exceptions import MissingValueError, NotPairedError
    from pymobiledevice3.lockdown import create_using_usbmux

    label = serial[:8]
    client = None
    try:
        # Same pair-record folder as ``lockdown.create``, so the phone is reached with
        # the pairing the rest of the engine uses. ``lockdown.create`` itself is not
        # used because its transport policy may fall back to Wi-Fi or follow the
        # connection setting; this must be the cable.
        records = paths.data_dir() / "lockdown"
        records.mkdir(parents=True, exist_ok=True)
        client = await maybe_await(
            create_using_usbmux(
                serial=serial,
                connection_type="USB",
                pairing_records_cache_folder=records,
                autopair=False,
            )
        )
        if not client.paired:
            return
        values = await lockdown.all_values(client)
        # Before the "already on" return: every paired attach refreshes the note that
        # lets ``wifi_direct`` find this phone on the LAN later. Isolated: a failure
        # there must not cost the phone its Wi-Fi sync.
        try:
            await asyncio.to_thread(
                wifi_direct.remember, serial, values.get("WiFiAddress"), values.get("DeviceName")
            )
        except Exception:
            pass
        try:
            if await maybe_await(client.get_enable_wifi_connections()):
                return
        except MissingValueError:
            pass  # never written on this phone: that is "off"
        label = values.get("DeviceName") or label
        await maybe_await(client.set_enable_wifi_connections(True))
        _announce(f"Turned on Wi-Fi sync for {label} so it can refresh without the cable.")
    except NotPairedError:
        return
    except Exception as exc:  # best effort: report it, never propagate
        detail = str(exc) or type(exc).__name__
        _announce(
            f"Could not turn on Wi-Fi sync for {label}: {detail}. "
            "Unlock the iPhone, tap Trust if it asks, then plug it in again."
        )
    finally:
        if client is not None:
            try:
                await lockdown.close(client)
            except Exception:
                pass


async def watch_usbmux(
    emit: Callable[[dict[str, Any]], None],
    stop: threading.Event,
    *,
    create_mux: Callable[[], Awaitable[Any]] | None = None,
    reconnect_wait: float = 1.0,
) -> None:
    """Hold a usbmux Listen socket and ``emit`` a ``devices`` event on Attached/Detached.

    This is the live inventory, not a poll: ``receive_device_state_update`` blocks
    until Apple Mobile Device Service (or usbmuxd) writes Attached, Detached, or
    Paired. Paired does not change the list, so it is not emitted.

    Each event carries the merged inventory: the usbmux rows plus a ``Network`` row
    for every remembered phone that usbmux misses but that answers on the LAN (see
    ``wifi_direct``). That lookup runs in the background - after every usbmux update
    and every ``DIRECT_RECHECK`` seconds - and never holds up the loop; a phone stays
    listed for ``GRACE`` seconds after the LAN last answered for it, and an event goes
    out only when the merged list changes.

    ``reconnect_wait`` is only paid when the Listen socket itself cannot be
    opened or dies (service not running, AMDS restart). It is not an inventory
    interval.

    Stopping can take up to about 4 s: a lookup cancelled while its ``locate`` thread
    is running lets that thread finish (``asyncio.run`` waits for it on shutdown).
    """
    from pymobiledevice3.exceptions import MuxException

    async def default_create_mux() -> Any:
        from pymobiledevice3 import usbmux

        return await usbmux.create_mux()

    factory = create_mux or default_create_mux
    last: tuple[tuple[Any, ...], ...] | None = None
    had_listen = False
    stopped = asyncio.create_task(_wait_until_stopped(stop))
    usb_rows: list[dict[str, Any]] = []
    direct_rows: list[dict[str, Any]] = []
    seen_at: dict[str, float] = {}  # UDID -> monotonic time the LAN last answered
    looking: asyncio.Task[None] | None = None
    look_again = False

    def publish(entries: list[dict[str, Any]]) -> None:
        nonlocal last, usb_rows, direct_rows
        usb_rows = entries
        # A phone on the cable is not "Wi-Fi only": forget its direct row and stamp, so
        # a later unplug is a deliberate one and is not kept (here, not in the look, so
        # a look that finishes later cannot bring the row back from a stale snapshot).
        on_usb = {e.get("serial") for e in entries if e.get("connection_type") == "USB"}
        if on_usb:
            direct_rows = [row for row in direct_rows if row["serial"] not in on_usb]
            for serial in on_usb:
                seen_at.pop(serial, None)
        merged = _merged(entries, direct_rows)
        signature = listing_signature(merged)
        if signature == last:
            return
        last = signature
        emit({"type": "event", "name": "devices", "data": merged})

    async def look_for_direct() -> None:
        """Look until no further look was asked for while this one ran."""
        nonlocal direct_rows, look_again
        while True:
            look_again = False
            try:
                found = await _direct_rows({entry.get("serial") for entry in usb_rows})
            except Exception:
                found = None  # keep what was shown; the next look tries again
            if found is not None:
                now = time.monotonic()
                for row in found:
                    seen_at[row["serial"]] = now
                answered = {row["serial"] for row in found}
                direct_rows = found + [
                    row
                    for row in direct_rows
                    if row["serial"] not in answered
                    and now - seen_at.get(row["serial"], now - GRACE) < GRACE
                ]
            # Before usbmux's first update an empty list would read as "everything
            # detached" (see the first Listen below), so only real rows go out early.
            if last is not None or direct_rows:
                publish(usb_rows)
            if not look_again:
                return

    def look() -> None:
        """Start a background lookup, or queue one if a lookup is already running."""
        nonlocal looking, look_again
        if looking is not None and not looking.done():
            look_again = True
            return
        looking = asyncio.create_task(look_for_direct())

    async def keep_vanished_network_rows(entries: list[dict[str, Any]]) -> None:
        """Keep, for GRACE, the row of a remembered phone usbmux listed as ``Network``
        and no longer lists, so a Wi-Fi phone that drops out of usbmux does not vanish
        before the LAN lookup has had its say. A phone that was only on the cable is
        a deliberate unplug and is not kept."""
        gone = {
            e.get("serial") for e in usb_rows if e.get("connection_type") == "Network"
        } - {e.get("serial") for e in entries}
        if not gone:
            return
        known = set(await asyncio.to_thread(wifi_direct.remembered))
        now = time.monotonic()
        for serial in gone & known:
            seen_at[serial] = now
            if all(row["serial"] != serial for row in direct_rows):
                direct_rows.append(
                    {"serial": serial, "connection_type": "Network", "device_id": None}
                )

    async def recheck() -> None:
        while True:
            await asyncio.sleep(DIRECT_RECHECK)
            look()

    rechecking = asyncio.create_task(recheck())

    # Phones already tried this attach, and the cable phones seen in the current Listen
    # session. A serial stays in ``tried`` until a Detached is seen for it, so usbmux
    # re-announcing a phone after the Listen socket is re-opened does not start another
    # attempt; the next real attach after an unplug does.
    tried: set[str] = set()
    on_cable: set[str] = set()
    syncing: set[asyncio.Task[None]] = set()

    def _sync_done(task: asyncio.Task[None]) -> None:
        syncing.discard(task)
        if not task.cancelled():
            task.exception()  # retrieved so a failed announce is not logged as unhandled

    def sync_new_cable_phones(entries: list[dict[str, Any]]) -> None:
        now = {
            str(entry["serial"])
            for entry in entries
            if entry.get("connection_type") == "USB" and entry.get("serial")
        }
        tried.difference_update(on_cable - now)
        on_cable.clear()
        on_cable.update(now)
        for serial in sorted(now - tried):
            tried.add(serial)
            # A task, not an await: a locked phone or an unanswered trust dialog can
            # take a long time, and the Listen loop must keep emitting meanwhile.
            task = asyncio.create_task(_enable_wifi_sync(serial))
            syncing.add(task)
            task.add_done_callback(_sync_done)

    try:
        while not stop.is_set():
            mux: Any = None
            try:
                mux = await factory()
                await mux.listen()
                # First Listen: usbmux follows with Attached for whoever is already
                # plugged in. Emitting empty here would make the UI treat that as
                # a Detached and ignore the one-shot `devices` RPC. After a dropped
                # socket, emit the (usually empty) snapshot so a phone unplugged
                # while we were disconnected does not stay on screen.
                if had_listen:
                    entries = [mux_device_to_entry(dev) for dev in mux.devices]
                    await keep_vanished_network_rows(entries)
                    publish(entries)
                had_listen = True
                # A new session announces everyone afresh, one device per update. Accepted
                # limit: a phone unplugged and re-plugged while the socket was down is not
                # retried until its next observed Detached/Attached, because a partial
                # replay cannot prove absence.
                on_cable.clear()
                while not stop.is_set():
                    update = asyncio.create_task(mux.receive_device_state_update())
                    done, _pending = await asyncio.wait(
                        {update, stopped},
                        return_when=asyncio.FIRST_COMPLETED,
                    )
                    if stopped in done:
                        if not update.done():
                            update.cancel()
                            try:
                                await update
                            except asyncio.CancelledError:
                                pass
                        return
                    await update
                    entries = [mux_device_to_entry(dev) for dev in mux.devices]
                    await keep_vanished_network_rows(entries)
                    publish(entries)
                    sync_new_cable_phones(entries)
                    look()
            except (OSError, MuxException):
                if stop.is_set():
                    return
                await asyncio.to_thread(stop.wait, reconnect_wait)
            finally:
                if mux is not None:
                    close = getattr(mux, "close", None)
                    if close is not None:
                        try:
                            await maybe_await(close())
                        except OSError:
                            pass
    finally:
        background = [rechecking, *([looking] if looking is not None else []), *syncing]
        for task in background:
            task.cancel()
        await asyncio.gather(*background, return_exceptions=True)
        if not stopped.done():
            stopped.cancel()
            try:
                await stopped
            except asyncio.CancelledError:
                pass


def run_usbmux_watch(
    emit: Callable[[dict[str, Any]], None],
    stop: threading.Event,
    **kwargs: Any,
) -> None:
    """``watch_usbmux`` for a background thread that has no event loop yet."""
    asyncio.run(watch_usbmux(emit, stop, **kwargs))
