import 'package:flutter/widgets.dart';
import 'palette.dart';
import 'tokens.dart';

/// The named type scale, resolved against the active [AppPalette].
///
/// Reach for these through `context.t` rather than building [TextStyle]s
/// inline, so colour follows the theme variant automatically.
class AppTextStyles {
  const AppTextStyles(this._p);

  final AppPalette _p;

  /// Page headline.
  TextStyle get display => TextStyle(
        fontFamily: Fonts.sans,
        fontSize: FontSizes.display,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        height: 1.2,
        color: _p.textPrimary,
      );

  /// Card / section heading.
  TextStyle get title => TextStyle(
        fontFamily: Fonts.sans,
        fontSize: FontSizes.title,
        fontWeight: FontWeight.w600,
        color: _p.textPrimary,
      );

  TextStyle get body => TextStyle(
        fontFamily: Fonts.sans,
        fontSize: FontSizes.body,
        height: 1.45,
        color: _p.textPrimary,
      );

  TextStyle get bodyMuted => body.copyWith(color: _p.textSecondary, height: 1.5);

  TextStyle get small => TextStyle(
        fontFamily: Fonts.sans,
        fontSize: FontSizes.small,
        color: _p.textPrimary,
      );

  TextStyle get smallMuted => small.copyWith(color: _p.textSecondary);

  TextStyle get faint => small.copyWith(color: _p.textMuted);

  /// Uppercase section label (`STATUS`, `QUICK ACTIONS`, …).
  TextStyle get caption => TextStyle(
        fontFamily: Fonts.sans,
        fontSize: FontSizes.caption,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
        color: _p.textSecondary,
      );

  TextStyle get mono => TextStyle(
        fontFamily: Fonts.mono,
        fontFamilyFallback: Fonts.monoFallback,
        fontSize: FontSizes.small,
        color: _p.textPrimary,
      );

  TextStyle get wordmark => TextStyle(
        fontFamily: Fonts.sans,
        fontSize: FontSizes.wordmark,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
        color: _p.textPrimary,
      );

  /// Label sitting on an accent-filled surface.
  TextStyle get onAccent => TextStyle(
        fontFamily: Fonts.sans,
        fontSize: FontSizes.body,
        fontWeight: FontWeight.w600,
        color: _p.onAccent,
      );

  /// Semibold at an arbitrary size, for one-off emphasis.
  TextStyle semi(double size) => TextStyle(
        fontFamily: Fonts.sans,
        fontSize: size,
        fontWeight: FontWeight.w600,
        color: _p.textPrimary,
      );
}
