"""The Listen watcher's look for remembered phones (``device.watch_usbmux``).

Offline: usbmux is a scripted fake, the LAN lookup is a fake, time is a fake clock
where it matters. Each test names the behaviour it pins; the comments say which edit
of ``device.py`` it is there to catch.
"""

import asyncio
import threading
import time
import types

import pytest

from ipaside_engine import device, wifi_direct

UDID = "935cbbb9b82d25d15566e5939bcea5677b1c44ae"
OTHER = "0f1e2d3c4b5a69788796a5b4c3d2e1f009876543"
THIRD = "1111111111111111111111111111111111111111"
MAC = "40:98:ad:39:e6:82"
PHONE = "192.168.1.53"


class _MuxDev:
    def __init__(self, devid, serial, connection_type="USB"):
        self.devid = devid
        self.serial = serial
        self.connection_type = connection_type


class _Harness:
    """A scripted usbmux Listen socket; the test pushes ``add`` / ``remove`` updates."""

    def __init__(self):
        self.frames: list[dict] = []
        self.stop = threading.Event()
        self.ops: asyncio.Queue = asyncio.Queue()
        self.task: asyncio.Task | None = None

    async def _create_mux(self):
        ops = self.ops

        class Mux:
            def __init__(self):
                self.devices = []

            async def listen(self):
                return

            async def receive_device_state_update(self):
                kind, payload = await ops.get()
                if kind == "add":
                    self.devices.append(payload)
                else:
                    self.devices = [d for d in self.devices if d.devid != payload]

            async def close(self):
                return

        return Mux()

    async def start(self):
        self.task = asyncio.create_task(
            device.watch_usbmux(
                self.frames.append,
                self.stop,
                create_mux=self._create_mux,
                reconnect_wait=0.01,
            )
        )

    async def push(self, kind, payload=None):
        await self.ops.put((kind, payload))

    async def settle(self, turns=60):
        """Let the watcher and the tasks it started run until they are idle."""
        for _ in range(turns):
            await asyncio.sleep(0)

    async def finish(self):
        self.stop.set()
        await asyncio.wait_for(self.task, 2)

    def rows(self):
        if not self.frames:
            return None
        return [(e["serial"], e["connection_type"]) for e in self.frames[-1]["data"]]


def _run(scenario):
    """Run ``scenario(harness)``; the watcher is always stopped, even on a failed check."""

    async def main():
        h = _Harness()
        await h.start()
        try:
            await scenario(h)
        finally:
            h.stop.set()
        await h.finish()

    asyncio.run(asyncio.wait_for(main(), 10))


async def _until(check, timeout=3.0):
    deadline = time.monotonic() + timeout
    while not check():
        assert time.monotonic() < deadline, "timed out"
        await asyncio.sleep(0.005)


def _network(udid):
    return {"serial": udid, "connection_type": "Network", "device_id": None}


@pytest.fixture
def clock(monkeypatch):
    """A clock the test moves by hand, in place of ``device.time`` only."""
    now = [1000.0]
    monkeypatch.setattr(device, "time", types.SimpleNamespace(monotonic=lambda: now[0]))
    return now


# --- 7: a detach during a slow lookup is looked at again --------------------- #


def test_a_detach_during_a_slow_lookup_gets_a_rerun(monkeypatch):
    # Catches: look_for_direct returning after one pass (the queued look is lost, so
    # the phone that was on the cable waits for the 60 s recheck).

    calls: list[set] = []
    gates: list = []

    async def direct_rows(listed):
        calls.append(set(listed))
        gate = asyncio.Event()
        gates.append(gate)
        await gate.wait()
        return [] if UDID in listed else [_network(UDID)]

    monkeypatch.setattr(device, "_direct_rows", direct_rows)

    async def scenario(h):
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await _until(lambda: len(calls) == 1)
        assert calls[0] == {UDID}, "the first look ran while the phone was on the cable"
        await h.push("remove", 7)
        await _until(lambda: h.rows() == [])
        assert len(calls) == 1, "the slow look is still running; the detach only queues one"
        gates[0].set()
        await _until(lambda: len(calls) == 2)
        assert calls[1] == set(), "the rerun sees the phone detached"
        gates[1].set()
        await _until(lambda: h.rows() == [(UDID, "Network")])

    _run(scenario)


def test_many_updates_during_one_slow_lookup_cost_one_rerun(monkeypatch):
    # Catches: a rerun per queued update (the queue must collapse to a single flag).
    calls: list[int] = []
    gates: list = []

    async def direct_rows(listed):
        calls.append(len(listed))
        gate = asyncio.Event()
        gates.append(gate)
        await gate.wait()
        return []

    monkeypatch.setattr(device, "_direct_rows", direct_rows)

    async def scenario(h):
        await h.push("add", _MuxDev(1, UDID, "USB"))
        await _until(lambda: len(calls) == 1)
        for devid, serial in ((2, OTHER), (3, THIRD)):
            await h.push("add", _MuxDev(devid, serial, "USB"))
        await _until(lambda: h.rows() is not None and len(h.rows()) == 3)
        gates[0].set()
        await _until(lambda: len(calls) == 2)
        gates[1].set()
        await h.settle()
        assert calls == [1, 3], "one rerun, which sees all three phones"

    _run(scenario)


# --- 7: the first look comes after the first usbmux update ------------------- #


def test_no_look_before_the_first_usbmux_update(monkeypatch):
    # Catches: look() started when the watcher starts (before usb_rows is known).
    calls: list[set] = []

    async def direct_rows(listed):
        calls.append(set(listed))
        return []

    monkeypatch.setattr(device, "_direct_rows", direct_rows)

    async def scenario(h):
        await h.settle()
        await asyncio.sleep(0.1)
        assert calls == [], "no lookup before usbmux's first update"
        assert h.frames == []
        await h.push("add", _MuxDev(7, OTHER, "USB"))
        await _until(lambda: len(calls) == 1)
        assert calls[0] == {OTHER}, "the first look knows what usbmux lists"

    _run(scenario)


def test_a_plugged_in_phone_is_never_published_as_network_first(monkeypatch):
    # Catches: an early look that publishes the remembered phone as Network before its
    # USB row arrives (and burns its sweep budget on a phone that is on the cable).
    wifi_direct.remember(UDID, MAC)
    asked: list[str] = []

    def locate(udid):
        asked.append(udid)
        return PHONE

    monkeypatch.setattr(wifi_direct, "locate", locate)

    async def scenario(h):
        await h.settle()
        await asyncio.sleep(0.1)
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await _until(lambda: h.rows() == [(UDID, "USB")])
        await h.settle()
        assert h.rows() == [(UDID, "USB")]
        assert asked == [], "a phone usbmux lists is not looked for"
        for frame in h.frames:
            assert [e["connection_type"] for e in frame["data"]] == ["USB"], frame

    _run(scenario)


# --- 7: file I/O from async code runs in a thread ---------------------------- #


def test_remember_runs_off_the_event_loop(monkeypatch):
    # Catches: wifi_direct.remember (a file write under a lock) called directly on the
    # loop thread.
    from pymobiledevice3 import lockdown as pmd_lockdown

    threads: dict[str, int] = {}

    class Client:
        paired = True
        all_values = {"WiFiAddress": MAC, "DeviceName": "Test iPhone"}

        async def get_enable_wifi_connections(self):
            return True

        async def close(self):
            return

    async def fake_create(serial=None, connection_type=None, **kwargs):
        return Client()

    def fake_remember(udid, wifi_mac, name=None):
        threads["remember"] = threading.get_ident()

    async def direct_rows(listed):
        return []

    monkeypatch.setattr(pmd_lockdown, "create_using_usbmux", fake_create)
    monkeypatch.setattr(wifi_direct, "remember", fake_remember)
    monkeypatch.setattr(device, "_direct_rows", direct_rows)

    async def scenario(h):
        loop_thread = threading.get_ident()
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await _until(lambda: "remember" in threads)
        assert threads["remember"] != loop_thread

    _run(scenario)


# --- 11b: GRACE -------------------------------------------------------------- #


def test_grace_is_three_minutes():
    assert device.GRACE == 180.0


def test_a_silent_phone_stays_listed_for_grace_then_goes(monkeypatch, clock):
    # Catches: dropping the row on the first miss; a grace shorter than GRACE; a row
    # that is never removed; `<=` in place of `<` at exactly GRACE.
    reachable = {UDID: True}
    looked: list[int] = []

    async def direct_rows(listed):
        looked.append(1)
        return [_network(UDID)] if reachable.get(UDID) and UDID not in listed else []

    monkeypatch.setattr(device, "_direct_rows", direct_rows)

    async def look_at(h, seconds, devid):
        """Move the clock to ``seconds`` after the last answer, then one more usbmux update."""
        clock[0] = 1000.0 + seconds
        before = len(looked)
        await h.push("add", _MuxDev(devid, f"dev{devid}", "USB"))
        await _until(lambda: len(looked) == before + 1)
        await h.settle()

    async def scenario(h):
        await h.push("add", _MuxDev(1, OTHER, "USB"))
        await _until(lambda: h.rows() == [(OTHER, "USB"), (UDID, "Network")])
        reachable[UDID] = False  # the last answer was at clock 1000
        await look_at(h, device.GRACE - 1, 2)
        assert (UDID, "Network") in h.rows(), "kept just inside the grace"
        await look_at(h, device.GRACE, 3)
        assert (UDID, "Network") not in h.rows(), "removed at GRACE"
        reachable[UDID] = True
        await look_at(h, device.GRACE + 5, 4)
        assert (UDID, "Network") in h.rows(), "an answer brings it back"

    _run(scenario)


def test_an_answer_restarts_the_grace(monkeypatch, clock):
    # Catches: the clock being stamped once (first find) instead of at the last find.
    reachable = {UDID: True}
    looked: list[int] = []

    async def direct_rows(listed):
        looked.append(1)
        return [_network(UDID)] if reachable.get(UDID) and UDID not in listed else []

    monkeypatch.setattr(device, "_direct_rows", direct_rows)

    async def update(h, devid):
        before = len(looked)
        await h.push("add", _MuxDev(devid, f"dev{devid}", "USB"))
        await _until(lambda: len(looked) == before + 1)
        await h.settle()

    async def scenario(h):
        await h.push("add", _MuxDev(1, OTHER, "USB"))
        await _until(lambda: h.rows() == [(OTHER, "USB"), (UDID, "Network")])
        clock[0] = 1000.0 + 150
        await update(h, 2)  # answered again at +150
        reachable[UDID] = False
        clock[0] = 1000.0 + 150 + 100  # 250 s after the first answer, 100 s after the last
        await update(h, 3)
        assert (UDID, "Network") in h.rows()

    _run(scenario)


def test_a_failed_lookup_keeps_what_was_shown_and_the_queued_look_still_runs(monkeypatch):
    # Catches: an exception in a look wiping the rows, or ending the look task so the
    # look queued behind it never runs.
    state = {"fail": False, "calls": 0}
    gate = asyncio.Event()

    async def direct_rows(listed):
        state["calls"] += 1
        if state["fail"]:
            await gate.wait()
            raise OSError("network down")
        return [_network(UDID)]

    monkeypatch.setattr(device, "_direct_rows", direct_rows)

    async def scenario(h):
        await h.push("add", _MuxDev(1, OTHER, "USB"))
        await _until(lambda: h.rows() == [(OTHER, "USB"), (UDID, "Network")])
        state["fail"] = True
        await h.push("add", _MuxDev(2, THIRD, "USB"))
        await _until(lambda: state["calls"] == 2)
        await h.push("add", _MuxDev(3, "dev3", "USB"))  # queued behind the failing look
        await _until(lambda: len(h.rows()) == 4)
        gate.set()
        await _until(lambda: state["calls"] == 3)
        await h.settle()
        assert (UDID, "Network") in h.rows(), "kept: a failed look changes nothing"
        assert h.task is not None and not h.task.done()

    _run(scenario)


# --- 11b: no extra row for a phone usbmux lists ------------------------------ #


def test_a_phone_usbmux_lists_gets_no_network_row(monkeypatch):
    # Catches: _merged not dropping a kept (grace) row once usbmux lists the phone, and
    # _direct_rows looking for a phone that usbmux lists.
    wifi_direct.remember(UDID, MAC)
    asked: list[str] = []

    def locate(udid):
        asked.append(udid)
        return PHONE

    monkeypatch.setattr(wifi_direct, "locate", locate)

    async def scenario(h):
        await h.push("add", _MuxDev(8, OTHER, "USB"))
        await _until(lambda: h.rows() == [(OTHER, "USB"), (UDID, "Network")])
        assert asked == [UDID]
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await _until(lambda: h.rows() == [(OTHER, "USB"), (UDID, "USB")])
        await h.settle()
        await asyncio.sleep(0.1)
        for frame in h.frames:
            serials = [e["serial"] for e in frame["data"]]
            assert len(serials) == len(set(serials)), frame
        assert asked == [UDID], "not looked for again while usbmux lists it"
        assert h.rows() == [(OTHER, "USB"), (UDID, "USB")]

    _run(scenario)


def test_a_phone_usbmux_lists_over_wifi_gets_no_second_row(monkeypatch):
    # Same phone, usbmux sees it as Network too: still one row, usbmux's.
    wifi_direct.remember(UDID, MAC)
    monkeypatch.setattr(wifi_direct, "locate", lambda udid: PHONE)

    async def scenario(h):
        await h.push("add", _MuxDev(9, UDID, "Network"))
        await _until(lambda: h.rows() == [(UDID, "Network")])
        await h.settle()
        await asyncio.sleep(0.1)
        assert [e["device_id"] for e in h.frames[-1]["data"]] == [9]
        for frame in h.frames:
            assert len(frame["data"]) == 1, frame

    _run(scenario)


# --- 11b+: a remembered phone usbmux listed as Network is kept after it detaches ---- #


def _silent_lan(monkeypatch):
    """A LAN that never answers; ``asked`` lists the phones looked for."""
    asked: list[str] = []

    def locate(udid):
        asked.append(udid)
        return None

    monkeypatch.setattr(wifi_direct, "locate", locate)
    return asked


def test_a_network_phone_that_leaves_usbmux_is_kept_for_grace_then_goes(monkeypatch, clock):
    # Catches: the row dropped the moment usbmux stops listing it (before discovery
    # has answered), a grace other than GRACE, and a row that is never removed.
    wifi_direct.remember(UDID, MAC)
    asked = _silent_lan(monkeypatch)

    async def next_update(h, devid, calls_before):
        await h.push("add", _MuxDev(devid, f"dev{devid}", "USB"))
        await _until(lambda: len(asked) > calls_before)
        await asyncio.sleep(0.05)

    async def scenario(h):
        await h.push("add", _MuxDev(9, UDID, "Network"))
        await _until(lambda: h.rows() == [(UDID, "Network")])
        await h.push("remove", 9)  # the LAN does not answer: discovery cannot save it
        await _until(lambda: len(asked) >= 1)
        await asyncio.sleep(0.05)
        assert h.rows() == [(UDID, "Network")], "kept at once, not dropped before the look"
        clock[0] += device.GRACE - 1
        await next_update(h, 1, len(asked))
        assert (UDID, "Network") in h.rows(), "kept just inside the grace"
        clock[0] += 1  # exactly GRACE after usbmux last listed it
        await next_update(h, 2, len(asked))
        assert (UDID, "Network") not in h.rows(), "removed at GRACE"

    _run(scenario)


def test_a_usb_only_detach_is_not_kept(monkeypatch, clock):
    # Catches: keeping every vanished row, not only the ones listed as Network.
    wifi_direct.remember(UDID, MAC)
    asked = _silent_lan(monkeypatch)

    async def scenario(h):
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await _until(lambda: h.rows() == [(UDID, "USB")])
        await h.push("remove", 7)
        await _until(lambda: h.rows() == [] and len(asked) >= 1)
        await asyncio.sleep(0.1)
        assert h.rows() == []

    _run(scenario)


def test_a_phone_never_remembered_is_not_kept_after_a_network_detach(monkeypatch, clock):
    # Catches: dropping the "remembered" test (the LAN lookup can never find such a
    # phone, so keeping its row would only show a ghost for GRACE).
    asked = _silent_lan(monkeypatch)

    async def scenario(h):
        await h.push("add", _MuxDev(9, OTHER, "Network"))
        await _until(lambda: h.rows() == [(OTHER, "Network")])
        await h.push("remove", 9)
        await _until(lambda: h.rows() == [])
        await asyncio.sleep(0.1)
        assert h.rows() == [] and asked == []

    _run(scenario)


# --- no worker thread outlives the loop ------------------------------------- #


def test_a_watcher_that_ends_without_stop_does_not_hold_the_loop_open():
    # Catches: _wait_until_stopped as one open-ended stop.wait in a pool thread, which
    # asyncio.run's shutdown then waits for (a cancelled watcher, a failed test).
    stop = threading.Event()

    async def main():
        h = _Harness()
        h.stop = stop
        await h.start()
        await h.settle()
        h.task.cancel()
        try:
            await h.task
        except asyncio.CancelledError:
            pass

    runner = threading.Thread(target=lambda: asyncio.run(main()), daemon=True)
    try:
        runner.start()
        runner.join(5)
        assert not runner.is_alive(), "asyncio.run did not return: a pool thread is still waiting"
    finally:
        stop.set()  # lets a stuck worker end so the test process can exit
        runner.join(2)


# --- a phone that was on the cable is forgotten as a direct row --------------- #


def test_usb_attach_then_detach_leaves_no_network_ghost(monkeypatch, clock):
    # Catches: publish() leaving the direct row and its stamp in place while usbmux
    # lists the phone over USB, so the unplug brings it back as Network until GRACE.
    wifi_direct.remember(UDID, MAC)
    answers = {"on": True}

    def locate(udid):
        return PHONE if answers["on"] else None

    monkeypatch.setattr(wifi_direct, "locate", locate)

    async def scenario(h):
        await h.push("add", _MuxDev(1, OTHER, "USB"))
        await _until(lambda: h.rows() == [(OTHER, "USB"), (UDID, "Network")])  # direct find
        answers["on"] = False  # the LAN is silent from now on
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await _until(lambda: h.rows() == [(OTHER, "USB"), (UDID, "USB")])
        await h.push("remove", 7)
        await _until(lambda: h.rows() == [(OTHER, "USB")])
        await h.settle()
        await asyncio.sleep(0.1)
        assert h.rows() == [(OTHER, "USB")], "no Network row after a deliberate unplug"
        for frame in h.frames[-2:]:
            assert (UDID, "Network") not in [(e["serial"], e["connection_type"]) for e in frame["data"]]

    _run(scenario)


def test_a_network_row_that_goes_while_the_phone_is_on_usb_is_not_kept(monkeypatch, clock):
    # usbmux lists the phone over Network and USB, then drops the Network entry only;
    # the later unplug must not bring a Network row back.
    wifi_direct.remember(UDID, MAC)
    monkeypatch.setattr(wifi_direct, "locate", lambda udid: None)

    async def scenario(h):
        await h.push("add", _MuxDev(9, UDID, "Network"))
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await _until(lambda: (UDID, "USB") in (h.rows() or []))
        await h.push("remove", 9)  # the Network entry goes, the cable stays
        await h.settle()
        await h.push("remove", 7)
        await _until(lambda: h.rows() == [])
        await h.settle()
        await asyncio.sleep(0.1)
        assert h.rows() == []

    _run(scenario)
