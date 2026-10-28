// Ported from iPASide.App/Platform/ISingleInstanceGuard.cs,
// iPASide.Platform.Windows/WindowsSingleInstanceGuard.cs, the
// NullSingleInstanceGuard in iPASide.App/Platform/Fallbacks.cs, and the
// RunningMutexName marker held by iPASide.App/Program.cs.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Name of the mutex held by the first GUI instance.
const String singleInstanceMutexName = 'EZSide.SingleInstance.Mutex';

/// Name of the marker mutex held for the lifetime of EVERY EZSide process.
const String runningMutexName = 'EZSide.Running.Mutex';

/// Cross-process "first GUI instance" detection.
///
/// The guard stays held for the life of the process and is dropped by [dispose]
/// (or by the OS at exit).
abstract class SingleInstanceGuard {
  /// True when this process is the first instance; false when another instance
  /// already holds the guard, in which case the caller should exit.
  bool tryAcquire();

  /// Releases the guard.
  void dispose();
}

/// The guard for this OS: a named Windows mutex, or the dev fallback elsewhere.
SingleInstanceGuard createSingleInstanceGuard() => Platform.isWindows
    ? WindowsSingleInstanceGuard()
    : const NullSingleInstanceGuard();

/// Cross-process single-instance detection backed by a named Windows mutex.
///
/// A second launch is expected to exit with code 0, after asking the running
/// instance to show its window through [showRunningInstance].
class WindowsSingleInstanceGuard implements SingleInstanceGuard {
  /// Creates a guard over the mutex called [name].
  WindowsSingleInstanceGuard([String name = singleInstanceMutexName])
    : _mutex = _NamedMutex(name);

  final _NamedMutex _mutex;
  bool _attempted = false;
  bool _isFirstInstance = false;

  @override
  bool tryAcquire() {
    if (_attempted) return _isFirstInstance;
    _attempted = true;
    _isFirstInstance = _mutex.create(initiallyOwned: true);
    return _isFirstInstance;
  }

  @override
  void dispose() => _mutex.close();
}

/// Development fallback that always reports "first instance"; it provides no
/// cross-process exclusion at all.
class NullSingleInstanceGuard implements SingleInstanceGuard {
  /// Creates the fallback guard.
  const NullSingleInstanceGuard();

  @override
  bool tryAcquire() => true;

  @override
  void dispose() {
    // Nothing was acquired.
  }
}

/// True when a GUI instance is running: it holds the mutex called [name].
///
/// Opens the mutex (it never creates one) and closes the handle straight away.
/// False off Windows and on any error: the headless run uses this to leave its
/// failure notice to the GUI, and an unanswered check must not silence it.
bool singleInstanceIsHeld([String name = singleInstanceMutexName]) {
  if (!Platform.isWindows) return false;

  final Pointer<Utf16> namePtr = name.toNativeUtf16();
  try {
    final Pointer handle = _openMutexW(_synchronize, FALSE, namePtr);
    if (handle == nullptr) return false;
    CloseHandle(HANDLE(handle));
    return true;
  } catch (_) {
    return false;
  } finally {
    malloc.free(namePtr);
  }
}

/// Class of the hidden window that owns the tray icon (kHostClassName in
/// windows/runner/tray_icon.cpp). Only the instance holding the single-instance
/// mutex creates one, so finding it finds that instance.
const String trayHostWindowClass = 'EZSide.TrayHost';

/// WM_APP + 2, kShowAppMessage in tray_icon.cpp: "show, restore and focus".
const int _showAppMessage = 0x8000 + 2;

/// Asks the running GUI instance to show, restore and focus its window. Called
/// by a second launch just before it exits.
///
/// The running instance makes its tray window only once its Dart side is up, so
/// a launch that races a starting instance looks again, up to [attempts] times
/// [interval] apart. Returns whether the request was posted. A no-op off
/// Windows, and it never throws: the second launch exits either way.
bool showRunningInstance({
  String windowClass = trayHostWindowClass,
  int attempts = 20,
  Duration interval = const Duration(milliseconds: 250),
}) {
  if (!Platform.isWindows) return false;

  final Pointer<Utf16> className = windowClass.toNativeUtf16();
  final Pointer<Uint32> processId = calloc<Uint32>();
  try {
    for (int attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) sleep(interval);
      final Pointer window = _findWindowW(className, nullptr);
      if (window == nullptr) continue;

      // This launch is what the user just started, so it may take the
      // foreground; handing that right over is what lets the running instance
      // raise its window instead of only flashing its taskbar button.
      _getWindowThreadProcessId(window, processId);
      _allowSetForegroundWindow(processId.value);
      return _postMessageW(window, _showAppMessage, 0, 0) != 0;
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    malloc.free(className);
    calloc.free(processId);
  }
}

/// The marker mutex the Inno Setup installer watches through its `AppMutex`
/// directive, so it can refuse to install over a running EZSide.
///
/// It is never used for single-instance gating (that is
/// [singleInstanceMutexName]). It must be held by BOTH the GUI and the headless
/// `--auto-refresh` path, because the installer has to detect ANY running
/// EZSide process - including a background refresh that the single-instance
/// mutex deliberately does not cover.
///
/// Holding it more than once in a process is harmless: each hold is a separate
/// handle to the same named object, and the object lives until the last one is
/// closed.
class RunningAppMarker {
  RunningAppMarker._(this._mutex);

  /// Creates and holds the marker for the lifetime of this process.
  ///
  /// Never throws, and is a no-op off Windows: losing the marker only costs the
  /// installer its running-app detection, so it must never block startup.
  factory RunningAppMarker.hold([String name = runningMutexName]) {
    if (!Platform.isWindows) return RunningAppMarker._(null);

    final _NamedMutex mutex = _NamedMutex(name);
    try {
      // Not owned exclusively - existence is the whole signal.
      mutex.create(initiallyOwned: false);
      return RunningAppMarker._(mutex);
    } catch (_) {
      return RunningAppMarker._(null);
    }
  }

  final _NamedMutex? _mutex;

  /// Drops the marker. The OS also drops it when the process exits.
  void dispose() => _mutex?.close();
}

/// A named Win32 mutex: the primitive behind both the single-instance guard and
/// the installer's running-app marker.
class _NamedMutex {
  _NamedMutex(this.name);

  final String name;
  HANDLE? _handle;
  bool _owned = false;

  /// Creates the mutex, requesting initial ownership when [initiallyOwned].
  ///
  /// Returns false only when the mutex ALREADY existed, i.e. another EZSide
  /// process created it first. A creation *failure* returns true, because no OS
  /// primitive may be the reason the app refuses to start; the worst case is a
  /// second window.
  bool create({required bool initiallyOwned}) {
    final Pointer<Utf16> namePtr = name.toNativeUtf16();
    try {
      // package:win32 binds GetLastError lazily; resolve it up front so that
      // resolution cannot clobber the error code CreateMutexW is about to set.
      GetLastError();
      final HANDLE handle = HANDLE(
        _createMutexW(nullptr, initiallyOwned ? TRUE : FALSE, namePtr),
      );
      final int error = GetLastError();

      if (!handle.isValid) return true;

      _handle = handle;
      // bInitialOwner only grants ownership to the process that created the
      // mutex, so an existing mutex is never owned here.
      final bool alreadyExisted = error == ERROR_ALREADY_EXISTS;
      _owned = initiallyOwned && !alreadyExisted;
      return !alreadyExisted;
    } finally {
      malloc.free(namePtr);
    }
  }

  /// Releases ownership if held and closes the handle.
  void close() {
    final HANDLE? handle = _handle;
    if (handle == null) return;
    _handle = null;

    try {
      if (_owned) _releaseMutex(handle);
    } catch (_) {
      // The OS abandons the mutex at process exit regardless.
    } finally {
      _owned = false;
      CloseHandle(handle);
    }
  }
}

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

// CreateMutexW and ReleaseMutex are not part of package:win32 6.x, so they are
// bound here; the constants and HANDLE wrapper still come from the package.
final Pointer Function(Pointer, int, Pointer<Utf16>) _createMutexW = _kernel32
    .lookupFunction<
      Pointer Function(Pointer, Int32, Pointer<Utf16>),
      Pointer Function(Pointer, int, Pointer<Utf16>)
    >('CreateMutexW');

// SYNCHRONIZE: the least access that opens a mutex.
const int _synchronize = 0x00100000;

final Pointer Function(int, int, Pointer<Utf16>) _openMutexW = _kernel32
    .lookupFunction<
      Pointer Function(Uint32, Int32, Pointer<Utf16>),
      Pointer Function(int, int, Pointer<Utf16>)
    >('OpenMutexW');

final int Function(Pointer) _releaseMutex = _kernel32
    .lookupFunction<Int32 Function(Pointer), int Function(Pointer)>(
      'ReleaseMutex',
    );

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

// Bound by hand for the same reason as CreateMutexW above.
final Pointer Function(Pointer<Utf16>, Pointer<Utf16>) _findWindowW = _user32
    .lookupFunction<
      Pointer Function(Pointer<Utf16>, Pointer<Utf16>),
      Pointer Function(Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowW');

final int Function(Pointer, Pointer<Uint32>) _getWindowThreadProcessId = _user32
    .lookupFunction<
      Uint32 Function(Pointer, Pointer<Uint32>),
      int Function(Pointer, Pointer<Uint32>)
    >('GetWindowThreadProcessId');

final int Function(int) _allowSetForegroundWindow = _user32
    .lookupFunction<Int32 Function(Uint32), int Function(int)>(
      'AllowSetForegroundWindow',
    );

final int Function(Pointer, int, int, int) _postMessageW = _user32
    .lookupFunction<
      Int32 Function(Pointer, Uint32, IntPtr, IntPtr),
      int Function(Pointer, int, int, int)
    >('PostMessageW');
