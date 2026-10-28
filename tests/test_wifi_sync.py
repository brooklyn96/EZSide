"""Tests for turning on Wi-Fi sync when a phone is plugged in while the engine runs.

While ``EnableWifiConnections`` is off the phone does not advertise itself over the
network, so it disappears the moment the cable comes out. The watcher flips that
switch once per attach, over USB only, without ever holding up the ``devices`` events
or dying because a phone was locked.
"""

import asyncio
import threading

import pytest

from ipaside_engine import device

UDID = "935cbbb9b82d25d15566e5939bcea5677b1c44ae"
OTHER = "0f1e2d3c4b5a69788796a5b4c3d2e1f009876543"


class _MuxDev:
    def __init__(self, devid, serial, connection_type="USB"):
        self.devid = devid
        self.serial = serial
        self.connection_type = connection_type


class _Client:
    def __init__(self, enabled=False, set_error=None):
        self.enabled = enabled
        self.set_error = set_error
        self.sets: list[bool] = []
        self.all_values = {"DeviceName": "Test iPhone"}
        self.closed = False

    async def get_enable_wifi_connections(self):
        return self.enabled

    async def set_enable_wifi_connections(self, value):
        if self.set_error is not None:
            raise self.set_error
        self.sets.append(value)
        self.enabled = value

    async def close(self):
        self.closed = True


class _Harness:
    """A scripted usbmux Listen socket plus a fake lockdown, driven by the test."""

    def __init__(self, monkeypatch, client_factory=None):
        self.frames: list[dict] = []
        self.notes: list[str] = []
        self.creates: list[dict] = []
        self.clients: list[_Client] = []
        self.client_factory = client_factory or (lambda: _Client(enabled=False))
        self.stop = threading.Event()
        self.ops: asyncio.Queue = asyncio.Queue()
        self.muxes: list = []

        from pymobiledevice3 import lockdown as pmd_lockdown

        async def fake_create(serial=None, connection_type=None, **kwargs):
            self.creates.append({"serial": serial, "connection_type": connection_type})
            client = self.client_factory()
            self.clients.append(client)
            return client

        monkeypatch.setattr(pmd_lockdown, "create_using_usbmux", fake_create)
        monkeypatch.setattr(device, "_announce", self.notes.append)

    def _make_mux(self):
        ops = self.ops

        class Mux:
            def __init__(self):
                self.devices = []
                self.closed = asyncio.Event()

            async def listen(self):
                return

            async def receive_device_state_update(self):
                closed = asyncio.create_task(self.closed.wait())
                got = asyncio.create_task(ops.get())
                done, pending = await asyncio.wait(
                    {closed, got}, return_when=asyncio.FIRST_COMPLETED
                )
                for task in pending:
                    task.cancel()
                if self.closed.is_set() and got not in done:
                    raise OSError("closed")
                kind, payload = got.result()
                if kind == "add":
                    self.devices.append(payload)
                elif kind == "remove":
                    self.devices = [d for d in self.devices if d.devid != payload]
                elif kind == "drop":
                    raise OSError("socket dropped")

            async def close(self):
                self.closed.set()

        mux = Mux()
        self.muxes.append(mux)
        return mux

    async def start(self):
        async def create_mux():
            return self._make_mux()

        self.task = asyncio.create_task(
            device.watch_usbmux(
                self.frames.append, self.stop, create_mux=create_mux, reconnect_wait=0.01
            )
        )

    async def push(self, kind, payload=None):
        await self.ops.put((kind, payload))

    async def settle(self):
        """Let the watcher and any sync task it started run until they are idle."""
        for _ in range(50):
            await asyncio.sleep(0)

    async def finish(self):
        self.stop.set()
        await asyncio.wait_for(self.task, 2)


def _run(coro):
    asyncio.run(asyncio.wait_for(coro, 10))


def test_usb_attach_with_sync_off_turns_it_on_once(monkeypatch):
    async def scenario():
        h = _Harness(monkeypatch)
        await h.start()
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await h.settle()

        assert h.creates == [{"serial": UDID, "connection_type": "USB"}]
        assert h.clients[0].sets == [True]
        assert h.clients[0].closed
        assert h.notes == [
            "Turned on Wi-Fi sync for Test iPhone so it can refresh without the cable."
        ]
        await h.finish()

    _run(scenario())


def test_usb_attach_with_sync_already_on_changes_nothing(monkeypatch):
    async def scenario():
        h = _Harness(monkeypatch, lambda: _Client(enabled=True))
        await h.start()
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await h.settle()

        assert len(h.creates) == 1
        assert h.clients[0].sets == []
        assert h.clients[0].closed
        assert h.notes == []
        await h.finish()

    _run(scenario())


def test_network_attach_does_not_touch_lockdown(monkeypatch):
    async def scenario():
        h = _Harness(monkeypatch)
        await h.start()
        await h.push("add", _MuxDev(7, UDID, "Network"))
        await h.settle()

        assert h.creates == []
        assert h.frames[-1]["data"][0]["connection_type"] == "Network"
        await h.finish()

    _run(scenario())


def test_a_failing_phone_never_stops_the_watcher(monkeypatch):
    async def scenario():
        h = _Harness(monkeypatch)

        from pymobiledevice3 import lockdown as pmd_lockdown

        async def locked(serial=None, connection_type=None, **kwargs):
            raise RuntimeError("PasswordProtected")

        monkeypatch.setattr(pmd_lockdown, "create_using_usbmux", locked)
        await h.start()
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await h.settle()

        assert len(h.notes) == 1
        assert "Could not turn on Wi-Fi sync" in h.notes[0]
        assert "PasswordProtected" in h.notes[0]

        # The watcher is still alive and still reporting the inventory.
        await h.push("add", _MuxDev(8, OTHER, "Network"))
        await h.settle()
        assert [e["serial"] for e in h.frames[-1]["data"]] == [UDID, OTHER]
        await h.finish()

    _run(scenario())


def test_a_failing_write_is_reported_and_the_connection_closed(monkeypatch):
    async def scenario():
        h = _Harness(monkeypatch, lambda: _Client(set_error=RuntimeError("denied")))
        await h.start()
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await h.settle()

        assert len(h.notes) == 1 and "denied" in h.notes[0]
        assert h.clients[0].closed
        await h.finish()

    _run(scenario())


def test_a_slow_phone_does_not_hold_up_device_events(monkeypatch):
    async def scenario():
        h = _Harness(monkeypatch)
        release = asyncio.Event()

        from pymobiledevice3 import lockdown as pmd_lockdown

        async def slow(serial=None, connection_type=None, **kwargs):
            await release.wait()  # e.g. a trust dialog nobody has answered yet
            return _Client()

        monkeypatch.setattr(pmd_lockdown, "create_using_usbmux", slow)
        await h.start()
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await h.settle()
        await h.push("add", _MuxDev(8, OTHER, "Network"))
        await h.settle()

        assert len(h.frames) == 2, "the second devices event must not wait for the phone"
        await h.finish()  # stopping cancels the sync still waiting on the phone

    _run(scenario())


def test_rapid_repeat_attaches_of_one_serial_try_once(monkeypatch):
    async def scenario():
        h = _Harness(monkeypatch)
        await h.start()
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await h.push("add", _MuxDev(8, UDID, "USB"))
        await h.push("add", _MuxDev(9, OTHER, "Network"))
        await h.settle()

        assert [c["serial"] for c in h.creates] == [UDID]
        await h.finish()

    _run(scenario())


def test_re_listening_does_not_retry_a_phone_still_plugged_in(monkeypatch):
    async def scenario():
        h = _Harness(monkeypatch)
        await h.start()
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await h.settle()
        assert len(h.creates) == 1

        await h.push("drop")  # Listen socket dies; the watcher opens a new one
        while len(h.muxes) < 2:
            await asyncio.sleep(0.01)
        h.muxes[1].devices.append(_MuxDev(7, UDID, "USB"))
        await h.push("add", _MuxDev(9, OTHER, "Network"))  # usbmux re-announces everyone
        await h.settle()

        assert len(h.creates) == 1
        await h.finish()

    _run(scenario())


def test_a_second_attach_after_an_unplug_tries_again(monkeypatch):
    async def scenario():
        h = _Harness(monkeypatch)
        await h.start()
        await h.push("add", _MuxDev(7, UDID, "USB"))
        await h.settle()
        await h.push("remove", 7)
        await h.settle()
        await h.push("add", _MuxDev(8, UDID, "USB"))
        await h.settle()

        assert [c["serial"] for c in h.creates] == [UDID, UDID]
        await h.finish()

    _run(scenario())


def test_the_note_goes_to_the_real_stderr_as_a_progress_event(capfd):
    device._announce("hello")
    err = capfd.readouterr().err
    assert '"event": "progress"' in err and '"step": "hello"' in err


@pytest.mark.parametrize("serial", [UDID, "abc"])
def test_the_fallback_label_is_a_short_udid(monkeypatch, serial):
    async def scenario():
        notes: list[str] = []
        monkeypatch.setattr(device, "_announce", notes.append)
        from pymobiledevice3 import lockdown as pmd_lockdown

        async def create(serial=None, connection_type=None, **kwargs):
            client = _Client()
            client.all_values = {}
            return client

        monkeypatch.setattr(pmd_lockdown, "create_using_usbmux", create)
        await device._enable_wifi_sync(serial)
        assert notes == [
            f"Turned on Wi-Fi sync for {serial[:8]} so it can refresh without the cable."
        ]

    _run(scenario())
