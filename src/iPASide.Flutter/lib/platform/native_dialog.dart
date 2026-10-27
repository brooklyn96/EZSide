import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Shows a modal notice with a [title] and a [message]. Injectable so callers
/// can be tested without opening a real window.
typedef NoticeDialog = void Function(String title, String message);

// MB_OK (0) | MB_ICONWARNING | MB_SETFOREGROUND | MB_TOPMOST.
const int _warningStyle = 0x00000030 | 0x00010000 | 0x00040000;

/// Shows a native Windows warning message box and blocks until it is closed.
///
/// Used by the headless `--auto-refresh` run, which has no Flutter window to
/// show anything in. A no-op off Windows, and it never throws: a notice that
/// cannot be shown must not change the exit code of the run it describes.
///
/// `MessageBoxW` is bound by hand, like `CreateMutexW` in single_instance.dart,
/// so this does not depend on how package:win32 6.x wraps its parameters.
void showWarningNotice(String title, String message) {
  if (!Platform.isWindows) return;

  final Pointer<Utf16> text = message.toNativeUtf16();
  final Pointer<Utf16> caption = title.toNativeUtf16();
  try {
    _messageBoxW(nullptr, text, caption, _warningStyle);
  } catch (_) {
    // Nothing else to try; the log already holds the failure.
  } finally {
    malloc.free(text);
    malloc.free(caption);
  }
}

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

final int Function(Pointer, Pointer<Utf16>, Pointer<Utf16>, int) _messageBoxW =
    _user32.lookupFunction<
      Int32 Function(Pointer, Pointer<Utf16>, Pointer<Utf16>, Uint32),
      int Function(Pointer, Pointer<Utf16>, Pointer<Utf16>, int)
    >('MessageBoxW');
