"""apps.py and livecontainer.py over Wi-Fi direct: operation caps and retries, a long
install, cleanup.

All offline. Which cap / retry each function asks ``wifi_direct.wifi_operation`` for is
checked with a recording stand-in for it; the rest runs through the real one.
"""

import asyncio
import functools
import importlib.util
import inspect
import time
from types import SimpleNamespace

import pytest

from ipaside_engine import device, lockdown, wifi_direct

from ipaside_engine import apps, livecontainer  # noqa: E402

UDID = "4fd25abf1b629b2c261becbecfb2d2a86e34b357"


# --- which public function carries which cap / retry ------------------------- #


def _decorations(monkeypatch, module):
    """``{function name: (cap, retry)}`` that ``module`` asks wifi_operation for."""
    seen: dict = {}
    taking_serial: list = []

    def recorder(*, cap, retry):
        def decorate(fn):
            seen[fn.__name__] = (cap, retry)
            if "serial" in inspect.signature(fn).parameters:
                taking_serial.append(fn.__name__)
            return fn

        return decorate

    monkeypatch.setattr(wifi_direct, "wifi_operation", recorder)
    # A private copy of the module, imported while the recorder is in place; the real
    # module (and every class it defines) is left alone.
    spec = importlib.util.spec_from_file_location(f"ipaside_engine._probe_{module.__name__.rsplit('.')[-1]}", module.__file__)
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    assert sorted(taking_serial) == sorted(seen), "every decorated function takes serial"
    return seen


def test_each_apps_function_carries_its_cap_and_retry(monkeypatch):
    assert _decorations(monkeypatch, apps) == {
        "list_installed": (120, True),
        "icons": (120, True),
        "install_profile": (120, True),
        "install": (1800, True),
        "uninstall": (120, False),
    }


def test_livecontainer_writes_are_never_retried(monkeypatch):
    seen = _decorations(monkeypatch, livecontainer)
    assert set(seen) == {
        "_write_documents", "_list_dir", "_remove_tree", "_push_bundle", "_list_documents",
    }
    assert all(retry is False for _cap, retry in seen.values())
    # A whole bundle is a long upload: it gets the install cap, the rest the short one.
    assert seen["_push_bundle"][0] == 1800
    assert {cap for name, (cap, _r) in seen.items() if name != "_push_bundle"} == {120}


# --- the target is passed on, never re-resolved ------------------------------ #


@pytest.fixture
def phone(monkeypatch):
    """A fake lockdown and fake services; ``created`` lists every serial asked for."""
    from pymobiledevice3.services import installation_proxy as ip_module
    from pymobiledevice3.services import misagent as misagent_module

    created: list = []

    async def create(serial=None, prefer_usb=True, allow_wifi_direct=True):
        created.append(serial)
        return object()

    async def close(client):
        pass

    async def no_listing():
        raise AssertionError("the device was looked up again after it had a serial")

    monkeypatch.setattr(lockdown, "create", create)
    monkeypatch.setattr(lockdown, "close", close)
    monkeypatch.setattr(device, "_list_devices_async", no_listing)

    class Proxy:
        def __init__(self, lockdown=None):
            pass

        async def get_apps(self, application_type="User"):
            return {"com.x": {"CFBundleName": "X", "CFBundleShortVersionString": "1"}}

        async def uninstall(self, bundle_id):
            pass

        async def close(self):
            pass

    plist = {"UUID": "u-1", "TeamIdentifier": ["TEAM"], "Entitlements": {"application-identifier": "TEAM.app"}}

    class Profile:
        def __init__(self, data):
            self.plist = plist

    class Misagent:
        def __init__(self, lockdown=None):
            pass

        async def install(self, stream):
            pass

        async def copy_all(self):
            return [SimpleNamespace(plist=plist)]

        async def remove(self, uuid):
            pass

        async def close(self):
            pass

    monkeypatch.setattr(ip_module, "InstallationProxyService", Proxy)
    monkeypatch.setattr(misagent_module, "MisagentService", Misagent)
    monkeypatch.setattr(misagent_module, "ProvisioningProfile", Profile)
    return created


@pytest.fixture
def springboard(monkeypatch):
    from pymobiledevice3.services import springboard as sb_module

    class Springboard:
        def __init__(self, lockdown=None):
            pass

        async def get_icon_pngdata(self, bundle_id):
            return b"png"

        async def close(self):
            pass

    monkeypatch.setattr(sb_module, "SpringBoardServicesService", Springboard)


def test_a_serial_given_as_keyword_reaches_lockdown_and_nothing_re_resolves(
    phone, springboard, monkeypatch, tmp_path
):
    ipa = tmp_path / "app.ipa"
    ipa.write_bytes(b"x" * 10)
    FakeInstall(monkeypatch, created=phone)  # install: AFC and installd fakes, same record
    assert apps.list_installed(serial=UDID)["com.x"]["name"] == "X"
    apps.uninstall("com.x", serial=UDID)
    assert apps.install_profile(b"profile", serial=UDID) == "u-1"
    apps.install(str(ipa), serial=UDID)
    assert list(apps.icons(serial=UDID)) == ["com.x"]
    assert phone == [UDID] * 5


def test_serial_none_is_resolved_once_and_every_call_sees_only_that_udid(
    phone, springboard, monkeypatch, tmp_path
):
    ipa = tmp_path / "app.ipa"
    ipa.write_bytes(b"x" * 10)
    FakeInstall(monkeypatch, created=phone)
    resolved: list = []
    monkeypatch.setattr(
        device, "resolve_serial", lambda serial=None: resolved.append(serial) or serial or UDID
    )
    apps.list_installed()
    apps.uninstall("com.x")
    apps.install_profile(b"profile")
    apps.install(str(ipa))
    apps.icons()
    assert resolved == [None] * 5, "once per public call"
    assert phone == [UDID] * 5


@pytest.fixture
def house(monkeypatch, phone):
    """A fake house_arrest service on top of the fake phone; ``phone`` lists the serials."""
    from pymobiledevice3.services import house_arrest

    class Service:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            pass

        async def makedirs(self, path):
            pass

        async def set_file_contents(self, path, data):
            pass

        async def listdir(self, path):
            raise OSError("not there")

        async def rm_single(self, path):
            pass

    async def create(client, bundle_id):
        return Service()

    monkeypatch.setattr(house_arrest.HouseArrestService, "create", create)
    return phone


def test_livecontainer_functions_pass_the_serial_on_and_never_re_resolve(house, tmp_path):
    p12 = tmp_path / "c.p12"
    p12.write_bytes(b"p12")
    bundle = {"p12_path": str(p12), "bundle_id": "com.lc", "p12_password": "pw"}
    assert livecontainer.seed_certificate(bundle, serial=UDID, automatic=False)["seeded"]
    assert livecontainer.guest_apps("com.lc", serial=UDID) == []
    livecontainer.remove_guest("g", "com.lc", serial=UDID)
    asyncio.run(livecontainer._push_bundle("com.lc", UDID, "t", {"a": b"x"}, 1, lambda *a: None))
    assert house == [UDID] * 4


def test_status_uses_one_target_for_both_phone_calls(monkeypatch):
    calls: list = []
    monkeypatch.setattr(device, "resolve_serial", lambda serial=None: serial or UDID)
    monkeypatch.setattr(
        apps, "list_installed",
        lambda serial=None, app_type="User": calls.append(("apps", serial)) or {"com.kdt.livecontainer": {}},
    )

    async def documents(bundle_id, serial):
        calls.append(("documents", serial))
        return []

    monkeypatch.setattr(livecontainer, "_list_documents", documents)
    monkeypatch.setattr(livecontainer, "BUNDLE_PREFIX", "com.kdt.livecontainer")
    assert livecontainer.status()["installed"]
    assert calls == [("apps", UDID), ("documents", UDID)]


# --- install: AFC is closed before the long phase, reopened for cleanup ------- #


class _WifiClient:
    """A registered Wi-Fi client; ``dropped`` is what the idle-read teardown sets."""

    def __init__(self):
        self.dropped = False
        self.requested_udid = UDID

    async def teardown(self, reason):
        self.dropped = True


class FakeInstall:
    """AFC, installd and the order of events of one install.

    An open AFC connection models what the real one does: a reader task with a read
    pending and nothing asked. Left open for IDLE_READ seconds it trips the idle-read
    deadline, which the install then meets as a dropped connection.
    """

    def __init__(self, monkeypatch, *, messages=None, rm_error=None, rm_hangs=False,
                 created=None, wifi=False):
        from pymobiledevice3.services import afc as afc_module
        from pymobiledevice3.services import installation_proxy as ip_module

        self.events: list = []
        self.dropped = False
        self.created: list = created if created is not None else []
        self.wifi = wifi
        me = self

        class Afc:
            def __init__(self, lockdown_client):
                pass

            async def __aenter__(self):
                me.events.append("afc-open")
                self.idle = asyncio.create_task(self._idle())
                return self

            async def _idle(self):
                await asyncio.sleep(wifi_direct.IDLE_READ)
                me.dropped = True

            async def __aexit__(self, *exc):
                self.idle.cancel()
                await asyncio.gather(self.idle, return_exceptions=True)
                me.events.append("afc-close")

            async def makedirs(self, path):
                pass

            async def fopen(self, path, mode):
                return 1

            async def fwrite(self, handle, data):
                pass

            async def fclose(self, handle):
                pass

            async def rm_single(self, path, force=False):
                me.events.append("rm")
                if rm_hangs:
                    await asyncio.sleep(3600)
                if rm_error:
                    raise rm_error

        pending = list(messages if messages is not None else
                       [{"Status": "Installing", "PercentComplete": p} for p in range(0, 100, 20)]
                       + [{"Status": "Complete"}])

        class Service:
            async def send_plist(self, message):
                me.events.append("watch")

            async def recv_plist(self):
                await asyncio.sleep(0.05)
                if me.dropped:
                    raise ConnectionResetError("idle read deadline")
                return pending.pop(0)

        class Proxy:
            def __init__(self, lockdown=None):
                self.service = Service()

            async def get_apps(self, application_type="User"):
                return {"com.x": {"CFBundleName": "X", "CFBundleShortVersionString": "1"}}

            async def uninstall(self, bundle_id):
                pass

            async def close(self):
                pass

        async def create(serial=None, prefer_usb=True, allow_wifi_direct=True):
            me.created.append(serial)
            client = _WifiClient()
            if me.wifi:  # what wifi_direct.connect does: the attempt learns of the client
                wifi_direct._attempt.get().append(client)
            return client

        async def close(client):
            pass

        monkeypatch.setattr(afc_module, "AfcService", Afc)
        monkeypatch.setattr(ip_module, "InstallationProxyService", Proxy)
        monkeypatch.setattr(lockdown, "create", create)
        monkeypatch.setattr(lockdown, "close", close)

    def run(self, tmp_path):
        ipa = tmp_path / "app.ipa"
        ipa.write_bytes(b"x" * 10)
        steps: list = []
        # An outer deadline, so a cleanup that hangs fails the test instead of hanging it.
        asyncio.run(asyncio.wait_for(apps._install_async(str(ipa), UDID, steps.append), 10))
        return steps

    def run_decorated(self, tmp_path):
        """Through ``apps.install``: the Wi-Fi cap and retry are live around the install."""
        ipa = tmp_path / "app.ipa"
        ipa.write_bytes(b"x" * 10)
        steps: list = []
        apps.install(str(ipa), UDID, steps.append)
        return steps


def test_a_long_install_phase_does_not_trip_the_idle_read_and_is_not_retried(
    monkeypatch, tmp_path
):
    monkeypatch.setattr(wifi_direct, "IDLE_READ", 0.1)
    monkeypatch.setattr(wifi_direct, "RETRY_PAUSE", 0.01)
    monkeypatch.setattr(wifi_direct, "RETRY_WINDOW", 0.2)
    monkeypatch.setattr(wifi_direct, "find", lambda udid, sweep=True: "192.168.1.53")
    # 6 progress messages x 0.05 s: longer than IDLE_READ. A Wi-Fi client is registered,
    # so a drop would run the decorator's retry (a second lockdown.create).
    fake = FakeInstall(monkeypatch, wifi=True)
    start = time.monotonic()
    steps = fake.run_decorated(tmp_path)
    assert time.monotonic() - start > 0.1
    assert not fake.dropped
    assert fake.created == [UDID], "one connection, no retry"
    assert steps[-1] == {"phase": "install", "percent": None, "status": "Complete"}
    assert any(s.get("percent") == 80 for s in steps), "progress kept coming"


def test_afc_is_closed_before_the_install_phase_and_reopened_for_cleanup(monkeypatch, tmp_path):
    fake = FakeInstall(monkeypatch)
    fake.run(tmp_path)
    assert fake.events == ["afc-open", "afc-close", "watch", "afc-open", "rm", "afc-close"]


def test_cleanup_runs_when_the_install_fails_and_the_install_error_wins(monkeypatch, tmp_path):
    from pymobiledevice3.exceptions import AppInstallError

    fake = FakeInstall(
        monkeypatch,
        messages=[{"Error": "InstallProhibited", "ErrorDescription": "nope"}],
        rm_error=OSError("phone left"),
    )
    with pytest.raises(AppInstallError, match="InstallProhibited"):
        fake.run(tmp_path)
    assert fake.events[-3:] == ["afc-open", "rm", "afc-close"]


def test_a_failed_cleanup_after_a_finished_install_is_not_an_error(monkeypatch, tmp_path):
    fake = FakeInstall(monkeypatch, rm_error=OSError("phone left"))
    steps = fake.run(tmp_path)
    assert steps[-1]["status"] == "Complete"


def test_a_hanging_cleanup_is_cut_off_after_step_timeout(monkeypatch, tmp_path):
    monkeypatch.setattr(wifi_direct, "STEP_TIMEOUT", 0.1)
    fake = FakeInstall(monkeypatch, rm_hangs=True)
    start = time.monotonic()
    fake.run(tmp_path)
    assert time.monotonic() - start < 3
    assert fake.events[-2:] == ["rm", "afc-close"]


# --- the CLI picks the target once ------------------------------------------ #


@pytest.mark.parametrize(
    "flags", [[], ["--apps"], ["--remove", "g"], ["--add", "x.ipa"]]
)
def test_livecontainer_cli_resolves_the_target_once_for_all_its_phone_calls(
    monkeypatch, flags
):
    from ipaside_engine import __main__ as cli

    resolved: list = []
    seen: list = []
    monkeypatch.setattr(
        cli.device, "resolve_serial", lambda serial=None: resolved.append(serial) or serial or UDID
    )
    monkeypatch.setattr(
        livecontainer, "status",
        lambda serial=None: seen.append(("status", serial))
        or {"installed": True, "bundle_id": "com.lc", "launched": True},
    )
    monkeypatch.setattr(
        livecontainer, "guest_apps",
        lambda bundle_id, serial=None: seen.append(("guests", serial)) or [],
    )
    monkeypatch.setattr(
        livecontainer, "remove_guest",
        lambda guest, bundle_id, serial=None: seen.append(("remove", serial)),
    )
    monkeypatch.setattr(
        livecontainer, "install_guest",
        lambda path, bundle_id, serial=None, **kw: seen.append(("add", serial))
        or {"name": "n", "bundle_id": "b"},
    )
    parsed = cli.build_parser().parse_args(["livecontainer", "--json", *flags])
    assert cli.dispatch(parsed) == 0
    assert resolved == [None], "resolved once, at the top"
    assert seen and {serial for _name, serial in seen} == {UDID}
