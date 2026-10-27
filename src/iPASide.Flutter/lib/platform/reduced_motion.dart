// Ported from iPASide.App/Platform/IReducedMotionProvider.cs,
// iPASide.Platform.Windows/WindowsReducedMotionProvider.cs and the
// DefaultReducedMotionProvider in iPASide.App/Platform/Fallbacks.cs.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Exposes the OS "reduce motion" accessibility preference, read once at startup
/// to gate UI transitions and animations.
abstract class ReducedMotionProvider {
  /// True when the user asked the OS to minimize animations.
  bool isReducedMotion();
}

/// The provider for this OS: the Windows accessibility read, or the fallback
/// that leaves motion enabled.
ReducedMotionProvider createReducedMotionProvider() => Platform.isWindows
    ? const WindowsReducedMotionProvider()
    : const DefaultReducedMotionProvider();

/// Reads the Windows "Animation effects" accessibility setting
/// (`SPI_GETCLIENTAREAANIMATION`, 0x1042) so the UI can honor reduced motion.
class WindowsReducedMotionProvider implements ReducedMotionProvider {
  /// Creates the provider; each call re-reads the OS setting.
  const WindowsReducedMotionProvider();

  @override
  bool isReducedMotion() {
    // The Win32 bindings resolve user32.dll lazily, so merely importing
    // package:win32 is safe off-Windows - calling into it is not.
    if (!Platform.isWindows) return false;

    // SPI_GETCLIENTAREAANIMATION writes a 4-byte BOOL, not a Dart bool.
    final Pointer<Int32> animationsEnabled = calloc<Int32>();
    try {
      final bool queried = SystemParametersInfo(
        SPI_GETCLIENTAREAANIMATION,
        0,
        animationsEnabled,
        const SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
      ).value;
      // Reduced motion only when the query succeeded AND animations are off; a
      // failed query must not silently disable every animation in the app.
      return queried && animationsEnabled.value == FALSE;
    } catch (_) {
      return false;
    } finally {
      calloc.free(animationsEnabled);
    }
  }
}

/// Fallback for OSes without a wired-up accessibility read: motion stays
/// enabled.
class DefaultReducedMotionProvider implements ReducedMotionProvider {
  /// Creates the fallback provider.
  const DefaultReducedMotionProvider();

  @override
  bool isReducedMotion() => false;
}
