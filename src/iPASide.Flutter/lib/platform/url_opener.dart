import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Opens [url] in the default handler and reports whether it was accepted.
typedef UrlOpener = Future<bool> Function(String url);

/// `SW_SHOWNORMAL`.
const int _showNormal = 1;

/// Opens an http(s) [url] in the user's default browser.
///
/// The URL goes straight to `ShellExecuteW`, never through `cmd`, so `&`, `^`
/// or `%` in it cannot be read as shell syntax. Anything that is not an
/// absolute http or https URL is refused without touching the shell. Returns
/// false when refused, off Windows, or when the shell reports a failure.
Future<bool> openUrl(String url) async {
  final Uri? parsed = Uri.tryParse(url.trim());
  if (parsed == null ||
      !(parsed.isScheme('https') || parsed.isScheme('http'))) {
    return false;
  }
  if (!Platform.isWindows) return false;

  final Pointer<Utf16> operation = 'open'.toNativeUtf16();
  final Pointer<Utf16> file = parsed.toString().toNativeUtf16();
  try {
    // ShellExecuteW returns an HINSTANCE that is greater than 32 on success.
    return _shellExecuteW(
          nullptr,
          operation,
          file,
          nullptr,
          nullptr,
          _showNormal,
        ) >
        32;
  } finally {
    malloc.free(operation);
    malloc.free(file);
  }
}

final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');

// Bound by hand, like CreateMutexW in single_instance.dart, so this does not
// depend on how package:win32 6.x wraps its parameters.
final int Function(
  Pointer,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Pointer,
  Pointer,
  int,
)
_shellExecuteW = _shell32.lookupFunction<
    IntPtr Function(
      Pointer,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer,
      Pointer,
      Int32,
    ),
    int Function(
      Pointer,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer,
      Pointer,
      int,
    )>('ShellExecuteW');
