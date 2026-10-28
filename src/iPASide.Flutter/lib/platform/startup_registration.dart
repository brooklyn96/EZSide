import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Thrown when the Run key cannot be read or changed. [message] is
/// presentable as it stands.
class StartupRegistrationException implements Exception {
  StartupRegistrationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The one registry value "Start with Windows" lives in, behind a seam so tests
/// never touch the real registry.
abstract class RunKeyStore {
  /// The value's data, or null when there is no such value.
  String? read(String name);

  /// Creates or replaces the value as a `REG_SZ`.
  void write(String name, String data);

  /// Removes the value. Removing a value that is not there is a success.
  void delete(String name);
}

/// "Start EZSide with Windows (in the tray)": an entry in the current user's
/// Run key that launches this exe with [trayArg] at sign-in.
///
/// Off by default: nothing is written until [setEnabled] is called with true.
/// Every read goes to the registry, so the toggles always show the real state.
class StartupRegistration {
  /// [exePath] defaults to the running exe; [store] to the real Run key on
  /// Windows and to none elsewhere, which makes the feature unsupported.
  StartupRegistration({String? exePath, RunKeyStore? store})
    : _exePath = exePath ?? Platform.resolvedExecutable,
      _store = store ?? (Platform.isWindows ? WindowsRunKeyStore() : null);

  static const runKeyPath = r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const valueName = 'EZSide';
  static const trayArg = '--tray';

  final String _exePath;
  final RunKeyStore? _store;

  /// False off Windows: there is no Run key to write.
  bool get isSupported => _store != null;

  /// The exact command line the Run value carries.
  String get command => '"$_exePath" $trayArg';

  /// True only when the value exists and launches THIS exe in the tray. A value
  /// left by another install (a moved or older copy) counts as off.
  ///
  /// Throws [StartupRegistrationException] when the key cannot be read.
  Future<bool> isEnabled() async {
    final String? data = _store?.read(valueName);
    return data != null && data.trim().toLowerCase() == command.toLowerCase();
  }

  /// Writes or removes the Run value. Turning on rewrites a value that points
  /// elsewhere, or one that cannot be read; turning off something already off
  /// is a success. A no-op when [isSupported] is false.
  Future<void> setEnabled(bool on) async {
    final RunKeyStore? store = _store;
    if (store == null) return;
    if (!on) {
      store.delete(valueName);
      return;
    }
    bool current;
    try {
      current = await isEnabled();
    } on StartupRegistrationException {
      current = false; // an unreadable value is repaired by writing over it
    }
    if (!current) store.write(valueName, command);
  }
}

/// [RunKeyStore] over `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
///
/// The three advapi32 calls are bound by hand, like `CreateMutexW` in
/// single_instance.dart, so this does not depend on how package:win32 6.x
/// wraps its parameters. Each one names the subkey itself, so no key handle is
/// ever opened or leaked.
class WindowsRunKeyStore implements RunKeyStore {
  @override
  String? read(String name) {
    final Pointer<Utf16> subKey = StartupRegistration.runKeyPath
        .toNativeUtf16();
    final Pointer<Utf16> value = name.toNativeUtf16();
    final Pointer<Uint32> size = calloc<Uint32>();
    try {
      // Ask for the size, then fetch; repeat if the value grew in between.
      while (true) {
        size.value = 0;
        int status = _regGetValueW(
          _hkeyCurrentUser,
          subKey,
          value,
          _rrfReadFlags,
          nullptr,
          nullptr,
          size,
        );
        if (status == _errorFileNotFound) return null;
        _check(status, 'read');

        final Pointer<Uint8> buffer = calloc<Uint8>(size.value);
        try {
          status = _regGetValueW(
            _hkeyCurrentUser,
            subKey,
            value,
            _rrfReadFlags,
            nullptr,
            buffer,
            size,
          );
          if (status == _errorMoreData) continue;
          if (status == _errorFileNotFound) return null;
          _check(status, 'read');
          return buffer.cast<Utf16>().toDartString();
        } finally {
          calloc.free(buffer);
        }
      }
    } finally {
      calloc.free(subKey);
      calloc.free(value);
      calloc.free(size);
    }
  }

  @override
  void write(String name, String data) {
    final Pointer<Utf16> subKey = StartupRegistration.runKeyPath
        .toNativeUtf16();
    final Pointer<Utf16> value = name.toNativeUtf16();
    final Pointer<Utf16> text = data.toNativeUtf16();
    try {
      // The byte count includes the terminating NUL, as REG_SZ requires.
      final int status = _regSetKeyValueW(
        _hkeyCurrentUser,
        subKey,
        value,
        _regSz,
        text,
        (data.length + 1) * 2,
      );
      _check(status, 'write');
    } finally {
      calloc.free(subKey);
      calloc.free(value);
      calloc.free(text);
    }
  }

  @override
  void delete(String name) {
    final Pointer<Utf16> subKey = StartupRegistration.runKeyPath
        .toNativeUtf16();
    final Pointer<Utf16> value = name.toNativeUtf16();
    try {
      final int status = _regDeleteKeyValueW(_hkeyCurrentUser, subKey, value);
      if (status == _errorFileNotFound) return;
      _check(status, 'remove');
    } finally {
      calloc.free(subKey);
      calloc.free(value);
    }
  }

  static void _check(int status, String verb) {
    if (status != _errorSuccess) {
      throw StartupRegistrationException(
        "Couldn't $verb the Windows startup entry (error $status).",
      );
    }
  }
}

// HKEY_CURRENT_USER, as package:win32 5.x passed it.
const int _hkeyCurrentUser = 0x80000001;
const int _regSz = 1;
// RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_NOEXPAND: a hand-edited
// REG_EXPAND_SZ value is read as written (so it shows as off and is
// rewritten), not refused with ERROR_UNSUPPORTED_TYPE.
const int _rrfReadFlags = 0x00000002 | 0x00000004 | 0x10000000;
const int _errorSuccess = 0;
const int _errorFileNotFound = 2;
const int _errorMoreData = 234;

final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');

final int Function(
  int,
  Pointer<Utf16>,
  Pointer<Utf16>,
  int,
  Pointer,
  Pointer,
  Pointer<Uint32>,
)
_regGetValueW = _advapi32.lookupFunction<
    Int32 Function(
      IntPtr,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Uint32,
      Pointer,
      Pointer,
      Pointer<Uint32>,
    ),
    int Function(
      int,
      Pointer<Utf16>,
      Pointer<Utf16>,
      int,
      Pointer,
      Pointer,
      Pointer<Uint32>,
    )>('RegGetValueW');

final int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer, int)
_regSetKeyValueW = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer,
        Uint32),
    int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer, int)>(
  'RegSetKeyValueW',
);

final int Function(int, Pointer<Utf16>, Pointer<Utf16>) _regDeleteKeyValueW =
    _advapi32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>),
      int Function(int, Pointer<Utf16>, Pointer<Utf16>)
    >('RegDeleteKeyValueW');
