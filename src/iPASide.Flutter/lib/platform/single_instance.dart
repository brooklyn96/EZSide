// Ported from iPASide.App/Platform/ISingleInstanceGuard.cs,
// iPASide.Platform.Windows/WindowsSingleInstanceGuard.cs, the
// NullSingleInstanceGuard in iPASide.App/Platform/Fallbacks.cs, and the
// RunningMutexName marker held by iPASide.App/Program.cs.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Name of the mutex held by the first GUI instance.
const String singleInstanceMutexName = 'iPASide.SingleInstance.Mutex';

/// Name of the marker mutex held for the lifetime of EVERY iPASide process.
const String runningMutexName = 'iPASide.Running.Mutex';

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
/// A second launch is expected to exit silently with code 0. It deliberately
/// does NOT activate or focus the window of the running instance - the C# app
/// never did, and reproducing that would need a window handshake this guard has
/// no channel for.
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

/// The marker mutex the Inno Setup installer watches through its `AppMutex`
/// directive, so it can refuse to install over a running iPASide.
///
/// It is never used for single-instance gating (that is
/// [singleInstanceMutexName]). It must be held by BOTH the GUI and the headless
/// `--auto-refresh` path, because the installer has to detect ANY running
/// iPASide process - including a background refresh that the single-instance
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
  /// Returns false only when the mutex ALREADY existed, i.e. another iPASide
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

final int Function(Pointer) _releaseMutex = _kernel32
    .lookupFunction<Int32 Function(Pointer), int Function(Pointer)>(
      'ReleaseMutex',
    );
