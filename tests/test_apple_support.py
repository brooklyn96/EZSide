"""Tests for Apple's device stack: what state it is in, and fetching it safely.

Two things are being pinned down. First, that the three service states stay
distinguishable - a UI that cannot tell "stopped" from "never installed" offers the
wrong button, and ``doctor`` must report the same answer as everything else rather
than probing on its own. Second, that the download is **fail-closed**: the only
thing it may ever hand back is a file Windows says Apple signed, and every refusal
takes the file with it.

Nothing here touches the network or runs PowerShell: the HTTP response and the
Authenticode answer are both faked, so a 198MB download is never part of a test run.
"""

from __future__ import annotations

import json

import pytest
import requests

from ipaside_engine import apple_support, doctor, paths
from ipaside_engine import __main__ as cli
from ipaside_engine.errors import EngineError

APPLE_SUBJECT = "CN=Apple Inc., O=Apple Inc., L=Cupertino, S=California, C=US"
INSTALLER_BYTES = b"MZ" + b"iTunes installer payload" * 64


class _FakeResponse:
    """The slice of ``requests.Response`` that :func:`_stream_to_file` uses.

    Chunks are handed out in small pieces regardless of the requested
    ``chunk_size``, which is what a real response does too - the size is an upper
    bound on a socket read, not a promise - and is what lets a test fail partway
    through a body far smaller than the engine's 1MiB read size.
    """

    _PIECE = 64

    def __init__(
        self,
        body: bytes = INSTALLER_BYTES,
        *,
        status_code: int = 200,
        content_length: int | None = None,
        fail_after: int | None = None,
    ) -> None:
        self.status_code = status_code
        self._body = body
        self._fail_after = fail_after
        declared = len(body) if content_length is None else content_length
        self.headers = {"Content-Length": str(declared)}
        self.closed = False

    def __enter__(self) -> "_FakeResponse":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.closed = True

    def iter_content(self, chunk_size: int = 1):
        piece = min(self._PIECE, max(1, chunk_size))
        for start in range(0, len(self._body), piece):
            if self._fail_after is not None and start >= self._fail_after:
                raise requests.ConnectionError("the connection dropped")
            yield self._body[start : start + piece]


@pytest.fixture
def service_state(monkeypatch):
    """Drive the Windows service query the way a given machine would answer it."""

    def install(state: str | None):
        monkeypatch.setattr(
            doctor, "_windows_service_state", lambda name: state
        )

    return install


@pytest.fixture(autouse=True)
def windows_host(monkeypatch):
    """Answer as a Windows machine with no iTunes, unless a test says otherwise.

    The suite has to give the same answers on a developer's machine (where iTunes
    *is* installed) as in CI (where it is not), so both signals are pinned rather
    than read.
    """
    monkeypatch.setattr(apple_support.os, "name", "nt")
    monkeypatch.setattr(apple_support, "_itunes_version", lambda: None)
    monkeypatch.setattr(
        apple_support, "_mobile_device_support_dir", lambda: paths.data_dir() / "absent"
    )


@pytest.fixture
def authenticode(monkeypatch):
    """Stand in for the one subprocess that asks Windows about a signature."""

    def install(status: str, subject: str = APPLE_SUBJECT):
        monkeypatch.setattr(
            apple_support, "_authenticode", lambda _path: (status, subject)
        )

    return install


@pytest.fixture
def http(monkeypatch):
    """Replace ``requests.get`` with a canned response or a canned failure."""

    def install(response=None, *, error: Exception | None = None):
        calls: list[dict[str, object]] = []

        def fake_get(url, **kwargs):
            calls.append({"url": url, **kwargs})
            if error is not None:
                raise error
            return response

        monkeypatch.setattr(apple_support.requests, "get", fake_get)
        return calls

    return install


class TestStatus:
    """The three states, plus the host that has no such service at all."""

    def test_a_running_service_is_the_only_ready_state(self, service_state):
        service_state("RUNNING")
        state = apple_support.status()

        assert state["state"] == apple_support.RUNNING
        assert state["service_state"] == "RUNNING"
        assert "running" in state["detail"]

    def test_a_stopped_service_can_be_started_and_says_it_needs_rights(self, service_state):
        # The distinction that matters: this machine needs a service start, not a
        # 198MB download, and starting one needs elevation.
        service_state("STOPPED")
        state = apple_support.status()

        assert state["state"] == apple_support.STOPPED
        assert state["service_state"] == "STOPPED"
        assert "administrator" in state["detail"]

    def test_a_paused_service_is_reported_as_stopped_not_unknown(self, service_state):
        # Anything that is neither RUNNING nor absent is something a start can fix.
        service_state("PAUSED")
        state = apple_support.status()

        assert state["state"] == apple_support.STOPPED
        assert "state=PAUSED" in state["detail"]

    def test_a_missing_service_asks_for_itunes(self, service_state):
        service_state(None)
        state = apple_support.status()

        assert state["state"] == apple_support.MISSING
        assert state["service_state"] is None
        assert state["itunes_installed"] is False
        assert "comes with iTunes" in state["detail"]

    def test_itunes_present_but_service_missing_reads_as_a_repair(
        self, service_state, monkeypatch
    ):
        # "Install iTunes" is the wrong sentence for someone who already has it.
        service_state(None)
        monkeypatch.setattr(apple_support, "_itunes_version", lambda: "12.13.10.3")
        state = apple_support.status()

        assert state["state"] == apple_support.MISSING
        assert state["itunes_installed"] is True
        assert state["itunes_version"] == "12.13.10.3"
        assert "Reinstalling iTunes" in state["detail"]

    def test_the_mobile_device_folder_alone_counts_as_installed(
        self, service_state, monkeypatch, tmp_path
    ):
        support = tmp_path / "Apple" / "Mobile Device Support"
        support.mkdir(parents=True)
        service_state(None)
        monkeypatch.setattr(apple_support, "_mobile_device_support_dir", lambda: support)

        assert apple_support.status()["itunes_installed"] is True

    def test_a_non_windows_host_reports_unsupported_rather_than_crashing(self, monkeypatch):
        monkeypatch.setattr(apple_support.os, "name", "posix")
        state = apple_support.status()

        assert state["state"] == apple_support.UNSUPPORTED
        assert state["service_state"] is None
        assert "usbmuxd" in state["detail"]


class TestDoctorAgrees:
    """One probe, one answer: the diagnostics row is this module's verdict."""

    @pytest.mark.parametrize(
        ("service", "expected"),
        [("RUNNING", doctor.OK), ("STOPPED", doctor.FAIL), (None, doctor.FAIL)],
    )
    def test_the_diagnostics_row_carries_the_shared_detail(
        self, service_state, service, expected
    ):
        service_state(service)
        check = doctor._check_amds()

        assert check["status"] == expected
        assert check["detail"] == apple_support.status()["detail"]

    def test_a_non_windows_host_warns_rather_than_failing(self, monkeypatch):
        monkeypatch.setattr(apple_support.os, "name", "posix")
        check = doctor._check_amds()

        assert check["status"] == doctor.WARN
        assert check["detail"] == apple_support.status()["detail"]


class TestDownload:
    """The installer arrives verified, or it does not arrive."""

    def test_a_good_download_is_verified_and_reported(self, http, authenticode, tmp_path):
        calls = http(_FakeResponse())
        authenticode("Valid")

        result = apple_support.download_itunes(str(tmp_path))

        assert calls[0]["url"] == apple_support.ITUNES_DOWNLOAD_URL
        assert calls[0]["stream"] is True
        assert calls[0]["allow_redirects"] is True
        target = tmp_path / apple_support.INSTALLER_NAME
        assert result["path"] == str(target)
        assert result["bytes"] == len(INSTALLER_BYTES)
        assert result["signer"] == APPLE_SUBJECT
        assert result["signature_status"] == "Valid"
        assert target.read_bytes() == INSTALLER_BYTES

    def test_progress_streams_the_engines_usual_shape(self, http, authenticode, tmp_path):
        http(_FakeResponse())
        authenticode("Valid")
        seen: list[tuple[str, object, str | None]] = []

        apple_support.download_itunes(
            str(tmp_path),
            on_progress=lambda phase, percent, step: seen.append((phase, percent, step)),
        )

        assert {phase for phase, _percent, _step in seen} == {"download"}
        assert seen[0][1] == 0
        assert seen[-1][1] == 100
        assert any(step and "of" in step for _phase, _percent, step in seen)

    def test_it_lands_in_the_apps_own_folder_by_default(self, http, authenticode):
        http(_FakeResponse())
        authenticode("Valid")

        result = apple_support.download_itunes()

        assert result["path"] == str(paths.downloads_dir() / apple_support.INSTALLER_NAME)

    def test_a_blank_folder_means_the_default_not_the_working_directory(
        self, http, authenticode
    ):
        http(_FakeResponse())
        authenticode("Valid")

        assert apple_support.download_itunes("   ")["path"] == str(
            paths.downloads_dir() / apple_support.INSTALLER_NAME
        )


class TestDownloadRefusals:
    """Every refusal raises an EngineError *and* takes the download with it."""

    def _no_file_left(self, directory) -> None:
        assert list(directory.iterdir()) == [], "an unverified download must not survive"

    def test_an_unsigned_installer_is_deleted_not_installed(
        self, http, authenticode, tmp_path
    ):
        http(_FakeResponse())
        authenticode("NotSigned", "")

        with pytest.raises(apple_support.AppleSupportError, match="not validly signed"):
            apple_support.download_itunes(str(tmp_path))

        self._no_file_left(tmp_path)

    def test_a_broken_signature_is_deleted_not_installed(
        self, http, authenticode, tmp_path
    ):
        http(_FakeResponse())
        authenticode("HashMismatch", APPLE_SUBJECT)

        with pytest.raises(apple_support.AppleSupportError, match="HashMismatch"):
            apple_support.download_itunes(str(tmp_path))

        self._no_file_left(tmp_path)

    def test_somebody_elses_valid_signature_is_still_refused(
        self, http, authenticode, tmp_path
    ):
        # A validly signed installer from anyone but Apple is the dangerous case:
        # it is exactly what a compromised download path would serve.
        http(_FakeResponse())
        authenticode("Valid", "CN=Contoso Ltd, O=Contoso Ltd, C=US")

        with pytest.raises(apple_support.AppleSupportError, match="not by Apple Inc."):
            apple_support.download_itunes(str(tmp_path))

        self._no_file_left(tmp_path)

    def test_apple_inc_smuggled_into_another_field_is_refused(
        self, http, authenticode, tmp_path
    ):
        # Substring-matching the subject for "O=Apple Inc." would accept this.
        http(_FakeResponse())
        authenticode("Valid", 'CN="Apple Inc., O=Apple Inc.", O=Contoso Ltd')

        with pytest.raises(apple_support.AppleSupportError, match="not by Apple Inc."):
            apple_support.download_itunes(str(tmp_path))

        self._no_file_left(tmp_path)

    def test_no_internet_reads_as_a_sentence_not_a_stack(self, http, tmp_path):
        http(error=requests.ConnectionError("getaddrinfo failed"))

        with pytest.raises(
            apple_support.AppleSupportError, match="Could not reach Apple"
        ) as caught:
            apple_support.download_itunes(str(tmp_path))

        assert "getaddrinfo" not in str(caught.value), "urllib3 noise is not a message"
        self._no_file_left(tmp_path)

    def test_a_connection_that_drops_midway_discards_the_partial_file(
        self, http, authenticode, tmp_path
    ):
        http(_FakeResponse(fail_after=len(INSTALLER_BYTES) // 2))
        authenticode("Valid")

        with pytest.raises(apple_support.AppleSupportError, match="download failed"):
            apple_support.download_itunes(str(tmp_path))

        self._no_file_left(tmp_path)

    def test_a_short_download_is_reported_as_short_not_as_unsigned(
        self, http, authenticode, tmp_path
    ):
        # A truncated file fails its signature check too, but "ended early" is the
        # sentence that tells the user to try again.
        http(_FakeResponse(content_length=len(INSTALLER_BYTES) * 2))
        authenticode("Valid")

        with pytest.raises(apple_support.AppleSupportError, match="ended early"):
            apple_support.download_itunes(str(tmp_path))

        self._no_file_left(tmp_path)

    def test_a_refusing_server_is_named_by_its_status(self, http, tmp_path):
        http(_FakeResponse(status_code=503))

        with pytest.raises(apple_support.AppleSupportError, match="HTTP 503"):
            apple_support.download_itunes(str(tmp_path))

        self._no_file_left(tmp_path)

    def test_a_non_windows_host_refuses_before_downloading_anything(
        self, http, monkeypatch, tmp_path
    ):
        calls = http(_FakeResponse())
        monkeypatch.setattr(apple_support.os, "name", "posix")

        with pytest.raises(apple_support.AppleSupportError, match="Windows"):
            apple_support.download_itunes(str(tmp_path))

        assert calls == []


class TestSubjectParsing:
    """The signer check reads real RDNs, not a substring of the whole subject."""

    def test_it_reads_the_organisation(self):
        assert apple_support._subject_field(APPLE_SUBJECT, "O") == ["Apple Inc."]

    def test_a_quoted_comma_does_not_split_a_value(self):
        subject = 'CN=Some CA, O="DigiCert, Inc.", C=US'
        assert apple_support._subject_field(subject, "O") == ["DigiCert, Inc."]

    def test_a_field_pretending_to_be_another_is_not_confused_for_it(self):
        subject = 'CN="hello O=Apple Inc.", O=Contoso Ltd'
        assert apple_support._subject_field(subject, "O") == ["Contoso Ltd"]

    def test_two_organisations_are_both_reported_so_neither_can_be_picked(self):
        subject = "CN=X, O=Apple Inc., O=Contoso Ltd"
        assert apple_support._subject_field(subject, "O") == ["Apple Inc.", "Contoso Ltd"]

    def test_an_absent_field_is_empty(self):
        assert apple_support._subject_field("CN=X", "O") == []


class TestStartService:
    """Elevation is asked for properly, and declining it is not a failure."""

    def test_an_already_running_service_never_asks_for_elevation(
        self, service_state, monkeypatch
    ):
        service_state("RUNNING")
        monkeypatch.setattr(
            apple_support,
            "_elevated_service_start",
            lambda: pytest.fail("must not prompt for a service that is already up"),
        )

        result = apple_support.start_service()

        assert result["started"] is True
        assert result["reason"] == "already_running"
        assert result["status"]["state"] == apple_support.RUNNING

    def test_a_declined_prompt_changes_nothing_and_says_so(
        self, service_state, monkeypatch
    ):
        service_state("STOPPED")
        monkeypatch.setattr(
            apple_support, "_elevated_service_start", lambda: ("cancelled", 1223, "")
        )

        result = apple_support.start_service()

        assert result["started"] is False
        assert result["reason"] == "elevation_declined"
        assert "declined" in result["detail"]
        assert result["status"]["state"] == apple_support.STOPPED

    def test_a_successful_start_reports_the_new_state(self, monkeypatch):
        states = iter(["STOPPED", "RUNNING", "RUNNING", "RUNNING"])
        monkeypatch.setattr(
            doctor, "_windows_service_state", lambda name: next(states, "RUNNING")
        )
        monkeypatch.setattr(
            apple_support, "_elevated_service_start", lambda: ("ok", 0, "")
        )

        result = apple_support.start_service()

        assert result["started"] is True
        assert result["reason"] == "started"
        assert result["status"]["state"] == apple_support.RUNNING

    def test_a_service_that_will_not_come_up_is_not_claimed_as_started(
        self, service_state, monkeypatch
    ):
        service_state("STOPPED")
        monkeypatch.setattr(
            apple_support, "_elevated_service_start", lambda: ("ok", 1053, "")
        )
        monkeypatch.setattr(apple_support, "_await_running", lambda: False)

        result = apple_support.start_service()

        assert result["started"] is False
        assert result["reason"] == "did_not_start"

    def test_a_windows_refusal_is_reported_rather_than_retried(
        self, service_state, monkeypatch
    ):
        service_state("STOPPED")
        monkeypatch.setattr(
            apple_support,
            "_elevated_service_start",
            lambda: ("error", 5, "Access is denied"),
        )

        result = apple_support.start_service()

        assert result["started"] is False
        assert result["reason"] == "failed"
        assert "Access is denied" in result["detail"]

    def test_there_is_nothing_to_start_when_the_service_is_missing(self, service_state):
        service_state(None)

        with pytest.raises(apple_support.AppleSupportError, match="install iTunes first"):
            apple_support.start_service()

    def test_a_non_windows_host_has_no_service_to_start(self, monkeypatch):
        monkeypatch.setattr(apple_support.os, "name", "posix")

        with pytest.raises(apple_support.AppleSupportError, match="Windows service"):
            apple_support.start_service()


class TestCommandLine:
    """The surface the desktop app drives, checked as a contract."""

    @staticmethod
    def _parse(argv):
        return cli.build_parser().parse_args(argv)

    def test_it_reports_status_by_default(self, service_state, capsys):
        service_state("RUNNING")

        assert cli.dispatch(self._parse(["apple-support", "--json"])) == 0

        payload = json.loads(capsys.readouterr().out)
        assert payload["state"] == "running"
        assert payload["service_name"] == apple_support.SERVICE_NAME

    def test_a_broken_environment_still_exits_zero(self, service_state, capsys):
        # The status is the answer, not an error: a non-zero exit would arrive at the
        # app as a thrown exception and lose the very report it asked for.
        service_state(None)

        assert cli.dispatch(self._parse(["apple-support", "--json"])) == 0
        assert json.loads(capsys.readouterr().out)["state"] == "missing"

    def test_download_is_behind_a_flag_and_forwards_the_folder(self, monkeypatch, capsys):
        seen: dict[str, object] = {}

        def fake_download(directory=None, *, on_progress=None):
            seen["directory"] = directory
            seen["progress_wired"] = on_progress is not None
            return {
                "path": r"D:\dl\iTunes64Setup.exe",
                "bytes": 208064480,
                "url": apple_support.ITUNES_DOWNLOAD_URL,
                "signer": APPLE_SUBJECT,
                "signature_status": "Valid",
            }

        monkeypatch.setattr(apple_support, "download_itunes", fake_download)
        monkeypatch.setattr(
            apple_support, "status", lambda: pytest.fail("must not report status")
        )

        assert cli.dispatch(
            self._parse(["apple-support", "--download", "--dir", r"D:\dl", "--json"])
        ) == 0
        assert seen == {"directory": r"D:\dl", "progress_wired": True}
        assert json.loads(capsys.readouterr().out)["signer"] == APPLE_SUBJECT

    def test_a_refused_download_prints_one_line_and_exits_one(self, monkeypatch, capsys):
        def refuse(directory=None, *, on_progress=None):
            raise apple_support.AppleSupportError("The installer is not signed by Apple.")

        monkeypatch.setattr(apple_support, "download_itunes", refuse)

        assert cli.main(["apple-support", "--download"]) == 1

        captured = capsys.readouterr()
        assert captured.err.strip() == "error: The installer is not signed by Apple."
        assert "Traceback" not in captured.err

    def test_starting_the_service_is_behind_its_own_flag(self, monkeypatch, capsys):
        monkeypatch.setattr(
            apple_support,
            "start_service",
            lambda: {
                "started": False,
                "reason": "elevation_declined",
                "detail": "The request was declined.",
                "status": {"state": "stopped"},
            },
        )
        monkeypatch.setattr(
            apple_support,
            "download_itunes",
            lambda *_a, **_k: pytest.fail("must not download"),
        )

        assert cli.dispatch(self._parse(["apple-support", "--start-service", "--json"])) == 0
        assert json.loads(capsys.readouterr().out)["reason"] == "elevation_declined"

    def test_neither_action_is_taken_unasked(self):
        args = self._parse(["apple-support"])

        assert args.download is False
        assert args.start_service is False
        assert args.dir is None


def test_the_error_is_an_engine_error_so_it_prints_as_a_sentence():
    assert issubclass(apple_support.AppleSupportError, EngineError)
