"""Tests for Wi-Fi direct: finding a phone usbmux does not list, and reaching it by TCP.

All offline: the UDP socket and the pymobiledevice3 entry points are replaced.
"""

import asyncio
import inspect
import json
import socket
import ssl
import struct
import threading
import time

import pytest

from ipaside_engine import device, lockdown, pairing, paths, sideload, wifi_direct

UDID = "4fd25abf1b629b2c261becbecfb2d2a86e34b357"
OTHER = "0f1e2d3c4b5a69788796a5b4c3d2e1f009876543"
MAC = "40:98:ad:39:e6:82"
INSTANCE = f"{MAC}@fe80::4298:adff:fe39:e682-supportsRP-17"
PC = "192.168.1.20"
PHONE = "192.168.1.53"


@pytest.fixture(autouse=True)
def fresh_sweep_clock():
    wifi_direct._swept.clear()
    yield
    wifi_direct._swept.clear()


def _labels(name: str) -> bytes:
    return b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0"


def _reply(instance: str = INSTANCE, query_id: int = 0x1234) -> bytes:
    """A legacy unicast answer as an iPhone sends it: names compressed by pointers."""
    header = struct.pack("!HHHHHH", query_id, 0x8400, 1, 1, 0, 1)
    question = _labels("_apple-mobdev2._tcp.local") + struct.pack("!HH", 12, 1)
    packet = header + question  # the service name sits at offset 12
    inst = instance.encode()
    rdata = bytes([len(inst)]) + inst + b"\xc0\x0c"
    answer = b"\xc0\x0c" + struct.pack("!HHIH", 12, 1, 10, len(rdata)) + rdata
    instance_at = len(packet) + len(answer) - len(rdata)
    srv = struct.pack("!HHH", 0, 0, 62078) + b"\xc0\x0c"
    additional = (
        struct.pack("!H", 0xC000 | instance_at)
        + struct.pack("!HHIH", 33, 1, 10, len(srv))
        + srv
    )
    return packet + answer + additional


# --- wire format ------------------------------------------------------------ #


def test_the_real_instance_string_is_read_through_compression_pointers():
    assert wifi_direct.instances(_reply()) == [INSTANCE]


def test_a_pointer_loop_or_a_short_packet_yields_nothing():
    looped = struct.pack("!HHHHHH", 1, 0x8400, 1, 0, 0, 0) + b"\xc0\x0c"
    assert wifi_direct.instances(looped) == []
    assert wifi_direct.instances(_reply()[:40]) == []
    assert wifi_direct.instances(b"") == []


def test_the_mac_match_ignores_case_and_rejects_other_phones():
    reply = _reply()
    assert wifi_direct.matches(reply, MAC.upper())
    assert wifi_direct.matches(reply, MAC.replace(":", "-"))
    assert not wifi_direct.matches(reply, "40:98:ad:39:e6:83")
    assert not wifi_direct.matches(_reply("40:98:ad:39:e6:83@fe80::1"), MAC)
    assert not wifi_direct.matches(reply, "not a mac")


# --- state file ------------------------------------------------------------- #


def _entry(udid=UDID):
    return wifi_direct._load()["devices"][udid]


def test_remember_round_trips_through_the_state_file():
    wifi_direct.remember(UDID, MAC.upper().replace(":", "-"), "iPhone X")

    data = json.loads(paths.wifi_devices_file().read_text(encoding="utf-8"))
    assert data["version"] == 1
    entry = data["devices"][UDID]
    assert entry["wifi_mac"] == MAC and entry["last_ip"] is None and entry["name"] == "iPhone X"
    assert entry["seen"].endswith("+00:00")
    assert wifi_direct.remembered() == [UDID]

    wifi_direct._set_last_ip(UDID, PHONE)
    wifi_direct.remember(UDID, MAC)  # same phone again: address and name kept
    assert _entry()["last_ip"] == PHONE and _entry()["name"] == "iPhone X"

    wifi_direct.remember(UDID, "40:98:ad:39:e6:99")  # new MAC: the old address is stale
    assert _entry()["last_ip"] is None


def test_an_unusable_mac_is_not_remembered():
    wifi_direct.remember(UDID, None)
    wifi_direct.remember(UDID, "garbage")
    assert not paths.wifi_devices_file().exists()


def test_a_damaged_state_file_is_moved_aside_not_emptied():
    path = paths.wifi_devices_file()
    path.write_text("{not json", encoding="utf-8")

    assert wifi_direct.remembered() == []
    assert not path.exists()
    aside = list(path.parent.glob("wifi-devices.json.corrupt-*"))
    assert len(aside) == 1 and aside[0].read_text(encoding="utf-8") == "{not json"


@pytest.fixture
def saves(monkeypatch):
    calls: list = []
    real = wifi_direct._save

    def spy(state):
        calls.append(json.loads(json.dumps(state)))
        real(state)

    monkeypatch.setattr(wifi_direct, "_save", spy)
    return calls


def test_an_unchanged_phone_seen_today_is_not_rewritten(saves):
    wifi_direct.remember(UDID, MAC, "iPhone X")
    wifi_direct.remember(UDID, MAC, "iPhone X")
    wifi_direct.remember(UDID, MAC)  # no name given: the stored one stands
    assert len(saves) == 1

    state = wifi_direct._load()
    state["devices"][UDID]["seen"] = "2026-01-01T00:00:00+00:00"
    wifi_direct._save(state)
    saves.clear()
    wifi_direct.remember(UDID, MAC, "iPhone X")
    assert len(saves) == 1, "a day-old note is refreshed"


def test_an_unreadable_state_file_is_never_overwritten(monkeypatch, saves):
    wifi_direct.remember(OTHER, "aa:bb:cc:dd:ee:ff")
    saves.clear()
    real = wifi_direct.paths.wifi_devices_file

    class Unreadable(type(real())):
        def read_text(self, *args, **kwargs):
            raise PermissionError("sharing violation")

    monkeypatch.setattr(wifi_direct.paths, "wifi_devices_file", lambda: Unreadable(real()))
    wifi_direct.remember(UDID, MAC)
    wifi_direct._set_last_ip(OTHER, PHONE)
    assert saves == []
    monkeypatch.setattr(wifi_direct.paths, "wifi_devices_file", real)
    assert wifi_direct.remembered() == [OTHER]


def test_a_stored_entry_that_is_not_a_dict_is_replaced():
    wifi_direct._save({"version": 1, "devices": {UDID: "junk", OTHER: 7}})
    wifi_direct.remember(UDID, MAC)
    wifi_direct._set_last_ip(OTHER, PHONE)  # nothing to update; must not raise
    assert _entry()["wifi_mac"] == MAC
    assert wifi_direct.remembered() == [UDID]


def test_the_state_lock_serializes_writers_without_losing_a_phone(monkeypatch):
    # Widen the read-modify-write window so unlocked writers would lose updates.
    real_read = wifi_direct._read

    def slow_read():
        state = real_read()
        time.sleep(0.01)
        return state

    monkeypatch.setattr(wifi_direct, "_read", slow_read)
    macs = [f"40:98:ad:39:e6:{i:02x}" for i in range(12)]
    udids = [f"{i:040x}" for i in range(12)]
    threads = [
        threading.Thread(target=wifi_direct.remember, args=(u, m)) for u, m in zip(udids, macs)
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(wifi_direct.remembered()) == sorted(udids)


def test_a_busy_lock_skips_the_update_instead_of_waiting(monkeypatch, saves):
    monkeypatch.setattr(wifi_direct, "LOCK_WAIT", 0.05)
    assert wifi_direct._THREAD_LOCK.acquire()
    try:
        start = time.monotonic()
        wifi_direct.remember(UDID, MAC)
        assert time.monotonic() - start < 0.5
    finally:
        wifi_direct._THREAD_LOCK.release()
    assert saves == []


_HOLD_LOCK = """
import sys, time
from ipaside_engine import wifi_direct
with wifi_direct._locked():
    print("held", flush=True)
    sys.stdin.readline()
"""


def test_another_process_holding_the_lock_makes_the_writer_skip(monkeypatch, saves):
    import os
    import subprocess
    import sys
    from pathlib import Path

    monkeypatch.setattr(wifi_direct, "LOCK_WAIT", 0.2)
    engine = Path(wifi_direct.__file__).resolve().parents[1]
    env = {**os.environ, "PYTHONPATH": str(engine)}
    holder = subprocess.Popen(
        [sys.executable, "-c", _HOLD_LOCK],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        env=env,
        text=True,
    )
    try:
        assert holder.stdout.readline().strip() == "held"
        start = time.monotonic()
        wifi_direct.remember(UDID, MAC)
        assert time.monotonic() - start < 1.0
        assert saves == [], "skipped, not waited for"
    finally:
        holder.communicate("\n", timeout=10)
    wifi_direct.remember(UDID, MAC)
    assert len(saves) == 1, "the lock is free again once the other process lets go"


# --- find ------------------------------------------------------------------- #


class _FakeSocket:
    """One UDP socket on a pretend LAN: ``phones`` maps an IP to the MAC it answers with.

    ``noise`` is put in front of the first answer: exceptions to raise from recvfrom,
    or (packet, address) datagrams to deliver.
    """

    def __init__(self, phones, noise=()):
        self.phones = phones
        self.noise = list(noise)
        self.sent: list[str] = []
        self.queue: list = []
        self.timeout = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def settimeout(self, value):
        self.timeout = value

    def sendto(self, packet, address):
        host, port = address
        assert port == 5353 and wifi_direct.SERVICE.split(".")[0].encode() in packet
        self.sent.append(host)
        if host in self.phones:
            query_id = struct.unpack_from("!H", packet)[0]
            reply = _reply(f"{self.phones[host]}@fe80::1", query_id)
            self.queue.append((reply, (host, 5353)))

    def recvfrom(self, size):
        if self.queue:
            if self.noise:
                item = self.noise.pop(0)
                if isinstance(item, BaseException):
                    raise item
                return item
            return self.queue.pop(0)
        time.sleep(self.timeout)
        raise socket.timeout()


@pytest.fixture
def lan(monkeypatch):
    def install(phones, last_ip=None, noise=()):
        sock = _FakeSocket(phones, noise)
        monkeypatch.setattr(wifi_direct, "_open_socket", lambda: sock)
        monkeypatch.setattr(wifi_direct, "_primary_address", lambda: PC)
        monkeypatch.setattr(wifi_direct, "LAST_IP_TIMEOUT", 0.2)
        monkeypatch.setattr(wifi_direct, "SWEEP_WINDOW", 0.4)
        wifi_direct.remember(UDID, MAC, "iPhone X")
        if last_ip:
            wifi_direct._set_last_ip(UDID, last_ip)
        return sock

    return install


def test_find_answers_from_the_last_address_without_a_sweep(lan):
    sock = lan({PHONE: MAC}, last_ip=PHONE)
    assert wifi_direct.find(UDID) == PHONE
    assert sock.sent == [PHONE]


def test_find_sweeps_when_the_last_address_is_silent_and_saves_the_new_one(lan):
    sock = lan({PHONE: MAC, "192.168.1.60": "aa:bb:cc:dd:ee:ff"}, last_ip="192.168.1.40")
    assert wifi_direct.find(UDID) == PHONE
    assert sock.sent[0] == "192.168.1.40"
    assert PC not in sock.sent, "never query this PC itself"
    assert len(sock.sent) == 1 + 253
    assert _entry()["last_ip"] == PHONE


def test_socket_errors_before_the_answer_do_not_end_the_sweep(lan):
    lan({PHONE: MAC}, noise=[ConnectionResetError(10054, "reset"), OSError(10040, "too long")])
    assert wifi_direct.find(UDID) == PHONE


def test_replies_with_another_id_source_or_port_are_ignored(lan, monkeypatch):
    monkeypatch.setattr(wifi_direct, "SWEEP_WINDOW", 0.2)
    wrong_id = (_reply(INSTANCE, query_id=0), (PHONE, 5353))
    unasked = (_reply(INSTANCE), ("10.9.9.9", 5353))
    wrong_port = (_reply(INSTANCE), (PHONE, 5354))
    lan({PHONE: "aa:bb:cc:dd:ee:ff"}, noise=[wrong_id, unasked, wrong_port])

    # Each claims the MAC, but with the wrong ID, from a host never asked, or from the
    # wrong port; the one correct answer is from a phone with another MAC.
    assert wifi_direct.find(UDID) is None
    assert _entry()["last_ip"] is None


def test_an_impostor_reply_with_the_right_id_from_an_unasked_host_is_ignored(lan, monkeypatch):
    monkeypatch.setattr(wifi_direct, "SWEEP_WINDOW", 0.2)
    sock = lan({"192.168.1.60": "aa:bb:cc:dd:ee:ff"})
    real_send = sock.sendto

    def send(packet, address):
        real_send(packet, address)
        if address[0] == "192.168.1.60":  # spoofed answer from a host never asked
            query_id = struct.unpack_from("!H", packet)[0]
            sock.queue.insert(0, (_reply(INSTANCE, query_id), ("10.9.9.9", 5353)))

    sock.sendto = send
    assert wifi_direct.find(UDID) is None
    assert _entry()["last_ip"] is None


def test_an_answer_from_the_right_host_but_not_port_5353_is_ignored(lan):
    sock = lan({}, last_ip=PHONE)
    real_send = sock.sendto

    def send(packet, address):
        real_send(packet, address)
        query_id = struct.unpack_from("!H", packet)[0]
        sock.queue.append((_reply(INSTANCE, query_id), (PHONE, 5354)))

    sock.sendto = send
    assert wifi_direct.find(UDID, sweep=False) is None


def test_a_last_address_off_the_current_networks_is_neither_asked_nor_kept(lan):
    sock = lan({PHONE: MAC}, last_ip="10.0.0.5")
    assert wifi_direct.find(UDID, sweep=False) is None
    assert sock.sent == []
    assert wifi_direct.find(UDID) == PHONE
    assert "10.0.0.5" not in sock.sent
    assert _entry()["last_ip"] == PHONE


def test_find_without_sweep_tries_only_the_last_address(lan):
    sock = lan({PHONE: MAC}, last_ip="192.168.1.40")
    assert wifi_direct.find(UDID, sweep=False) is None
    assert sock.sent == ["192.168.1.40"]


def test_find_gives_up_at_the_total_limit(lan, monkeypatch):
    monkeypatch.setattr(wifi_direct, "LAST_IP_TIMEOUT", 0.3)
    monkeypatch.setattr(wifi_direct, "SWEEP_WINDOW", 1.0)
    monkeypatch.setattr(wifi_direct, "TOTAL_LIMIT", 0.5)
    lan({"192.168.1.60": "aa:bb:cc:dd:ee:ff"}, last_ip="192.168.1.40")
    start = time.monotonic()
    assert wifi_direct.find(UDID) is None
    assert time.monotonic() - start < 0.7
    assert _entry()["last_ip"] == "192.168.1.40"


def test_find_knows_nothing_of_a_phone_never_remembered(monkeypatch):
    monkeypatch.setattr(wifi_direct, "_open_socket", lambda: pytest.fail("no socket"))
    assert wifi_direct.find(OTHER) is None


def test_locate_sweeps_at_most_once_per_interval(lan):
    sock = lan({})
    assert wifi_direct.locate(UDID) is None
    swept = len(sock.sent)
    assert swept == 253
    assert wifi_direct.locate(UDID) is None
    assert len(sock.sent) == swept, "no second sweep inside the interval"

    wifi_direct._swept[UDID] -= wifi_direct.SWEEP_INTERVAL
    sock.phones[PHONE] = MAC
    assert wifi_direct.locate(UDID) == PHONE


def test_locate_does_not_spend_the_sweep_when_the_last_address_answers(lan):
    lan({PHONE: MAC}, last_ip=PHONE)
    assert wifi_direct.locate(UDID) == PHONE
    assert UDID not in wifi_direct._swept


# --- the network to sweep --------------------------------------------------- #


@pytest.mark.parametrize(
    "address, expected",
    [
        ("192.168.1.20", "192.168.1.0/24"),
        ("10.1.2.3", "10.1.2.0/24"),
        ("172.16.5.5", "172.16.5.0/24"),
        ("8.8.8.8", None),
        ("100.74.213.78", None),  # Tailscale / CGNAT
        ("169.254.3.4", None),
        ("127.0.0.1", None),
        ("172.32.0.1", None),
        (None, None),
        ("junk", None),
    ],
)
def test_only_a_private_address_gives_a_network_to_sweep(address, expected):
    got = wifi_direct.network_of(address)
    assert (str(got) if got else None) == expected


def test_find_never_sweeps_off_a_private_network(lan, monkeypatch):
    sock = lan({PHONE: MAC}, last_ip=PHONE)
    monkeypatch.setattr(wifi_direct, "_primary_address", lambda: "100.74.213.78")
    assert wifi_direct.find(UDID) is None
    assert sock.sent == [], "not even the last address"


# --- remember from the USB paths -------------------------------------------- #


class _UsbClient:
    def __init__(self, paired=True, wifi_on=True):
        self.paired = paired
        self.wifi_on = wifi_on
        self.all_values = {"DeviceName": "iPhone X", "WiFiAddress": MAC.upper()}
        self.sets: list = []
        self.closed = False

    async def get_enable_wifi_connections(self):
        return self.wifi_on

    async def set_enable_wifi_connections(self, value):
        self.sets.append(value)

    async def close(self):
        self.closed = True


@pytest.fixture
def remembered_calls(monkeypatch):
    calls: list = []
    real = wifi_direct.remember

    def spy(*args):
        calls.append(args)
        real(*args)

    monkeypatch.setattr(wifi_direct, "remember", spy)
    return calls


def _usb_only(monkeypatch, client):
    from pymobiledevice3 import lockdown as pml

    async def create(**kwargs):
        assert kwargs["connection_type"] == "USB" and kwargs["autopair"] is False
        return client

    monkeypatch.setattr(pml, "create_using_usbmux", create)


def test_wifi_sync_remembers_the_phone_even_when_sync_was_already_on(monkeypatch, remembered_calls):
    client = _UsbClient(wifi_on=True)
    _usb_only(monkeypatch, client)
    asyncio.run(device._enable_wifi_sync(UDID))

    assert remembered_calls == [(UDID, MAC.upper(), "iPhone X")]
    assert client.sets == [] and client.closed
    assert wifi_direct.remembered() == [UDID]


def test_wifi_sync_does_not_remember_an_unpaired_phone(monkeypatch, remembered_calls):
    _usb_only(monkeypatch, _UsbClient(paired=False))
    asyncio.run(device._enable_wifi_sync(UDID))
    assert remembered_calls == []


@pytest.mark.parametrize("how", ["save fails", "remember raises"])
def test_a_failing_remember_still_turns_on_wifi_sync(monkeypatch, how):
    if how == "save fails":
        monkeypatch.setattr(wifi_direct, "_save", lambda state: (_ for _ in ()).throw(OSError("ro")))
    else:
        monkeypatch.setattr(wifi_direct, "remember", lambda *a: (_ for _ in ()).throw(OSError("x")))
    notes: list = []
    monkeypatch.setattr(device, "_announce", notes.append)
    client = _UsbClient(wifi_on=False)
    _usb_only(monkeypatch, client)
    asyncio.run(device._enable_wifi_sync(UDID))
    assert client.sets == [True] and client.closed
    assert notes and notes[0].startswith("Turned on Wi-Fi sync")


# --- lockdown.create -------------------------------------------------------- #


@pytest.fixture
def usbmux(monkeypatch):
    """usbmux that answers per transport with a client, or raises DeviceNotFoundError."""
    from pymobiledevice3 import lockdown as pml
    from pymobiledevice3.exceptions import DeviceNotFoundError

    tried: list = []

    def install(answers):
        async def create(serial=None, connection_type=None, **kwargs):
            tried.append(connection_type)
            answer = answers.get(connection_type)
            if answer is None:
                raise DeviceNotFoundError(serial)
            return answer

        monkeypatch.setattr(pml, "create_using_usbmux", create)
        return tried

    return install


@pytest.fixture
def direct(monkeypatch):
    calls: list = []

    def install(result):
        async def connect(udid):
            calls.append(udid)
            if isinstance(result, Exception):
                raise result
            return result

        monkeypatch.setattr(wifi_direct, "connect", connect)
        return calls

    return install


def test_create_falls_back_to_tcp_only_after_usb_then_any_fail(usbmux, direct):
    tried = usbmux({})
    calls = direct("tcp-client")
    wifi_direct.remember(UDID, MAC)

    assert asyncio.run(lockdown.create(UDID)) == "tcp-client"
    assert tried == ["USB", None] and calls == [UDID]


def test_create_never_tries_tcp_for_a_phone_never_remembered(usbmux, direct):
    usbmux({})
    calls = direct("tcp-client")
    with pytest.raises(device.DeviceError, match="is not connected"):
        asyncio.run(lockdown.create(OTHER))
    assert calls == []


def test_create_never_tries_tcp_when_usb_is_forced(usbmux, direct, monkeypatch):
    monkeypatch.setenv(lockdown.CONNECTION_ENV, "usb")
    usbmux({})
    calls = direct("tcp-client")
    wifi_direct.remember(UDID, MAC)
    with pytest.raises(device.DeviceError, match="over USB"):
        asyncio.run(lockdown.create(UDID))
    assert calls == []


def test_create_never_tries_tcp_when_the_caller_says_so(usbmux, direct):
    usbmux({})
    calls = direct("tcp-client")
    wifi_direct.remember(UDID, MAC)
    with pytest.raises(device.DeviceError, match="is not connected"):
        asyncio.run(lockdown.create(UDID, allow_wifi_direct=False))
    assert calls == []


def test_pairing_create_never_uses_wifi_direct(monkeypatch):
    seen: dict = {}

    async def create(serial=None, prefer_usb=True, allow_wifi_direct=True):
        seen["allow"] = allow_wifi_direct
        raise device.DeviceError("not connected")

    monkeypatch.setattr(lockdown, "create", create)
    with pytest.raises(pairing.PairingError):
        pairing._remote_pair_keys(UDID)
    assert seen == {"allow": False}


def test_create_uses_usb_first_and_remembers_the_phone(usbmux, direct, remembered_calls):
    client = _UsbClient()
    tried = usbmux({"USB": client})
    calls = direct("tcp-client")

    assert asyncio.run(lockdown.create(UDID)) is client
    assert tried == ["USB"] and calls == []
    assert remembered_calls == [(UDID, MAC.upper(), "iPhone X")]


def test_create_remembers_only_a_paired_phone_on_usb(usbmux, remembered_calls):
    usbmux({"USB": _UsbClient(paired=False)})
    asyncio.run(lockdown.create(UDID))
    usbmux({None: _UsbClient()})  # reached, but not over the cable
    asyncio.run(lockdown.create(UDID))
    assert remembered_calls == []


@pytest.mark.parametrize("how", ["save fails", "remember raises"])
def test_a_failing_remember_never_costs_the_usb_connection(usbmux, monkeypatch, how):
    if how == "save fails":
        monkeypatch.setattr(wifi_direct, "_save", lambda state: (_ for _ in ()).throw(OSError("ro")))
    else:
        monkeypatch.setattr(wifi_direct, "remember", lambda *a: (_ for _ in ()).throw(OSError("x")))
    client = _UsbClient()
    usbmux({"USB": client})
    assert asyncio.run(lockdown.create(UDID)) is client


def test_create_raises_the_unreachable_error_when_both_fail(usbmux, direct):
    usbmux({})
    direct(device.DeviceError("Device was not found on the local network."))
    wifi_direct.remember(UDID, MAC)
    with pytest.raises(device.DeviceError) as failure:
        asyncio.run(lockdown.create(UDID))
    message = str(failure.value)
    assert message.startswith(f"Device {UDID} is not connected.")
    assert "Wi-Fi direct was also tried: Device was not found on the local network." in message


def test_probe_reaches_a_remembered_phone_by_wifi_direct(usbmux, direct):
    class Client:
        closed = False

        async def close(self):
            Client.closed = True

    usbmux({})
    direct(Client())
    wifi_direct.remember(UDID, MAC)
    asyncio.run(lockdown.probe(UDID))
    assert Client.closed


# --- wifi_direct.connect ---------------------------------------------------- #

DEVICE_DER = b"the phone's certificate"
RECORD = {"HostID": "h", "DeviceCertificate": ssl.DER_cert_to_PEM_cert(DEVICE_DER).encode()}


class _Heartbeat:
    """The phone's heartbeat service: ``marcos`` Marcos, then silence until closed."""

    def __init__(self, marcos=3, interval=10, silent=False, stuck_send=False):
        self.sent: list = []
        self.closed = False
        self.silent = silent
        self.stuck_send = stuck_send
        self._marcos = [{"Command": "Marco", "Interval": interval}] * marcos

    async def recv_plist(self):
        while self.silent or not self._marcos:
            await asyncio.sleep(0.01)  # the next Marco is ten seconds away
        return self._marcos.pop()

    async def send_plist(self, message):
        if self.stuck_send and self.sent:
            await asyncio.Event().wait()
        self.sent.append(message)

    async def close(self):
        self.closed = True


class _Tls:
    def __init__(self, peer):
        self.peer = peer

    def getpeercert(self, binary_form=False):
        assert binary_form
        return self.peer


class _Writer:
    def __init__(self, peer):
        self.peer = peer

    def get_extra_info(self, name):
        assert name == "ssl_object"
        return None if self.peer is None else _Tls(self.peer)


class _Conn:
    """A service connection: TLS to ``peer`` (None: plaintext); reads wait until closed."""

    def __init__(self, peer=DEVICE_DER):
        self.writer = _Writer(peer)
        self.closed = asyncio.Event()

    async def recvall(self, size):
        from pymobiledevice3.exceptions import ConnectionTerminatedError

        await self.closed.wait()
        raise ConnectionTerminatedError()

    async def close(self):
        self.closed.set()


class _FakeClient:
    """What ``_open_session`` hands back: the heartbeat and teardown of the real one."""

    def __init__(self, heartbeat=None):
        self.heartbeat = heartbeat or _Heartbeat()
        self.started: list = []
        self.closed = False
        self.dropped = False
        self.requested_udid = UDID
        self._heartbeat = None
        self.torn: list = []

    async def start_lockdown_service(self, name):
        self.started.append(name)
        return self.heartbeat

    async def teardown(self, reason):
        self.dropped = True
        self.torn.append(reason)

    async def close(self):
        if self._heartbeat is not None:
            self._heartbeat.cancel()
            await asyncio.wait({self._heartbeat})
        await self.heartbeat.close()
        self.closed = True


@pytest.fixture
def tcp(monkeypatch):
    from pymobiledevice3 import pair_records

    seen: dict = {}

    def install(client, ip=PHONE, record=None):
        record = RECORD if record is None else record
        monkeypatch.setattr(wifi_direct, "find", lambda udid, sweep=True: ip)

        async def preferred(identifier, folder, usbmux_address=None):
            seen["record_for"] = (identifier, folder)
            return record

        async def open_session(host, udid, pair_record, der):
            seen["session"] = (host, udid, pair_record, der)
            if isinstance(client, Exception):
                raise client
            return client

        monkeypatch.setattr(pair_records, "get_preferred_pair_record", preferred)
        monkeypatch.setattr(wifi_direct, "_open_session", open_session)
        return seen

    return install


def _tasks_left():
    return [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]


def _run(coro, limit=5):
    """Run ``coro`` with a hard limit: a removed bound fails the test instead of hanging it."""

    async def bounded():  # in the main task, so ``_tasks_left`` sees no extra task
        async with asyncio.timeout(limit):
            return await coro

    return asyncio.run(bounded())


def test_connect_uses_the_stored_pair_record_and_keeps_answering_the_heartbeat(tcp):
    # Over the network lockdownd drops every service connection after its TLS
    # handshake unless the host answers the heartbeat (seen live on iOS 16.7).
    client = _FakeClient()
    seen = tcp(client)

    async def scenario():
        opened: list = []
        wifi_direct._attempt.set(opened)  # what wifi_operation does around an attempt
        got = await wifi_direct.connect(UDID)
        assert got is client and opened == [client]
        assert client.loop is asyncio.get_running_loop(), "where a cap tears it down"
        await asyncio.sleep(0.1)
        assert seen["session"] == (PHONE, UDID, RECORD, DEVICE_DER)
        assert seen["record_for"] == (UDID, paths.data_dir() / "lockdown")
        assert client.started == [wifi_direct.HEARTBEAT]
        assert client.heartbeat.sent == [{"Command": "Polo"}] * 3
        assert not client._heartbeat.done(), "still answering"
        await lockdown.close(got)
        assert client.heartbeat.closed and client.closed
        assert _tasks_left() == []

    asyncio.run(scenario())


def test_connect_refuses_without_a_device_certificate(tcp):
    seen = tcp(_FakeClient(), record={"HostID": "h"})
    with pytest.raises(device.DeviceError, match="no device certificate"):
        asyncio.run(wifi_direct.connect(UDID))
    assert "session" not in seen


def test_a_refusal_from_the_session_is_passed_on_unchanged(tcp):
    tcp(device.DeviceError("Refused the host: its certificate is not the paired phone's."))
    with pytest.raises(device.DeviceError, match="certificate is not the paired phone"):
        asyncio.run(wifi_direct.connect(UDID))


def test_a_silent_first_heartbeat_fails_within_the_bound_and_leaks_nothing(tcp, monkeypatch):
    monkeypatch.setattr(wifi_direct, "STEP_TIMEOUT", 0.2)
    client = _FakeClient(heartbeat=_Heartbeat(silent=True))
    tcp(client)

    async def scenario():
        start = time.monotonic()
        with pytest.raises(device.DeviceError, match="no answer to the first heartbeat"):
            await wifi_direct.connect(UDID)
        assert time.monotonic() - start < 1.0
        assert client.closed and _tasks_left() == []

    _run(scenario())


def test_connect_fails_plainly_when_the_phone_is_not_found(tcp):
    seen = tcp(_FakeClient(), ip=None)
    with pytest.raises(device.DeviceError, match="not found on the local network"):
        asyncio.run(wifi_direct.connect(UDID))
    assert "session" not in seen


def test_connect_fails_plainly_without_a_pair_record(tcp):
    seen = tcp(_FakeClient(), record={})
    with pytest.raises(device.DeviceError, match="no pair record"):
        asyncio.run(wifi_direct.connect(UDID))
    assert "session" not in seen


def test_a_stalled_pair_record_lookup_fails_within_the_bound(tcp, monkeypatch):
    # AMDS that never answers ReadPairRecord must not hold the engine before any cap.
    from pymobiledevice3 import pair_records

    seen = tcp(_FakeClient())
    monkeypatch.setattr(wifi_direct, "STEP_TIMEOUT", 0.2)

    async def stalled(identifier, folder, usbmux_address=None):
        await asyncio.Event().wait()

    monkeypatch.setattr(pair_records, "get_preferred_pair_record", stalled)
    start = time.monotonic()
    with pytest.raises(device.DeviceError, match="pair record"):
        _run(wifi_direct.connect(UDID))
    assert time.monotonic() - start < 1.0 and "session" not in seen


# --- the heartbeat watchdog ------------------------------------------------- #


def test_the_interval_the_phone_asks_for_is_capped():
    assert wifi_direct._interval({"Interval": 1000}) == wifi_direct.MAX_INTERVAL == 30
    assert wifi_direct._interval({}) == wifi_direct.DEFAULT_INTERVAL
    assert wifi_direct._interval({"Interval": "junk"}) == wifi_direct.DEFAULT_INTERVAL


def test_a_silent_heartbeat_tears_the_client_down_within_the_bound(monkeypatch):
    monkeypatch.setattr(wifi_direct, "HEARTBEAT_SLACK", 0.1)

    async def scenario():
        client = _FakeClient(heartbeat=_Heartbeat(silent=True))
        start = time.monotonic()
        await wifi_direct._heartbeat(client, client.heartbeat, 0.1)
        assert time.monotonic() - start < 1.0
        assert client.dropped and client.torn == ["the heartbeat stopped"]

    _run(scenario())


def test_a_polo_that_cannot_be_sent_tears_the_client_down(monkeypatch):
    monkeypatch.setattr(wifi_direct, "STEP_TIMEOUT", 0.1)

    async def scenario():
        client = _FakeClient(heartbeat=_Heartbeat(marcos=5, stuck_send=True))
        await asyncio.wait_for(wifi_direct._heartbeat(client, client.heartbeat, 10), 2)
        assert client.dropped

    _run(scenario())


# --- the pinned client itself ----------------------------------------------- #


class _Session:
    """The lockdown session socket of a pinned client: answers requests from a script."""

    def __init__(self, peer=DEVICE_DER):
        self.writer = _Writer(peer)
        self.closed = False

    async def close(self):
        self.closed = True


def _pinned(monkeypatch, version="16.7", udid=UDID, peer=DEVICE_DER, start_session=None):
    """A real PinnedTcpLockdownClient on a fake session; returns it and its requests."""
    _connection, client_class = wifi_direct._classes()
    client = client_class(
        _Session(peer),
        host_id="host",
        hostname=PHONE,
        identifier=UDID,
        pair_record=RECORD,
        pairing_records_cache_folder=paths.data_dir() / "lockdown",
        requested_udid=UDID,
        device_der=DEVICE_DER,
    )
    client.all_values = {"ProductVersion": version, "UniqueDeviceID": udid}
    requests: list = []

    async def request(name, options=None, verify_request=True):
        requests.append((name, options))
        if name == "StartSession":
            return start_session if start_session is not None else {"SessionID": "s"}
        if name == "GetValue":
            return {"Value": {"ProductVersion": version, "UniqueDeviceID": udid}}
        raise AssertionError(f"unexpected request {name}")

    monkeypatch.setattr(client, "_request", request)
    return client, requests


@pytest.mark.parametrize("version", ["6.0", "10.3"])
def test_old_ios_is_refused_before_anything_carries_the_pair_record(monkeypatch, version):
    client, requests = _pinned(monkeypatch, version=version)
    with pytest.raises(device.DeviceError, match="needs iOS 11"):
        asyncio.run(client.validate_pairing())
    assert requests == [], "no ValidatePair, no StartSession"


def test_a_pinned_session_with_the_right_phone_validates(monkeypatch):
    client, requests = _pinned(monkeypatch)
    assert asyncio.run(client.validate_pairing()) is True
    assert [name for name, _ in requests] == ["StartSession", "GetValue"]


@pytest.mark.parametrize(
    "kwargs, reason",
    [
        ({"peer": None}, "did not secure the connection"),
        ({"peer": b"someone else"}, "certificate is not the paired phone"),
        ({"udid": OTHER}, "a different device"),
    ],
    ids=["plaintext session", "certificate mismatch", "udid mismatch"],
)
def test_a_session_that_is_not_the_paired_phone_is_refused(monkeypatch, kwargs, reason):
    client, _requests = _pinned(monkeypatch, **kwargs)
    with pytest.raises(device.DeviceError, match=reason):
        asyncio.run(client.validate_pairing())


def test_a_dropped_session_is_never_reopened(monkeypatch):
    client, _requests = _pinned(monkeypatch)
    connection, _client_class = wifi_direct._classes()
    monkeypatch.setattr(connection, "create_using_tcp", lambda *a, **k: pytest.fail("no socket"))
    with pytest.raises(device.DeviceError, match="dropped"):
        asyncio.run(client.areestablish_connection())
    assert client.dropped


@pytest.fixture
def service_sockets(monkeypatch):
    connection, _client_class = wifi_direct._classes()
    opened: list = []

    def install(peer=DEVICE_DER):
        async def dial(host, port, keep_alive=True, ssl_context=None, **kwargs):
            conn = _Conn(peer)
            opened.append({"host": host, "keep_alive": keep_alive, "ssl": ssl_context, "conn": conn})
            return conn

        monkeypatch.setattr(connection, "create_using_tcp", dial)
        return opened

    return install


def test_service_connections_are_pinned_and_kept_alive(monkeypatch, service_sockets):
    opened = service_sockets()
    client, _requests = _pinned(monkeypatch)
    client._starting = "com.apple.afc"
    conn = asyncio.run(client.create_service_connection(49000, ssl_context="tls"))
    assert opened[0]["host"] == PHONE and opened[0]["keep_alive"] is True
    assert client.connections == [conn] and client.secured == {"com.apple.afc": True}


def test_a_service_with_the_wrong_certificate_is_refused_and_closed(monkeypatch, service_sockets):
    opened = service_sockets(peer=b"someone else")
    client, _requests = _pinned(monkeypatch)
    client._starting = "com.apple.afc"
    with pytest.raises(device.DeviceError, match="certificate is not the paired phone"):
        asyncio.run(client.create_service_connection(49000, ssl_context="tls"))
    assert opened[0]["conn"].closed.is_set() and client.connections == []


def test_a_service_without_tls_is_refused_before_any_socket(monkeypatch, service_sockets):
    opened = service_sockets()
    client, _requests = _pinned(monkeypatch)
    client._starting = "com.apple.mobile.installation_proxy"
    with pytest.raises(device.DeviceError, match="without TLS"):
        asyncio.run(client.create_service_connection(49000, ssl_context=None))
    assert opened == []


def test_a_service_that_strips_tls_is_refused_before_any_socket(monkeypatch, service_sockets):
    opened = service_sockets()
    client, _requests = _pinned(monkeypatch)
    client._starting = "com.apple.afc"
    with pytest.raises(device.DeviceError, match="without TLS"):
        asyncio.run(client.create_service_connection(49000, ssl_context="tls", strip_ssl=True))
    assert opened == [] and client.connections == []


def test_only_the_heartbeat_may_be_plaintext(monkeypatch, service_sockets):
    opened = service_sockets(peer=None)
    client, _requests = _pinned(monkeypatch)
    client._starting = wifi_direct.HEARTBEAT
    asyncio.run(client.create_service_connection(49000, ssl_context=None))
    assert len(opened) == 1 and client.secured == {wifi_direct.HEARTBEAT: False}


def test_teardown_makes_a_pending_service_read_fail(monkeypatch, service_sockets):
    from pymobiledevice3.exceptions import ConnectionTerminatedError

    service_sockets()
    client, _requests = _pinned(monkeypatch)
    client._starting = "com.apple.afc"

    async def scenario():
        conn = await client.create_service_connection(49000, ssl_context="tls")
        reading = asyncio.create_task(conn.recvall(4))
        await asyncio.sleep(0.01)
        await client.teardown("test")
        with pytest.raises(ConnectionTerminatedError):
            await asyncio.wait_for(reading, 1)
        assert client.dropped and client.service.closed

    asyncio.run(scenario())


def test_a_silent_service_with_a_live_heartbeat_fails_after_the_idle_read(monkeypatch):
    # The heartbeat keeps answering, so only the read deadline can end the wait. The
    # deadline is 100 times the Marco spacing and the watchdog 5 s: no race to lose
    # under load, and the only upper limit is ``_run``'s.
    from pymobiledevice3.exceptions import ConnectionTerminatedError

    monkeypatch.setattr(wifi_direct, "IDLE_READ", 1.0)
    connection, _client_class = wifi_direct._classes()
    client, _requests = _pinned(monkeypatch)

    class Writer(_Writer):
        def close(self):
            pass

        async def wait_closed(self):
            pass

        def is_closing(self):
            return True

    async def scenario():
        conn = connection(asyncio.StreamReader(), Writer(DEVICE_DER))
        conn.owner = client
        other = _Conn()
        client.connections += [conn, other]
        beat = _Heartbeat(marcos=0)

        async def answering():  # a Marco every 0.01 s, as a healthy phone does
            while True:
                await asyncio.sleep(0.01)
                beat._marcos.append({"Command": "Marco", "Interval": 0.05})

        alive = asyncio.create_task(answering())
        client._heartbeat = asyncio.create_task(wifi_direct._heartbeat(client, beat, 0.05))
        start = time.monotonic()
        with pytest.raises(ConnectionTerminatedError):
            await conn.recvall(4)
        assert time.monotonic() - start > 0.8, "ended by the read deadline, not earlier"
        assert client.dropped and other.closed.is_set() and client.service.closed
        assert len(beat.sent) >= 2, "the heartbeat was answering all along"
        alive.cancel()
        while not client._heartbeat.done():
            # Python 3.11's wait_for returns a result that finished in the same tick as
            # a cancel, swallowing it; the fake phone never fails, so cancel until it ends.
            client._heartbeat.cancel()
            await asyncio.sleep(0.01)
        await asyncio.gather(alive, return_exceptions=True)

    _run(scenario())


def test_close_ends_a_heartbeat_whose_cancel_lands_in_the_same_tick_as_a_marco(monkeypatch, capfd):
    # Python 3.11's wait_for swallows a cancel that arrives in the tick its read finishes
    # in; close() must still end the heartbeat quickly, before the phone's next Marco,
    # without the "heartbeat stopped" teardown, and with every connection closed.
    monkeypatch.setattr(wifi_direct, "STEP_TIMEOUT", 3.0)
    client, _requests = _pinned(monkeypatch)

    class Beat(_Heartbeat):
        def __init__(self):
            super().__init__(marcos=0)
            self.gate = None

        async def recv_plist(self):
            self.gate = gate = asyncio.Event()  # a Marco whenever the test sets it
            await gate.wait()
            return {"Command": "Marco", "Interval": 10}

    async def scenario():
        beat = Beat()
        other = _Conn()
        client.connections += [beat, other]
        client._heartbeat = asyncio.create_task(wifi_direct._heartbeat(client, beat, 10))
        await asyncio.sleep(0.05)
        beat.gate.set()  # the Marco is delivered in the tick close() cancels the task in
        start = time.monotonic()
        await client.close()
        assert time.monotonic() - start < 1.5, "well under STEP_TIMEOUT"
        assert client._heartbeat is None
        assert beat.closed and other.closed.is_set() and client.service.closed

    _run(scenario())
    assert "heartbeat stopped" not in capfd.readouterr().err
    assert not client.dropped


def test_an_idle_read_inside_the_heartbeat_still_closes_everything(monkeypatch):
    # Interval 30: the heartbeat's own read hits IDLE_READ first, and the teardown it
    # starts cancels the heartbeat task it runs under. The closing must survive that.
    monkeypatch.setattr(wifi_direct, "IDLE_READ", 0.2)
    connection, _client_class = wifi_direct._classes()
    client, _requests = _pinned(monkeypatch)

    class Writer(_Writer):
        def close(self):
            pass

        async def wait_closed(self):
            await asyncio.sleep(0.01)

        def is_closing(self):
            return True

    async def scenario():
        hb = connection(asyncio.StreamReader(), Writer(None))
        hb.owner = client
        other = _Conn()
        client.connections += [hb, other]

        class Beat:
            async def recv_plist(self):
                await hb.recvall(4)

            async def send_plist(self, message):
                pass

        client._heartbeat = asyncio.create_task(wifi_direct._heartbeat(client, Beat(), 30))
        await asyncio.wait({client._heartbeat}, timeout=2)
        await asyncio.sleep(0.2)
        assert client.dropped
        assert hb._closed and other.closed.is_set() and client.service.closed

    _run(scenario())


# --- the TCP session itself ------------------------------------------------- #


class _Dialed:
    def __init__(self):
        self.closed = False
        self.owner = None

    async def close(self):
        self.closed = True


@pytest.fixture
def session_parts(monkeypatch):
    from pymobiledevice3 import lockdown as pml

    connection, client_class = wifi_direct._classes()
    conn = _Dialed()
    seen: dict = {}

    def install(create):
        async def dial(host, port, keep_alive=True, **kwargs):
            seen["dial"] = (host, port, keep_alive)
            return conn

        monkeypatch.setattr(connection, "create_using_tcp", dial)
        monkeypatch.setattr(client_class, "create", create)
        return conn, seen

    return install


def test_the_session_never_pairs_and_keeps_its_records_in_the_data_folder(session_parts):
    async def create(service, **kwargs):
        create.kwargs = kwargs
        return "client"

    conn, seen = session_parts(create)
    assert asyncio.run(wifi_direct._open_session(PHONE, UDID, RECORD, DEVICE_DER)) == "client"
    assert seen["dial"] == (PHONE, 62078, True)
    kw = create.kwargs
    assert kw["autopair"] is False and kw["pair_record"] is RECORD and kw["hostname"] == PHONE
    assert kw["keep_alive"] is True and kw["requested_udid"] == UDID and kw["device_der"] == DEVICE_DER
    assert kw["pairing_records_cache_folder"] == paths.data_dir() / "lockdown"
    assert conn.owner == "client" and not conn.closed


def test_a_silent_peer_times_out_and_the_socket_is_closed(session_parts, monkeypatch):
    monkeypatch.setattr(wifi_direct, "STEP_TIMEOUT", 0.2)

    async def create(service, **kwargs):
        await asyncio.Event().wait()  # accepts the connection, never answers

    conn, _seen = session_parts(create)
    monkeypatch.setattr(wifi_direct, "find", lambda udid, sweep=True: PHONE)
    from pymobiledevice3 import pair_records

    async def preferred(identifier, folder, usbmux_address=None):
        return RECORD

    monkeypatch.setattr(pair_records, "get_preferred_pair_record", preferred)

    async def scenario():
        start = time.monotonic()
        with pytest.raises(device.DeviceError, match="no answer to StartSession"):
            await wifi_direct.connect(UDID)
        assert time.monotonic() - start < 1.0
        assert conn.closed and _tasks_left() == []

    _run(scenario())


def test_a_refused_session_closes_the_socket(session_parts):
    async def create(service, **kwargs):
        raise device.DeviceError("Refused the host")

    conn, _seen = session_parts(create)
    with pytest.raises(device.DeviceError, match="Refused"):
        asyncio.run(wifi_direct._open_session(PHONE, UDID, RECORD, DEVICE_DER))
    assert conn.closed


def test_cancelling_the_session_closes_the_socket(session_parts):
    async def create(service, **kwargs):
        await asyncio.Event().wait()

    conn, _seen = session_parts(create)

    async def scenario():
        task = asyncio.create_task(wifi_direct._open_session(PHONE, UDID, RECORD, DEVICE_DER))
        await asyncio.sleep(0.05)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert conn.closed

    asyncio.run(scenario())


# --- the operation boundary: cap and one retry ------------------------------ #


class _OpClient:
    def __init__(self, udid=UDID, dropped=False):
        self.requested_udid = udid
        self.dropped = dropped
        self.torn: list = []
        self.loop = asyncio.get_running_loop()

    async def teardown(self, reason):
        self.dropped = True
        self.torn.append(reason)


def _opened(client):
    """What ``connect`` does on success: the attempt learns about the client."""
    wifi_direct._attempt.get().append(client)
    return client


@pytest.fixture
def retry_clock(monkeypatch):
    monkeypatch.setattr(wifi_direct, "RETRY_PAUSE", 0.01)
    monkeypatch.setattr(wifi_direct, "RETRY_WINDOW", 0.2)
    found: dict = {UDID: PHONE}
    monkeypatch.setattr(wifi_direct, "find", lambda udid, sweep=True: found.get(udid))
    return found


@pytest.fixture(params=["async", "sync"])
def operation(request):
    """Make ``body(serial)`` a decorated public operation of either shape; returns a caller.

    The sync shape is what apps.py decorates: a function that runs its own loop.
    """

    def make(body, *, cap=5, retry=True):
        if request.param == "async":

            @wifi_direct.wifi_operation(cap=cap, retry=retry)
            async def op(ipa=None, serial=None):
                return await body(serial)

            return lambda *a, **k: asyncio.run(op(*a, **k))

        @wifi_direct.wifi_operation(cap=cap, retry=retry)
        def op(ipa=None, serial=None):
            return asyncio.run(body(serial))

        return op

    return make


def _drop():
    from pymobiledevice3.exceptions import ConnectionTerminatedError

    return ConnectionTerminatedError()


def test_a_drop_is_retried_once_on_a_new_connection(retry_clock, operation, capfd):
    calls: list = []

    async def body(serial):
        calls.append(serial)
        _opened(_OpClient(dropped=len(calls) == 1))
        if len(calls) == 1:
            raise _drop()
        return "done"

    assert operation(body)("app.ipa", UDID) == "done"
    assert calls == [UDID, UDID]
    assert "Wi-Fi connection dropped, retrying once" in capfd.readouterr().err


def test_without_retry_a_drop_surfaces_at_once(retry_clock, operation):
    calls: list = []

    async def body(serial):
        calls.append(serial)
        _opened(_OpClient(dropped=True))
        raise _drop()

    with pytest.raises(type(_drop())):
        operation(body, retry=False)("app.ipa", UDID)
    assert len(calls) == 1


def test_the_wait_asks_the_last_address_every_pause_and_sweeps_at_most_once(lan, monkeypatch):
    sock = lan({}, last_ip="192.168.1.40")  # the phone never answers
    monkeypatch.setattr(wifi_direct, "RETRY_PAUSE", 0.01)
    monkeypatch.setattr(wifi_direct, "RETRY_WINDOW", 0.5)
    monkeypatch.setattr(wifi_direct, "LAST_IP_TIMEOUT", 0.01)
    monkeypatch.setattr(wifi_direct, "SWEEP_WINDOW", 0.01)
    assert wifi_direct._found_again(UDID) is False
    assert sock.sent.count("192.168.1.40") >= 3, "asked again at every pause"
    assert sock.sent.count("192.168.1.41") == 1, "one sweep in the whole window"


def test_the_wait_does_not_sweep_when_the_inventory_swept_a_moment_ago(lan, monkeypatch):
    sock = lan({}, last_ip="192.168.1.40")
    wifi_direct._sweep_due(UDID)
    monkeypatch.setattr(wifi_direct, "RETRY_PAUSE", 0.01)
    monkeypatch.setattr(wifi_direct, "RETRY_WINDOW", 0.1)
    monkeypatch.setattr(wifi_direct, "LAST_IP_TIMEOUT", 0.01)
    assert wifi_direct._found_again(UDID) is False
    assert set(sock.sent) == {"192.168.1.40"}


def test_a_second_drop_surfaces(retry_clock, operation):
    calls: list = []

    async def body(serial):
        calls.append(serial)
        _opened(_OpClient(dropped=True))
        raise _drop()

    with pytest.raises(type(_drop())):
        operation(body)("app.ipa", UDID)
    assert len(calls) == 2


def test_a_refusal_is_never_retried(retry_clock, operation):
    calls: list = []

    async def body(serial):
        calls.append(serial)
        _opened(_OpClient())
        raise device.DeviceError("Refused the host: it offered com.apple.afc without TLS.")

    with pytest.raises(device.DeviceError, match="without TLS"):
        operation(body)("app.ipa", UDID)
    assert len(calls) == 1


def test_a_usb_failure_is_never_retried(retry_clock, operation):
    calls: list = []

    async def body(serial):
        calls.append(serial)  # no Wi-Fi client: this went over usbmux
        raise _drop()

    with pytest.raises(type(_drop())):
        operation(body)("app.ipa", UDID)
    assert len(calls) == 1


def test_the_wait_for_the_phone_is_bounded(retry_clock, operation):
    retry_clock.clear()  # the phone never answers again
    calls: list = []

    async def body(serial):
        calls.append(serial)
        _opened(_OpClient(dropped=True))
        raise _drop()

    start = time.monotonic()
    with pytest.raises(type(_drop())):
        operation(body)("app.ipa", UDID)
    assert time.monotonic() - start < 1.0 and len(calls) == 1


def test_the_overall_cap_aborts_a_wifi_operation_and_is_not_retried(retry_clock, operation):
    calls: list = []
    clients: list = []

    async def body(serial):
        calls.append(serial)
        clients.append(_opened(_OpClient()))
        await asyncio.Event().wait()

    start = time.monotonic()
    with pytest.raises(device.DeviceError, match="did not finish within 0.2 s"):
        operation(body, cap=0.2)("app.ipa", UDID)
    assert time.monotonic() - start < 1.5
    assert len(calls) == 1 and clients[0].torn


def test_the_cap_does_not_touch_a_usb_operation(retry_clock, operation):
    async def body(serial):
        await asyncio.sleep(0.3)  # no Wi-Fi client
        return "done"

    assert operation(body, cap=0.1)("app.ipa", UDID) == "done"

    async def failing(serial):
        await asyncio.sleep(0.3)
        raise _drop()

    with pytest.raises(type(_drop())):  # its own error, never the cap's
        operation(failing, cap=0.1)("app.ipa", UDID)


def test_a_sync_operation_runs_in_the_callers_thread():
    seen: list = []

    @wifi_direct.wifi_operation(cap=5, retry=True)
    def op(serial=None):
        seen.append(threading.current_thread())
        return serial

    assert op(UDID) == UDID and seen == [threading.current_thread()]


@pytest.fixture
def inventory(monkeypatch):
    rows = [[{"serial": UDID, "connection_type": "Network"}]]
    listed: list = []

    async def listing():
        listed.append(1)
        return rows[0]

    monkeypatch.setattr(device, "_list_devices_async", listing)
    return rows, listed


def test_the_retry_never_changes_the_target(retry_clock, operation, inventory):
    # serial None: phone A is chosen, drops mid-install and disappears; B becomes the
    # only phone. The retry must not go to B.
    rows, listed = inventory
    retry_clock.clear()
    retry_clock[OTHER] = "192.168.1.60"
    calls: list = []

    async def body(serial):
        calls.append(serial)
        _opened(_OpClient(udid=serial, dropped=True))
        rows[0] = [{"serial": OTHER, "connection_type": "USB"}]
        raise _drop()

    with pytest.raises(type(_drop())):
        operation(body)("app.ipa", None)
    assert calls == [UDID], "B received nothing"
    assert listed == [1], "the inventory is read once, before the first attempt"


def test_the_retry_reconnects_to_the_same_phone_when_it_is_back(retry_clock, operation, inventory):
    rows, listed = inventory
    calls: list = []

    async def body(serial):
        calls.append(serial)
        if len(calls) == 1:
            _opened(_OpClient(udid=serial, dropped=True))
            rows[0] = [{"serial": OTHER, "connection_type": "USB"}]
            raise _drop()
        return "installed"

    assert operation(body)("app.ipa", serial=None) == "installed"
    assert calls == [UDID, UDID] and listed == [1]


def test_the_decorator_keeps_the_name_and_signature():
    def install(ipa_path: str, serial: str | None = None, progress=None) -> None:
        """Install."""

    async def install_async(ipa_path: str, serial: str | None = None, progress=None) -> None:
        """Install."""

    for fn in (install, install_async):
        decorated = wifi_direct.wifi_operation(cap=1800, retry=True)(fn)
        assert decorated.__name__ == fn.__name__ and decorated.__doc__ == "Install."
        assert inspect.signature(decorated) == inspect.signature(fn)
    assert inspect.iscoroutinefunction(decorated)


def test_an_operation_without_a_serial_is_refused_at_import():
    with pytest.raises(TypeError, match="takes no serial"):
        wifi_direct.wifi_operation(cap=5, retry=True)(lambda udid: udid)


# --- listing and target resolution ------------------------------------------ #


@pytest.fixture
def listing(monkeypatch):
    from pymobiledevice3 import usbmux as pmd_usbmux

    class Mux:
        def __init__(self, serial):
            self.serial, self.connection_type, self.devid = serial, "USB", 3

    def install(serials, reachable=None, delay=0.0):
        lookups: list = []

        async def list_devices():
            return [Mux(s) for s in serials]

        monkeypatch.setattr(pmd_usbmux, "list_devices", list_devices)
        if reachable is not None:
            def locate(udid):
                lookups.append(udid)
                time.sleep(delay)
                return reachable.get(udid)

            monkeypatch.setattr(wifi_direct, "locate", locate)
        return lookups

    return install


def test_list_devices_adds_a_remembered_phone_that_answers(listing):
    wifi_direct.remember(UDID, MAC)
    wifi_direct.remember(OTHER, "aa:bb:cc:dd:ee:ff")
    lookups = listing([OTHER], {UDID: PHONE})

    assert device.list_devices() == [
        {"serial": OTHER, "connection_type": "USB", "device_id": 3},
        {"serial": UDID, "connection_type": "Network", "device_id": None},
    ]
    assert lookups == [UDID], "a phone usbmux lists is not looked for"


def test_list_devices_leaves_out_a_remembered_phone_that_is_silent(listing):
    wifi_direct.remember(UDID, MAC)
    listing([], {})
    assert device.list_devices() == []


def test_list_devices_looks_for_phones_at_the_same_time(listing):
    wifi_direct.remember(UDID, MAC)
    wifi_direct.remember(OTHER, "aa:bb:cc:dd:ee:ff")
    listing([], {}, delay=0.5)
    start = time.monotonic()
    assert device.list_devices() == []
    assert time.monotonic() - start < 0.8


def test_devices_finds_a_phone_never_seen_on_wifi_by_sweeping(listing, lan):
    # Plug once (remembered, no address yet), unplug: the listing still shows it.
    lan({PHONE: MAC})
    listing([])
    assert _entry()["last_ip"] is None
    assert device.list_devices() == [
        {"serial": UDID, "connection_type": "Network", "device_id": None}
    ]
    assert _entry()["last_ip"] == PHONE


def test_resolve_udid_with_no_udid_picks_the_remembered_phone(listing):
    wifi_direct.remember(UDID, MAC)
    listing([], {UDID: PHONE})
    assert sideload.resolve_udid(None) == UDID
