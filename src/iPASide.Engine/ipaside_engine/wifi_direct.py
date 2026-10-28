"""Reach a phone over the LAN when Apple Mobile Device Service does not list it.

AMDS finds Wi-Fi phones by multicast mDNS, which many routers and access points
filter, so a phone that was plugged in once and has Wi-Fi sync on can vanish from
usbmux the moment the cable is out although it answers on the network just fine.
This module remembers every phone seen paired over USB (its UDID and its Wi-Fi MAC,
the ``WiFiAddress`` lockdown value), finds it again by asking hosts on the local
networks directly - a legacy unicast DNS-SD query for ``_apple-mobdev2._tcp.local``
sent to ``<ip>:5353`` - and opens lockdown over TCP with the pair record this PC
already holds. It never pairs: a phone that does not accept the record is refused.

Over the network lockdownd hands out service ports but drops every service
connection right after its TLS handshake unless the host holds a heartbeat
(``com.apple.mobile.heartbeat``, the Marco/Polo exchange AMDS and netmuxd keep for
Wi-Fi phones). ``connect`` therefore opens one and answers it until the client closes.

An answer on the LAN proves nothing about who answered, so the TCP client
(``PinnedTcpLockdownClient``) pins every connection to the phone's certificate from
the pair record, and bounds every step so a silent host cannot hang a refresh.

The phone names itself in its answer: the instance label starts with its Wi-Fi MAC
(``40:98:ad:39:e6:82@fe80::...``), the hardware address, which a private Wi-Fi
address does not change. That is what a reply is matched on, not the IP.
"""

from __future__ import annotations

import asyncio
import contextlib
import contextvars
import datetime
import functools
import inspect
import ipaddress
import json
import os
import random
import re
import socket
import ssl
import struct
import sys
import tempfile
import threading
import time
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

from . import paths, secure_store
from ._asyncutil import maybe_await

MDNS_PORT = 5353
SERVICE = "_apple-mobdev2._tcp.local"
#: How long the remembered address gets to answer before the networks are swept.
LAST_IP_TIMEOUT = 0.8
#: How long replies to a sweep are collected.
SWEEP_WINDOW = 2.5
#: Hard ceiling on one ``find``.
TOTAL_LIMIT = 4.0
#: An inventory (``devices``, the Listen watcher) sweeps for one phone at most this
#: often, in seconds; in between it only asks the last known address.
SWEEP_INTERVAL = 300.0
#: Each step of opening a TCP session (connect, StartSession, heartbeat start, first
#: Marco) must finish within this many seconds, or the phone counts as gone.
STEP_TIMEOUT = 10.0
#: How long a state update waits for another thread or process to finish its own.
LOCK_WAIT = 1.0
#: An unchanged phone entry is rewritten only when its ``seen`` is older than this.
SEEN_REFRESH = datetime.timedelta(days=1)
HEARTBEAT = "com.apple.mobile.heartbeat"
#: The oldest iOS reached over Wi-Fi direct; older ones validate pairing in plaintext.
MIN_IOS = 11
#: Heartbeat interval when the phone names none, and the most it may ask for.
DEFAULT_INTERVAL = 10.0
MAX_INTERVAL = 30.0
#: A Marco may be this many seconds later than twice its interval before the
#: watchdog counts the phone as gone (so at most 2 * 30 + 5 = 65 s).
HEARTBEAT_SLACK = 5.0
#: A read that gets no data for this many seconds tears the Wi-Fi connection down.
IDLE_READ = 60.0
#: Overall caps on one public operation over Wi-Fi direct, in seconds.
SHORT_CAP = 120.0
INSTALL_CAP = 1800.0
#: After a dropped connection: how long to wait for the phone to answer again, and
#: the pause between looks.
RETRY_WINDOW = 75.0
RETRY_PAUSE = 5.0

_QTYPE_PTR = 12
_QCLASS_IN = 1
_PRIVATE = tuple(
    ipaddress.ip_network(net) for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
)
_MAC_RE = re.compile(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")
_THREAD_LOCK = threading.Lock()
_SWEEP_LOCK = threading.Lock()
_swept: dict[str, float] = {}  # UDID -> monotonic time of its last inventory sweep
#: The Wi-Fi clients opened by the current operation attempt (see ``wifi_operation``).
_attempt: contextvars.ContextVar[list[Any] | None] = contextvars.ContextVar(
    "wifi_direct_attempt", default=None
)


def _log(message: str) -> None:
    # The real stderr: under ``serve`` sys.stderr turns lines into progress frames.
    print(f"wifi-direct: {message}", file=sys.__stderr__ or sys.stderr, flush=True)


# --------------------------------------------------------------------------- #
# State file


class _Busy(Exception):
    """Another thread or process holds the state lock past ``LOCK_WAIT``."""


def _empty() -> dict[str, Any]:
    return {"version": 1, "devices": {}}


def _read() -> dict[str, Any] | None:
    """The remembered phones, or None when the file is there but cannot be read.

    A damaged file is moved aside and reported, then counts as empty: its content is
    kept beside it, so writing a fresh file loses nothing.
    """
    path = paths.wifi_devices_file()
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return _empty()
    except OSError as exc:
        _log(f"cannot read {path}: {exc}")
        return None
    try:
        data = json.loads(text)
    except ValueError:
        data = None
    if isinstance(data, dict) and isinstance(data.get("devices"), dict):
        return data
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    aside = path.with_name(f"{path.name}.corrupt-{stamp}")
    try:
        os.replace(path, aside)
        _log(f"{path} was damaged and has been moved to {aside}")
    except OSError as exc:
        _log(f"{path} is damaged and could not be moved aside: {exc}")
        return None
    return _empty()


def _load() -> dict[str, Any]:
    return _read() or _empty()


def _save(state: dict[str, Any]) -> None:
    """Write the state atomically: a temp file beside it, then one rename."""
    path = paths.wifi_devices_file()
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=f"{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        secure_store.replace_atomic(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise


@contextlib.contextmanager
def _locked() -> Iterator[None]:
    """Hold the state lock: one load-modify-save at a time, across threads and processes.

    The Listen watcher (serve process) and a scheduled refresh (its own process) both
    update the file; without this the last writer would drop the other's phone. Gives
    up with ``_Busy`` after ``LOCK_WAIT`` rather than hold up a connection.
    """
    deadline = time.monotonic() + LOCK_WAIT
    if not _THREAD_LOCK.acquire(timeout=LOCK_WAIT):
        raise _Busy()
    try:
        path = paths.wifi_devices_file()
        with open(path.with_name(f"{path.name}.lock"), "a+b") as handle:
            while not _try_lock(handle):
                if time.monotonic() >= deadline:
                    raise _Busy()
                time.sleep(0.02)
            try:
                yield
            finally:
                _unlock(handle)
    finally:
        _THREAD_LOCK.release()


def _try_lock(handle: Any) -> bool:
    try:
        if sys.platform == "win32":
            import msvcrt

            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl

            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


def _unlock(handle: Any) -> None:
    if sys.platform == "win32":
        import msvcrt

        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
    else:
        import fcntl

        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _update(what: str, change: Callable[[dict[str, Any]], bool]) -> None:
    """Apply ``change`` to the devices map under the lock; save only if it says so.

    Never raises. A file that could not be read is never overwritten: that would drop
    every other phone in it.
    """
    try:
        with _locked():
            state = _read()
            if state is None:
                _log(f"left {what} unsaved: the state file could not be read")
                return
            if change(state["devices"]):
                _save(state)
    except _Busy:
        _log(f"left {what} unsaved: the state file is busy")
    except Exception as exc:
        _log(f"could not save {what}: {exc}")


def _normalize_mac(value: Any) -> str | None:
    mac = str(value or "").strip().lower().replace("-", ":")
    return mac if _MAC_RE.match(mac) else None


def _fresh(seen: Any) -> bool:
    """True when ``seen`` is under ``SEEN_REFRESH`` old."""
    try:
        age = datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(
            str(seen)
        )
    except (TypeError, ValueError):
        return False
    return age < SEEN_REFRESH


def remember(udid: str, wifi_mac: Any, name: str | None = None) -> None:
    """Note a phone seen paired over USB, so it can be found on the LAN later.

    Never raises: losing this note only means no cable-free refresh for that phone.
    Called on every paired USB connection, so an unchanged entry seen within the last
    day is not rewritten.
    """
    mac = _normalize_mac(wifi_mac)
    if not udid or mac is None:
        return

    def change(devices: dict[str, Any]) -> bool:
        entry = devices.get(udid)
        old = entry if isinstance(entry, dict) else {}
        new = {
            "wifi_mac": mac,
            "last_ip": old.get("last_ip") if old.get("wifi_mac") == mac else None,
            "name": name or old.get("name"),
        }
        if all(old.get(k) == v for k, v in new.items()) and _fresh(old.get("seen")):
            return False
        new["seen"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
        devices[udid] = new
        return True

    _update(f"phone {udid[:8]}", change)


def remembered() -> list[str]:
    """Every UDID with a usable Wi-Fi MAC on record."""
    return [
        udid
        for udid, entry in _load()["devices"].items()
        if isinstance(entry, dict) and _normalize_mac(entry.get("wifi_mac"))
    ]


def is_remembered(udid: str | None) -> bool:
    return bool(udid) and udid in remembered()


def _set_last_ip(udid: str, ip: str) -> None:
    def change(devices: dict[str, Any]) -> bool:
        entry = devices.get(udid)
        if not isinstance(entry, dict) or entry.get("last_ip") == ip:
            return False
        entry["last_ip"] = ip
        return True

    _update(f"the address of {udid[:8]}", change)


# --------------------------------------------------------------------------- #
# DNS-SD wire format


def _query(query_id: int) -> bytes:
    """A legacy unicast PTR query (RFC 6762 §6.7): any source port, unicast answer."""
    header = struct.pack("!HHHHHH", query_id, 0, 1, 0, 0, 0)
    name = b"".join(bytes([len(p)]) + p.encode() for p in SERVICE.split(".")) + b"\0"
    return header + name + struct.pack("!HH", _QTYPE_PTR, _QCLASS_IN)


def _read_name(data: bytes, offset: int) -> tuple[list[bytes], int]:
    """The labels of the name at ``offset`` and the offset just past it in the record."""
    labels: list[bytes] = []
    end: int | None = None
    for _hop in range(128):  # bounds a pointer loop
        length = data[offset]
        if length & 0xC0 == 0xC0:
            if end is None:
                end = offset + 2
            offset = ((length & 0x3F) << 8) | data[offset + 1]
            continue
        if length & 0xC0:
            raise ValueError("reserved label type")
        offset += 1
        if length == 0:
            return labels, end if end is not None else offset
        label = data[offset:offset + length]
        if len(label) != length:
            raise ValueError("truncated label")
        labels.append(label)
        offset += length
    raise ValueError("name pointer loop")


def instances(data: bytes) -> list[str]:
    """The service instance labels in a DNS-SD reply's PTR records (any section)."""
    found: list[str] = []
    try:
        _id, _flags, qd, an, ns, ar = struct.unpack_from("!HHHHHH", data, 0)
        offset = 12
        for _ in range(qd):
            _labels, offset = _read_name(data, offset)
            offset += 4
        for _ in range(an + ns + ar):
            _labels, offset = _read_name(data, offset)
            rtype, _cls, _ttl, rdlen = struct.unpack_from("!HHIH", data, offset)
            offset += 10
            if rtype == _QTYPE_PTR:
                target, _end = _read_name(data, offset)
                if target:
                    found.append(target[0].decode("utf-8", "replace"))
            offset += rdlen
    except (IndexError, ValueError, struct.error):
        pass  # keep what parsed; a short or odd packet is not this phone's answer
    return found


def matches(data: bytes, wifi_mac: str) -> bool:
    """True when the reply advertises the phone whose Wi-Fi MAC is ``wifi_mac``."""
    mac = _normalize_mac(wifi_mac)
    return mac is not None and any(
        _normalize_mac(label.split("@", 1)[0]) == mac for label in instances(data)
    )


# --------------------------------------------------------------------------- #
# Local networks


def network_of(address: str | None) -> ipaddress.IPv4Network | None:
    """The /24 around ``address`` to sweep, or None when it is not worth sweeping.

    Only an RFC 1918 private address qualifies (10/8, 172.16/12, 192.168/16): that
    rules out public, CGNAT/Tailscale (100.64/10), link-local and loopback addresses
    without guessing prefixes across VPN adapters.
    """
    try:
        ip = ipaddress.IPv4Address(str(address))
    except ValueError:
        return None
    if not any(ip in net for net in _PRIVATE):
        return None
    return ipaddress.IPv4Interface(f"{ip}/24").network


def _primary_address() -> str | None:
    """This PC's address on its primary route (the UDP-connect trick sends nothing)."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("192.0.2.1", 9))
            return probe.getsockname()[0]
    except OSError:
        return None


# --------------------------------------------------------------------------- #
# Finding and connecting


def _open_socket() -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", 0))
    return sock


def _await_reply(
    sock: Any, mac: str, query_id: int, asked: set[str], deadline: float
) -> str | None:
    """The host that answered for ``mac`` before ``deadline``, or None.

    Only an answer to this query (same ID) from a host it was sent to, from port 5353,
    counts: anything else on the LAN could claim the MAC.
    """
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        sock.settimeout(remaining)
        try:
            data, addr = sock.recvfrom(65535)
        except socket.timeout:
            return None
        except OSError:
            # Windows reports an ICMP port-unreachable from a swept host as a reset, and
            # an oversized datagram as WinError 10040; neither ends the search.
            continue
        if (
            len(data) >= 2
            and struct.unpack_from("!H", data)[0] == query_id
            and addr[0] in asked
            and addr[1] == MDNS_PORT
            and matches(data, mac)
        ):
            return addr[0]


def _send(sock: Any, packet: bytes, host: str, asked: set[str]) -> None:
    asked.add(host)
    try:
        sock.sendto(packet, (host, MDNS_PORT))
    except OSError:
        pass  # one unreachable host does not end the search


def find(udid: str, *, sweep: bool | Callable[[], bool] = True) -> str | None:
    """A current IPv4 address for a remembered phone, or None.

    The last known address first, if it is still on this PC's network; then, when
    ``sweep`` (or ``sweep()``, asked only if it comes to that) is true, every host of
    that /24 at once from one socket. Bounded by ``TOTAL_LIMIT`` seconds.
    """
    entry = _load()["devices"].get(udid)
    mac = _normalize_mac(entry.get("wifi_mac")) if isinstance(entry, dict) else None
    if mac is None:
        return None
    start = time.monotonic()
    own = _primary_address()
    net = network_of(own)
    hosts = [str(host) for host in net.hosts() if str(host) != own] if net else []
    last_ip = entry.get("last_ip")
    if last_ip not in hosts:
        last_ip = None  # another LAN's address: never queried, never kept
    query_id = random.randint(1, 0xFFFF)
    packet = _query(query_id)
    asked: set[str] = set()
    found: str | None = None
    try:
        with _open_socket() as sock:
            if last_ip:
                _send(sock, packet, last_ip, asked)
                found = _await_reply(sock, mac, query_id, asked, start + LAST_IP_TIMEOUT)
            if found is None and hosts and (sweep() if callable(sweep) else sweep):
                for host in hosts:
                    _send(sock, packet, host, asked)
                deadline = min(time.monotonic() + SWEEP_WINDOW, start + TOTAL_LIMIT)
                found = _await_reply(sock, mac, query_id, asked, deadline)
    except OSError as exc:
        _log(f"search for {udid[:8]} failed: {exc}")
        return None
    if found is not None and found != entry.get("last_ip"):
        _set_last_ip(udid, found)
    return found


def _sweep_due(udid: str) -> bool:
    """True, and the clock restarted, when ``udid`` has not been swept for recently."""
    now = time.monotonic()
    with _SWEEP_LOCK:
        last = _swept.get(udid)
        if last is not None and now - last < SWEEP_INTERVAL:
            return False
        _swept[udid] = now
        return True


def locate(udid: str) -> str | None:
    """``find`` for an inventory: a sweep at most once per ``SWEEP_INTERVAL`` per phone.

    The ``devices`` listing and the Listen watcher run this often; between sweeps they
    only ask the last known address, which costs at most ``LAST_IP_TIMEOUT``. A lookup
    already running when the watcher stops finishes on its own (at most ``TOTAL_LIMIT``).
    """
    return find(udid, sweep=lambda: _sweep_due(udid))


# --------------------------------------------------------------------------- #
# The pinned TCP session


def _device_error(message: str) -> Exception:
    from . import device  # deferred: device imports this module at load time

    return device.DeviceError(message)


def _device_der(record: dict[str, Any]) -> bytes | None:
    """The phone's own certificate (DER) from the pair record, or None."""
    try:
        pem = record["DeviceCertificate"]
        return ssl.PEM_cert_to_DER_cert(pem.decode() if isinstance(pem, bytes) else pem)
    except (KeyError, TypeError, ValueError, AttributeError):
        return None


def _peer_problem(conn: Any, der: bytes) -> str | None:
    """Why ``conn`` is not a TLS connection to the paired phone, or None."""
    writer = getattr(conn, "writer", None)
    tls = writer.get_extra_info("ssl_object") if writer is not None else None
    if tls is None:
        return "it did not secure the connection"
    if tls.getpeercert(binary_form=True) != der:
        return "its certificate is not the paired phone's"
    return None


def _major(version: Any) -> int:
    try:
        return int(str(version).split(".")[0])
    except ValueError:
        return 0


def _interval(message: Any) -> float:
    """The phone's heartbeat interval, capped at ``MAX_INTERVAL``."""
    try:
        value = float(message.get("Interval", DEFAULT_INTERVAL))
    except (AttributeError, TypeError, ValueError):
        value = DEFAULT_INTERVAL
    return min(max(value, 0.1), MAX_INTERVAL)


async def _close_bounded(closable: Any) -> None:
    """Close ``closable`` within ``STEP_TIMEOUT``; a stuck close must not hold anything."""
    try:
        await asyncio.wait_for(maybe_await(closable.close()), STEP_TIMEOUT)
    except Exception:
        pass


@functools.cache
def _classes() -> tuple[type, type]:
    """``(PinnedConnection, PinnedTcpLockdownClient)``, built on first use.

    Built lazily so importing this module (which ``device`` does at load) does not
    load pymobiledevice3.
    """
    from pymobiledevice3.exceptions import ConnectionTerminatedError
    from pymobiledevice3.lockdown import TcpLockdownClient
    from pymobiledevice3.service_connection import ServiceConnection

    class PinnedConnection(ServiceConnection):
        """A Wi-Fi socket whose reads give up after ``IDLE_READ`` seconds of silence.

        Every read of every service ends in ``recvall`` or ``recv_any``; a phone that
        stops sending mid-operation tears the whole client down instead of holding the
        operation (and the engine lock) forever.
        """

        owner: Any = None

        async def _idle_bounded(self, read: Any) -> Any:
            try:
                return await asyncio.wait_for(read, IDLE_READ)
            except asyncio.TimeoutError:
                if self.owner is not None:
                    await self.owner.teardown(f"no data from the phone for {IDLE_READ:g} s")
                raise ConnectionTerminatedError() from None

        async def recvall(self, size: int) -> bytes:
            return await self._idle_bounded(super().recvall(size))

        async def recv_any(self, length: int = 4096) -> bytes:
            return await self._idle_bounded(super().recv_any(length))

    class PinnedTcpLockdownClient(TcpLockdownClient):
        """Lockdown over TCP that only ever talks to the paired phone.

        - iOS older than 11 is refused before pymobiledevice3 could send the legacy
          ``ValidatePair`` (which carries the whole pair record in plaintext).
        - The session and every service connection must be TLS, with the phone's own
          certificate from the pair record, and the phone must report the UDID asked
          for. Only the heartbeat may be plaintext: it carries nothing.
        - A dropped connection is never re-opened behind the caller's back.
        - A heartbeat watchdog and per-read deadlines close everything when the phone
          goes silent, so the operation fails instead of hanging.
        """

        def __init__(self, *args: Any, requested_udid: str, device_der: bytes, **kwargs: Any):
            super().__init__(*args, **kwargs)
            self.requested_udid = requested_udid
            self._der = device_der
            self.connections: list[Any] = []
            self.secured: dict[str, bool] = {}  # service name -> opened over TLS
            self.dropped = False
            self._starting: str | None = None
            self._heartbeat: asyncio.Task[None] | None = None
            self.loop: asyncio.AbstractEventLoop | None = None
            self._closing: asyncio.Future[None] | None = None

        def _refused(self, problem: str) -> Exception:
            return _device_error(
                f"Refused the host at {self.hostname} for device {self.requested_udid}: "
                f"{problem}."
            )

        async def validate_pairing(self) -> bool:
            if _major(self.product_version) < MIN_IOS:
                raise self._refused(
                    f"it reports iOS {self.product_version}; Wi-Fi direct needs iOS {MIN_IOS}+"
                )
            if not await super().validate_pairing():
                raise self._refused("it no longer trusts this PC; plug it in and tap Trust")
            problem = _peer_problem(self.service, self._der)
            if problem is None and (self.all_values or {}).get("UniqueDeviceID") != self.requested_udid:
                problem = "it is a different device"
            if problem is not None:
                raise self._refused(problem)
            return True

        async def areestablish_connection(self) -> None:
            self.dropped = True
            raise _device_error("Wi-Fi connection to the phone dropped.")

        async def start_lockdown_service(self, name: str, include_escrow_bag: bool = False) -> Any:
            self._starting = name
            try:
                return await super().start_lockdown_service(name, include_escrow_bag=include_escrow_bag)
            finally:
                self._starting = None

        async def create_service_connection(
            self, port: int, ssl_context: Any = None, strip_ssl: bool = False
        ) -> Any:
            name = self._starting or "a service"
            if strip_ssl or (ssl_context is None and name != HEARTBEAT):
                raise self._refused(f"it offered {name} without TLS")
            conn = await _step(
                PinnedConnection.create_using_tcp(
                    self.hostname, port, keep_alive=True, ssl_context=ssl_context
                ),
                name,
            )
            conn.owner = self
            problem = _peer_problem(conn, self._der) if ssl_context is not None else None
            if problem is not None:
                await _close_bounded(conn)
                raise self._refused(f"{name}: {problem}")
            self.secured[name] = ssl_context is not None
            self.connections.append(conn)
            return conn

        async def teardown(self, reason: str) -> None:
            """Close every connection so pending reads fail; the client is then dead.

            The closing runs in a task of its own, started before the heartbeat is
            cancelled: a teardown called from inside the heartbeat (its idle read) would
            otherwise be cancelled with it and leave sockets open.
            """
            if not self.dropped:
                _log(f"closing the Wi-Fi connection to {self.requested_udid[:8]}: {reason}")
            self.dropped = True
            if self._closing is None:
                self._closing = asyncio.ensure_future(self._close_all())
            task = self._heartbeat
            if task is not None and task is not asyncio.current_task():
                task.cancel()
            await asyncio.shield(self._closing)

        async def _close_all(self) -> None:
            for conn in [*self.connections, self.service]:
                await _close_bounded(conn)

        async def close(self) -> None:
            task, self._heartbeat = self._heartbeat, None
            if task is not None and task is not asyncio.current_task():
                task.cancel()
                await asyncio.wait({task}, timeout=STEP_TIMEOUT)
            for conn in self.connections:
                await _close_bounded(conn)
            await _close_bounded(self.service)

    return PinnedConnection, PinnedTcpLockdownClient


async def _step(awaitable: Any, what: str) -> Any:
    """``awaitable`` within ``STEP_TIMEOUT``; a silent peer must not hang a refresh."""
    try:
        return await asyncio.wait_for(maybe_await(awaitable), STEP_TIMEOUT)
    except asyncio.TimeoutError:
        raise TimeoutError(f"no answer to {what} within {STEP_TIMEOUT:g} s") from None


async def _open_session(ip: str, udid: str, record: dict[str, Any], der: bytes) -> Any:
    """A pinned lockdown session over TCP to ``ip`` with ``record``; never pairs.

    The connection and the client are made in two steps (what ``create_using_tcp``
    does) so the socket can be closed when StartSession times out, is refused or is
    cancelled.
    """
    from pymobiledevice3.lockdown import SERVICE_PORT

    connection, client_class = _classes()
    service = await _step(
        connection.create_using_tcp(ip, SERVICE_PORT, keep_alive=True), "connect"
    )
    try:
        client = await _step(
            client_class.create(
                service,
                identifier=udid,
                pair_record=record,
                autopair=False,
                pairing_records_cache_folder=paths.data_dir() / "lockdown",
                port=SERVICE_PORT,
                hostname=ip,
                keep_alive=True,
                requested_udid=udid,
                device_der=der,
            ),
            "StartSession",
        )
    except BaseException:
        await _close_bounded(service)
        raise
    service.owner = client
    return client


async def _start_heartbeat(client: Any) -> float:
    """Open the heartbeat, answer its first ``Marco`` and keep answering in a task."""
    beat = await _step(client.start_lockdown_service(HEARTBEAT), "the heartbeat")
    first = await _step(beat.recv_plist(), "the first heartbeat")
    await _step(beat.send_plist({"Command": "Polo"}), "the first heartbeat")
    interval = _interval(first)
    client._heartbeat = asyncio.create_task(_heartbeat(client, beat, interval))
    return interval


async def _heartbeat(client: Any, beat: Any, interval: float) -> None:
    """Answer each ``Marco`` with ``Polo``; tear the client down when the phone stops.

    No Marco within ``2 * interval + HEARTBEAT_SLACK`` s, or a Polo not sent within
    ``STEP_TIMEOUT``, means the phone is gone.
    """
    try:
        while True:
            message = await asyncio.wait_for(beat.recv_plist(), 2 * interval + HEARTBEAT_SLACK)
            interval = _interval(message)
            await asyncio.wait_for(beat.send_plist({"Command": "Polo"}), STEP_TIMEOUT)
    except asyncio.CancelledError:
        raise
    except Exception:
        await client.teardown("the heartbeat stopped")


async def connect(udid: str) -> Any:
    """A pinned lockdown client over TCP for a remembered phone, or ``DeviceError``.

    Uses the pair record this PC already holds (AMDS, then iTunes, then EZSide's
    cache folder) and never pairs. The client holds a running heartbeat, which its
    ``close`` stops. Timeouts, refusals and cancellation close whatever was opened.
    """
    from . import device  # deferred: device imports this module at load time

    try:
        from pymobiledevice3.pair_records import get_preferred_pair_record

        _classes()
    except ImportError as exc:
        raise device.DeviceError(
            "Wi-Fi direct needs a newer pymobiledevice3 than the one installed."
        ) from exc

    ip = await asyncio.to_thread(find, udid)
    if ip is None:
        raise device.DeviceError(f"Device {udid} was not found on the local network.")
    try:  # a stalled AMDS must not hold the engine before any cap applies
        record = await _step(
            get_preferred_pair_record(udid, paths.data_dir() / "lockdown"), "the pair record lookup"
        )
    except TimeoutError as exc:
        raise device.DeviceError(f"Could not read the pair record for device {udid}: {exc}.") from exc
    if not record:
        raise device.DeviceError(f"This PC holds no pair record for device {udid}.")
    der = _device_der(record)
    if der is None:
        raise device.DeviceError(
            f"The pair record for device {udid} holds no device certificate."
        )
    try:
        client = await _open_session(ip, udid, record, der)
    except device.DeviceError:
        raise
    except Exception as exc:
        detail = str(exc) or type(exc).__name__
        raise device.DeviceError(f"Device {udid} at {ip} did not answer: {detail}.") from exc
    try:
        await _start_heartbeat(client)
    except BaseException as exc:
        await client.close()
        if isinstance(exc, device.DeviceError) or not isinstance(exc, Exception):
            raise
        detail = str(exc) or type(exc).__name__
        raise device.DeviceError(
            f"Device {udid} at {ip} refused a network session: {detail}."
        ) from exc
    client.loop = asyncio.get_running_loop()  # where a cap from another thread tears it down
    clients = _attempt.get()
    if clients is not None:
        clients.append(client)
    return client


# --------------------------------------------------------------------------- #
# Operation boundary: overall cap and one retry after a dropped connection


def _is_drop(exc: BaseException, clients: list[Any]) -> bool:
    """True when ``exc`` came from a Wi-Fi-direct connection that dropped.

    Never for a refusal (pin, version, unpaired), an install error or a USB failure:
    only a client this attempt opened over Wi-Fi that was torn down or lost.
    """
    from pymobiledevice3.exceptions import ConnectionTerminatedError

    if not clients or isinstance(exc, _CapExpired):
        return False
    if any(getattr(client, "dropped", False) for client in clients):
        return True
    return isinstance(exc, (ConnectionError, ConnectionTerminatedError, asyncio.IncompleteReadError))


class _CapExpired(Exception):
    """An operation over Wi-Fi ran past its overall cap; never retried."""


def _cancel_all(loop: asyncio.AbstractEventLoop) -> None:
    for task in asyncio.all_tasks(loop):
        task.cancel()


def _abort_elsewhere(client: Any, reason: str) -> None:
    """Tear ``client`` down on its own event loop (another thread) and stop that loop's work."""
    loop = getattr(client, "loop", None)
    if loop is None or loop.is_closed():
        return
    with contextlib.suppress(Exception):
        asyncio.run_coroutine_threadsafe(client.teardown(reason), loop).result(STEP_TIMEOUT)
    with contextlib.suppress(RuntimeError):  # that loop already finished
        loop.call_soon_threadsafe(_cancel_all, loop)


async def _attempt_async(fn: Any, args: tuple, kwargs: dict, cap: float) -> tuple[Any, list[Any]]:
    """Run async ``fn`` once; over Wi-Fi it is cut off after ``cap`` seconds.

    Returns the finished task and the Wi-Fi clients it opened. A USB-only attempt
    has no cap: its behaviour does not change.
    """
    clients: list[Any] = []
    token = _attempt.set(clients)
    try:
        task = asyncio.create_task(fn(*args, **kwargs))
    finally:
        _attempt.reset(token)
    try:
        while True:
            done, _pending = await asyncio.wait({task}, timeout=cap)
            if done:
                return task, clients
            if clients:
                for client in clients:
                    await client.teardown(f"the operation ran past {cap:g} s")
                task.cancel()
                await asyncio.wait({task}, timeout=STEP_TIMEOUT)
                raise _CapExpired()
    except BaseException:
        task.cancel()
        raise


def _attempt_sync(fn: Any, args: tuple, kwargs: dict, cap: float) -> tuple[dict[str, Any], list[Any]]:
    """Run sync ``fn`` (which runs its own event loop) once, capped like ``_attempt_async``.

    ``fn`` runs in the caller's thread, as without the decorator. A watcher thread
    enforces the cap: past it, the Wi-Fi clients ``fn`` opened are torn down on their
    own loop and that loop's tasks cancelled, so ``fn`` ends.
    """
    clients: list[Any] = []
    capped = threading.Event()
    finished = threading.Event()

    def watch() -> None:
        while not finished.wait(cap):
            if clients:
                capped.set()
                for client in list(clients):
                    _abort_elsewhere(client, f"the operation ran past {cap:g} s")
                return

    token = _attempt.set(clients)
    threading.Thread(target=watch, name="wifi-operation-cap", daemon=True).start()
    try:
        try:
            return {"result": fn(*args, **kwargs)}, clients
        except BaseException as exc:
            if capped.is_set():
                raise _CapExpired() from None
            if not isinstance(exc, Exception):
                raise
            return {"error": exc}, clients
    finally:
        finished.set()
        _attempt.reset(token)


def _found_again(udid: str) -> bool:
    """Wait for ``udid`` to answer on the LAN again, for up to ``RETRY_WINDOW`` s."""
    deadline = time.monotonic() + RETRY_WINDOW
    while True:
        time.sleep(RETRY_PAUSE)
        if find(udid) is not None:
            return True
        if time.monotonic() >= deadline:
            return False


def _cap_error(cap: float) -> Exception:
    return _device_error(
        f"The phone did not finish within {cap:g} s over Wi-Fi; try again with the cable."
    )


def wifi_operation(*, cap: float, retry: bool) -> Callable[[Any], Any]:
    """Decorate a public operation (sync or async) that takes ``serial``.

    The target is resolved once, before the first attempt, and every attempt gets
    ``serial=<that UDID>``: a retry never looks at the inventory again, so it cannot
    land on another phone. An attempt that opened no Wi-Fi-direct connection (USB,
    usbmux) runs once, as before: no cap, no retry. Over Wi-Fi direct the attempt is
    cut off after ``cap`` seconds, and with ``retry`` a dropped connection runs the
    operation once more from the start, on a new pinned connection, after the phone
    answers again (the idle phone goes quiet for about a minute). ``fn`` must be
    idempotent for ``retry``.
    """

    def decorate(fn: Any) -> Any:
        signature = inspect.signature(fn)
        if "serial" not in signature.parameters:
            raise TypeError(f"{fn.__qualname__} takes no serial")

        def frozen(args: tuple, kwargs: dict, udid: str) -> tuple[tuple, dict]:
            bound = signature.bind(*args, **kwargs)
            bound.arguments["serial"] = udid
            return bound.args, bound.kwargs

        def given(args: tuple, kwargs: dict) -> Any:
            return signature.bind(*args, **kwargs).arguments.get("serial")

        def retry_after(exc: BaseException, clients: list[Any], udid: str) -> bool:
            if not retry or not _is_drop(exc, clients):
                return False
            _log("Wi-Fi connection dropped, retrying once")
            return _found_again(udid)

        if inspect.iscoroutinefunction(fn):

            @functools.wraps(fn)
            async def run_async(*args: Any, **kwargs: Any) -> Any:
                from . import device  # deferred: device imports this module at load time

                udid = await device.resolve_serial_async(given(args, kwargs))
                args, kwargs = frozen(args, kwargs, udid)
                for last in (False, True):
                    try:
                        task, clients = await _attempt_async(fn, args, kwargs, cap)
                    except _CapExpired:
                        raise _cap_error(cap) from None
                    exc = task.exception()
                    if exc is None:
                        return task.result()
                    if last or not await asyncio.to_thread(retry_after, exc, clients, udid):
                        raise exc

            return run_async

        @functools.wraps(fn)
        def run_sync(*args: Any, **kwargs: Any) -> Any:
            from . import device  # deferred: device imports this module at load time

            udid = device.resolve_serial(given(args, kwargs))
            args, kwargs = frozen(args, kwargs, udid)
            for last in (False, True):
                try:
                    outcome, clients = _attempt_sync(fn, args, kwargs, cap)
                except _CapExpired:
                    raise _cap_error(cap) from None
                if "error" not in outcome:
                    return outcome["result"]
                exc = outcome["error"]
                if last or not retry_after(exc, clients, udid):
                    raise exc

        return run_sync

    return decorate
