import 'package:flutter/material.dart';
import 'palette.dart';
import 'tokens.dart';
import 'typography.dart';

export 'palette.dart';
export 'tokens.dart';
export 'typography.dart';

/// Builds the [ThemeData] for a variant and attaches the matching [AppPalette].
///
/// Material's own component themes are only configured far enough to keep
/// stock widgets (text fields, scrollbars, selection) on-palette — the app's
/// surfaces are all custom, so most Material styling is deliberately unused.
ThemeData buildAppTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: Fonts.sans,
    scaffoldBackgroundColor: p.bg0,
    canvasColor: p.bg0,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    colorScheme: ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: brightness,
    ).copyWith(
      primary: p.accent,
      onPrimary: p.onAccent,
      surface: p.bg1,
      onSurface: p.textPrimary,
      error: p.danger,
      onError: p.onAccent,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accentSelection,
      selectionHandleColor: p.accent,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(8),
      radius: const Radius.circular(Radii.full),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered) ? p.hairlineStrong : p.hairline,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: p.bg2,
        borderRadius: Radii.rSmall,
        border: Border.all(color: p.hairline),
      ),
      textStyle: TextStyle(
        fontFamily: Fonts.sans,
        fontSize: FontSizes.small,
        color: p.textPrimary,
      ),
    ),
    extensions: [p],
  );
}

/// Ergonomic access to the palette and type scale from any widget.
extension AppThemeContext on BuildContext {
  AppPalette get palette => Theme.of(this).extension<AppPalette>() ?? AppPalette.dark;

  AppTextStyles get t => AppTextStyles(palette);
}
