# macOS port — deferred task list

iPASide is Windows-first. The shell was built so a macOS port is additive work
rather than a rewrite, and this document is the authoritative list of what was
**intentionally deferred**. None of it is built today. Do not treat any item
below as implemented.

## What is already macOS-ready

The seams the port plugs into exist now:

- **Platform interfaces** live in `src/iPASide.Flutter/lib/platform/`, each an
  abstract class with a factory that switches on `Platform.isWindows` and falls
  back to a documented non-Windows stand-in:

  | Interface | Windows implementation | non-Windows fallback |
  |---|---|---|
  | `ChildProcessReaper` | `WindowsChildProcessReaper` (Job Object) | `NoopChildProcessReaper` |
  | `BackgroundRefreshScheduler` | `WindowsBackgroundRefreshScheduler` (`schtasks`) | `UnsupportedBackgroundRefreshScheduler` |
  | `SingleInstanceGuard` | `WindowsSingleInstanceGuard` (named mutex) | `NullSingleInstanceGuard` |
  | `ReducedMotionProvider` | `WindowsReducedMotionProvider` | `DefaultReducedMotionProvider` |

- **`AppPaths`** (`lib/platform/app_paths.dart`) already resolves a macOS host,
  so per-user data lands under `~/Library/Application Support/iPASide/` without
  further work.
- **Engine discovery** (`lib/engine/engine_locator.dart`) already probes the
  macOS bundled-interpreter layout (`engine/python/bin/python3`) alongside the
  Windows one.
- The **engine protocol** — newline-delimited JSON over stdio — is
  platform-agnostic, and the **entire Python engine** is portable Python with no
  Windows-specific code paths.
- The **UI layer** is Flutter, which builds for macOS as-is. Nothing under
  `lib/ui/` is Windows-specific.
- The engine's zsign resolver (`resolve_zsign()` in
  `src/iPASide.Engine/ipaside_engine/signing.py`) already looks for a bare
  `zsign` binary with no `.exe` suffix on non-Windows: the `IPASIDE_ZSIGN`
  override, then the vendored copy, then `PATH`.

## Deferred tasks

When this work starts, mirror the existing layout: add `macos_*.dart` siblings
next to the `windows_*.dart` files and extend the factory switch in each
interface's file. Do not introduce a separate platform package.

### 1. Native file dialogs — a hard blocker

`lib/services/file_picker.dart` currently returns `null` (single) and an empty
list (multiple) on any non-Windows host, because the picker calls
`IFileOpenDialog` through COM in `lib/platform/windows_file_dialog.dart`. This
was a deliberate trade: the available Flutter picker plugin pinned an
incompatible `win32` version and could not set dialog titles.

**Consequence: on macOS today you cannot choose an `.ipa` or a tweak at all.**
Drag-and-drop would be the only input path. This is the first thing the port
must fix — either an `NSOpenPanel` binding alongside the COM one, or a picker
plugin that does not collide with the `win32` FFI layer.

### 2. Real child-process reaper (kqueue `EVFILT_PROC`)

Replace `NoopChildProcessReaper` on macOS with a real reaper guaranteeing the
Python engine — and transitively zsign — dies when the host dies. This is the
macOS equivalent of `WindowsChildProcessReaper`, which adopts the engine into a
Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.

Intended design: register a kqueue watch with `EVFILT_PROC`/`NOTE_EXIT` on the
**host** pid and kill the adopted child tree when the host exits. Until it
exists, macOS builds run with the no-op fallback, where a crashed or
force-killed host leaks orphaned `python3`/`zsign` processes. Graceful shutdown
still kills them, via the engine client's shutdown frame.

### 3. launchd auto-refresh scheduler

Implement `BackgroundRefreshScheduler` on launchd: a per-user LaunchAgent plist
(`~/Library/LaunchAgents/com.ipaside.autorefresh.plist`) with a daily
`StartCalendarInterval`, running `iPASide --auto-refresh`. That is the
counterpart of the daily `schtasks` job in
`WindowsBackgroundRefreshScheduler`. The enable/disable calls map to writing
the plist plus `launchctl bootstrap`/`bootout`. Until then the unsupported
fallback reports that it is unavailable and the Settings toggle stays disabled,
which matters more here than on Windows — without it, free-account apps expire
after 7 days with no automatic renewal.

### 4. File-lock single-instance guard

Implement `SingleInstanceGuard` with an advisory file lock (`flock`/`O_EXLOCK`
on a lock file under the `AppPaths` directory), since Windows named mutexes
have no direct macOS equivalent. Preserve the two-lock split from
`lib/main.dart`: the single-instance lock gates only GUI launches, while a
separate always-held "running" marker lets the installer and updater detect
*any* running iPASide — including a headless `--auto-refresh` run, which must
never block a GUI launch. Until then the null guard allows unlimited
concurrent instances.

### 5. Window chrome

The window is chromeless with a custom title bar (`lib/ui/shell/title_bar.dart`)
carrying Windows-style caption buttons on the right, and it contains no
platform switches. macOS needs the traffic-light controls on the left, at the
system's expected position and spacing, and should respect a full-screen
transition rather than a maximize toggle. Note the caption buttons deliberately
sit *outside* the drag region — a double-tap recogniser wrapping them held
Flutter's gesture arena open and delayed every click by 300 ms — so keep that
arrangement when rearranging for macOS.

### 6. `packaging/build-engine.sh` producing `engine/python/bin/python3`

Write the counterpart of `packaging/build-engine.ps1`: assemble a relocatable
CPython with the trimmed standard library, the runtime dependencies installed
into a private site-packages, `ipaside_engine` copied in, PyAV pruned, bytecode
precompiled, and a `python3 -m ipaside_engine version` smoke test. Lay it out
so the interpreter lands at `engine/python/bin/python3`, exactly where the
engine locator already looks. Framework-versus-non-framework CPython and
`install_name`/rpath relocatability are the expected hard parts.

### 7. macOS zsign binary

Build zsign for macOS as a universal `arm64` + `x86_64` binary via `lipo`,
linked against OpenSSL, zlib and minizip. This is the counterpart of
`tools/zsign/build-zsign.sh`, which currently produces only a Windows
`zsign.exe` through MSYS2/MinGW-w64. Vendor the output at
`src/iPASide.Engine/ipaside_engine/vendor/zsign` with no extension, which
`resolve_zsign()` already picks up. Keep the build-from-source policy: zsign
handles the user's Apple signing identity, so no prebuilt binaries.

### 8. `.app` bundle and notarization

Package the build as `iPASide.app` — `Info.plist`, an `.icns` icon, and the
portable engine under `Contents/Resources/`. Codesign with a Developer ID
Application certificate and the hardened runtime enabled, covering every nested
Mach-O: `python3`, the native wheels' `.so`/`.dylib` files, and the vendored
zsign. Then notarize with `notarytool` and staple the ticket. This replaces the
Inno Setup step in `packaging/build-installer.ps1` and `packaging/iPASide.iss`.
The distribution format, DMG versus zip, is an open decision.

### 9. Updater install step and asset selection

The updater's release check, download and checksum verification are portable,
but two pieces are not. `installStaged()` launches the staged `.exe` directly
and relies on Inno Setup upgrading in place and restarting the app, so macOS
needs its own apply step matching whatever format item 8 settles on. And asset
selection reads `PROCESSOR_ARCHITECTURE` to pick the right download, which is a
Windows-only environment variable — on macOS it is absent, so architecture must
come from somewhere else before an Apple-silicon build can be offered.
