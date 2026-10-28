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
from collections.abc import Awaitable, Callable
from typing import Any

from . import lockdown, paths
from ._asyncutil import maybe_await, run
from .errors import EngineError


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
    return [mux_device_to_entry(dev) for dev in devices]


def list_devices() -> list[dict[str, Any]]:
    """List every iOS device currently visible to usbmuxd (USB and network)."""
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
    await asyncio.to_thread(stop.wait)


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
        try:
            if await maybe_await(client.get_enable_wifi_connections()):
                return
        except MissingValueError:
            pass  # never written on this phone: that is "off"
        label = (await lockdown.all_values(client)).get("DeviceName") or label
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

    ``reconnect_wait`` is only paid when the Listen socket itself cannot be
    opened or dies (service not running, AMDS restart). It is not an inventory
    interval.
    """
    from pymobiledevice3.exceptions import MuxException

    async def default_create_mux() -> Any:
        from pymobiledevice3 import usbmux

        return await usbmux.create_mux()

    factory = create_mux or default_create_mux
    last: tuple[tuple[Any, ...], ...] | None = None
    had_listen = False
    stopped = asyncio.create_task(_wait_until_stopped(stop))

    def publish(entries: list[dict[str, Any]]) -> None:
        nonlocal last
        signature = listing_signature(entries)
        if signature == last:
            return
        last = signature
        emit({"type": "event", "name": "devices", "data": entries})

    # Phones already tried this attach, and the cable phones seen in the current Listen
    # session. A serial stays in ``tried`` until a Detached is seen for it, so usbmux
    # re-announcing a phone after the Listen socket is re-opened does not start another
    # attempt; the next real attach after an unplug does.
    tried: set[str] = set()
    on_cable: set[str] = set()
    syncing: set[asyncio.Task[None]] = set()
    relistened = False

    def _sync_done(task: asyncio.Task[None]) -> None:
        syncing.discard(task)
        if not task.cancelled():
            task.exception()  # retrieved so a failed announce is not logged as unhandled

    def sync_new_cable_phones(entries: list[dict[str, Any]]) -> None:
        nonlocal relistened
        now = {
            str(entry["serial"])
            for entry in entries
            if entry.get("connection_type") == "USB" and entry.get("serial")
        }
        tried.difference_update(on_cable - now)
        if relistened:
            # The socket was down, so a Detached may have been missed: a phone that is
            # not announced again is gone, and its next attach is a real one.
            tried.intersection_update(now)
            relistened = False
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
                    publish([mux_device_to_entry(dev) for dev in mux.devices])
                had_listen = True
                on_cable.clear()  # a new session announces everyone afresh
                relistened = True
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
                    publish(entries)
                    sync_new_cable_phones(entries)
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
        for task in list(syncing):
            task.cancel()
        if syncing:
            await asyncio.gather(*syncing, return_exceptions=True)
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
