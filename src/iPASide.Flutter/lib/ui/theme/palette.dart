import 'package:flutter/material.dart';

/// Theme-variant colour set, carried as a [ThemeExtension] so a light/dark
/// switch re-resolves (and can animate) every surface at once.
///
/// Values mirror the previous Avalonia `Palette.axaml`. The single restrained
/// indigo accent (#5E6AD2 family) is used everywhere; the indigo→violet
/// gradient is reserved for the primary action and the logo mark.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.bg0,
    required this.bg1,
    required this.bg2,
    required this.inputBg,
    required this.surfaceHover,
    required this.surfacePressed,
    required this.hairline,
    required this.hairlineStrong,
    required this.scrim,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.accentHover,
    required this.accentPressed,
    required this.accentSubtle,
    required this.accentSelection,
    required this.accentDisabled,
    required this.onAccent,
    required this.onAccentMuted,
    required this.focusRing,
    required this.cardBorder,
    required this.cardBorderHover,
    required this.success,
    required this.successBg,
    required this.warning,
    required this.warningBg,
    required this.danger,
    required this.dangerHover,
    required this.dangerPressed,
    required this.dangerDisabled,
    required this.dangerBg,
    required this.appBgStops,
    required this.sidebarBgStops,
    required this.cardBgStops,
    required this.cardHoverBgStops,
    required this.accentGradientStops,
    required this.accentGradientHoverStops,
    required this.heroBgStops,
    required this.heroStops,
    required this.cardShadow,
    required this.liftShadow,
    required this.accentGlow,
  });

  final Brightness brightness;

  // Surfaces
  final Color bg0;
  final Color bg1;
  final Color bg2;
  final Color inputBg;
  final Color surfaceHover;
  final Color surfacePressed;
  final Color hairline;
  final Color hairlineStrong;
  final Color scrim;

  // Text
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  // Accent
  final Color accent;
  final Color accentHover;
  final Color accentPressed;
  final Color accentSubtle;
  final Color accentSelection;
  final Color accentDisabled;
  final Color onAccent;
  final Color onAccentMuted;
  final Color focusRing;

  // Cards
  final Color cardBorder;
  final Color cardBorderHover;

  // Semantic
  final Color success;
  final Color successBg;
  final Color warning;
  final Color warningBg;
  final Color danger;
  final Color dangerHover;
  final Color dangerPressed;
  final Color dangerDisabled;
  final Color dangerBg;

  // Gradient stop colours
  final List<Color> appBgStops;
  final List<Color> sidebarBgStops;
  final List<Color> cardBgStops;
  final List<Color> cardHoverBgStops;
  final List<Color> accentGradientStops;
  final List<Color> accentGradientHoverStops;
  final List<Color> heroBgStops;

  /// Hero gradient offsets — the mid stop differs between variants.
  final List<double> heroStops;

  // Elevation
  final List<BoxShadow> cardShadow;
  final List<BoxShadow> liftShadow;
  final List<BoxShadow> accentGlow;

  bool get isDark => brightness == Brightness.dark;

  LinearGradient get appGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: appBgStops,
      );

  LinearGradient get sidebarGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: sidebarBgStops,
      );

  LinearGradient get cardGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: cardBgStops,
      );

  LinearGradient get cardHoverGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: cardHoverBgStops,
      );

  LinearGradient get accentGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: accentGradientStops,
      );

  LinearGradient get accentGradientHover => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: accentGradientHoverStops,
      );

  LinearGradient get heroGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: heroBgStops,
        stops: heroStops,
      );

  static const dark = AppPalette(
    brightness: Brightness.dark,
    bg0: Color(0xFF0B0B0D),
    bg1: Color(0xFF121215),
    bg2: Color(0xFF1A1A1F),
    inputBg: Color(0xFF0F0F13),
    surfaceHover: Color(0xFF202027),
    surfacePressed: Color(0xFF26262E),
    hairline: Color(0xFF26262C),
    hairlineStrong: Color(0xFF34343C),
    scrim: Color(0x99000000),
    textPrimary: Color(0xFFEDEDEF),
    textSecondary: Color(0xFF9C9CA6),
    textMuted: Color(0xFF6B6B76),
    accent: Color(0xFF5E6AD2),
    accentHover: Color(0xFF6D78DB),
    accentPressed: Color(0xFF4F5AC2),
    accentSubtle: Color(0x265E6AD2),
    accentSelection: Color(0x4D5E6AD2),
    accentDisabled: Color(0x665E6AD2),
    onAccent: Color(0xFFFFFFFF),
    onAccentMuted: Color(0x99FFFFFF),
    focusRing: Color(0xFF7D88E0),
    cardBorder: Color(0xFF2C2C37),
    cardBorderHover: Color(0xFF3A3A46),
    success: Color(0xFF4CC38A),
    successBg: Color(0x264CC38A),
    warning: Color(0xFFF0B429),
    warningBg: Color(0x26F0B429),
    danger: Color(0xFFE5484D),
    dangerHover: Color(0xFFEC5D62),
    dangerPressed: Color(0xFFD93D42),
    dangerDisabled: Color(0x66E5484D),
    dangerBg: Color(0x26E5484D),
    appBgStops: [Color(0xFF0E0E13), Color(0xFF08080A)],
    sidebarBgStops: [Color(0xFF101016), Color(0xFF0A0A0E)],
    cardBgStops: [Color(0xFF1B1B23), Color(0xFF141419)],
    cardHoverBgStops: [Color(0xFF212129), Color(0xFF18181E)],
    accentGradientStops: [Color(0xFF6672E6), Color(0xFF8C5CF0)],
    accentGradientHoverStops: [Color(0xFF7883EF), Color(0xFF9C6DFB)],
    heroBgStops: [Color(0xFF262750), Color(0xFF191A2A), Color(0xFF141419)],
    heroStops: [0.0, 0.6, 1.0],
    cardShadow: [
      BoxShadow(color: Color(0x59000000), blurRadius: 16, offset: Offset(0, 4), spreadRadius: -4),
    ],
    liftShadow: [
      BoxShadow(color: Color(0x6E000000), blurRadius: 30, offset: Offset(0, 10), spreadRadius: -6),
    ],
    accentGlow: [
      BoxShadow(color: Color(0x6E6672E6), blurRadius: 22, offset: Offset(0, 6), spreadRadius: -4),
      BoxShadow(color: Color(0x40000000), blurRadius: 3, offset: Offset(0, 1)),
    ],
  );

  /// Light variant. Elevation is deliberately softer than dark: the dark
  /// build's near-opaque black shadows read as smudges on white surfaces.
  static const light = AppPalette(
    brightness: Brightness.light,
    bg0: Color(0xFFFAFAFB),
    bg1: Color(0xFFFFFFFF),
    bg2: Color(0xFFF4F4F6),
    inputBg: Color(0xFFFFFFFF),
    surfaceHover: Color(0xFFEFEFF1),
    surfacePressed: Color(0xFFE6E6EA),
    hairline: Color(0xFFE5E5EA),
    hairlineStrong: Color(0xFFD4D4DB),
    scrim: Color(0x59000000),
    textPrimary: Color(0xFF1C1C21),
    textSecondary: Color(0xFF6E6E78),
    textMuted: Color(0xFF9A9AA3),
    accent: Color(0xFF5E6AD2),
    accentHover: Color(0xFF4F5BC4),
    accentPressed: Color(0xFF4450B2),
    accentSubtle: Color(0x1A5E6AD2),
    accentSelection: Color(0x405E6AD2),
    accentDisabled: Color(0x665E6AD2),
    onAccent: Color(0xFFFFFFFF),
    onAccentMuted: Color(0xB3FFFFFF),
    focusRing: Color(0xFF5E6AD2),
    cardBorder: Color(0xFFE4E4EA),
    cardBorderHover: Color(0xFFD2D2DC),
    success: Color(0xFF18794E),
    successBg: Color(0x1A18794E),
    warning: Color(0xFF9E6C00),
    warningBg: Color(0x1A9E6C00),
    danger: Color(0xFFCE2C31),
    dangerHover: Color(0xFFB7282D),
    dangerPressed: Color(0xFFA02226),
    dangerDisabled: Color(0x66CE2C31),
    dangerBg: Color(0x14CE2C31),
    appBgStops: [Color(0xFFFBFBFD), Color(0xFFF1F1F5)],
    sidebarBgStops: [Color(0xFFF6F6F9), Color(0xFFEFEFF3)],
    cardBgStops: [Color(0xFFFFFFFF), Color(0xFFFBFBFD)],
    cardHoverBgStops: [Color(0xFFFFFFFF), Color(0xFFF6F6FA)],
    accentGradientStops: [Color(0xFF5E6AD2), Color(0xFF8257E0)],
    accentGradientHoverStops: [Color(0xFF5460C6), Color(0xFF754BD4)],
    heroBgStops: [Color(0xFFE9EAFB), Color(0xFFF4F4FA), Color(0xFFFFFFFF)],
    heroStops: [0.0, 0.7, 1.0],
    cardShadow: [
      BoxShadow(color: Color(0x14000000), blurRadius: 14, offset: Offset(0, 3), spreadRadius: -4),
    ],
    liftShadow: [
      BoxShadow(color: Color(0x24000000), blurRadius: 26, offset: Offset(0, 10), spreadRadius: -8),
    ],
    accentGlow: [
      BoxShadow(color: Color(0x455E6AD2), blurRadius: 20, offset: Offset(0, 6), spreadRadius: -5),
      BoxShadow(color: Color(0x14000000), blurRadius: 3, offset: Offset(0, 1)),
    ],
  );

  @override
  AppPalette copyWith({Brightness? brightness}) =>
      brightness == null || brightness == this.brightness
          ? this
          : (brightness == Brightness.dark ? dark : light);

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    List<Color> cs(List<Color> a, List<Color> b) => [
          for (var i = 0; i < a.length; i++) c(a[i], b[i]),
        ];
    List<double> ds(List<double> a, List<double> b) => [
          for (var i = 0; i < a.length; i++) a[i] + (b[i] - a[i]) * t,
        ];
    List<BoxShadow> ss(List<BoxShadow> a, List<BoxShadow> b) =>
        BoxShadow.lerpList(a, b, t) ?? b;

    return AppPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      bg0: c(bg0, other.bg0),
      bg1: c(bg1, other.bg1),
      bg2: c(bg2, other.bg2),
      inputBg: c(inputBg, other.inputBg),
      surfaceHover: c(surfaceHover, other.surfaceHover),
      surfacePressed: c(surfacePressed, other.surfacePressed),
      hairline: c(hairline, other.hairline),
      hairlineStrong: c(hairlineStrong, other.hairlineStrong),
      scrim: c(scrim, other.scrim),
      textPrimary: c(textPrimary, other.textPrimary),
      textSecondary: c(textSecondary, other.textSecondary),
      textMuted: c(textMuted, other.textMuted),
      accent: c(accent, other.accent),
      accentHover: c(accentHover, other.accentHover),
      accentPressed: c(accentPressed, other.accentPressed),
      accentSubtle: c(accentSubtle, other.accentSubtle),
      accentSelection: c(accentSelection, other.accentSelection),
      accentDisabled: c(accentDisabled, other.accentDisabled),
      onAccent: c(onAccent, other.onAccent),
      onAccentMuted: c(onAccentMuted, other.onAccentMuted),
      focusRing: c(focusRing, other.focusRing),
      cardBorder: c(cardBorder, other.cardBorder),
      cardBorderHover: c(cardBorderHover, other.cardBorderHover),
      success: c(success, other.success),
      successBg: c(successBg, other.successBg),
      warning: c(warning, other.warning),
      warningBg: c(warningBg, other.warningBg),
      danger: c(danger, other.danger),
      dangerHover: c(dangerHover, other.dangerHover),
      dangerPressed: c(dangerPressed, other.dangerPressed),
      dangerDisabled: c(dangerDisabled, other.dangerDisabled),
      dangerBg: c(dangerBg, other.dangerBg),
      appBgStops: cs(appBgStops, other.appBgStops),
      sidebarBgStops: cs(sidebarBgStops, other.sidebarBgStops),
      cardBgStops: cs(cardBgStops, other.cardBgStops),
      cardHoverBgStops: cs(cardHoverBgStops, other.cardHoverBgStops),
      accentGradientStops: cs(accentGradientStops, other.accentGradientStops),
      accentGradientHoverStops: cs(accentGradientHoverStops, other.accentGradientHoverStops),
      heroBgStops: cs(heroBgStops, other.heroBgStops),
      heroStops: ds(heroStops, other.heroStops),
      cardShadow: ss(cardShadow, other.cardShadow),
      liftShadow: ss(liftShadow, other.liftShadow),
      accentGlow: ss(accentGlow, other.accentGlow),
    );
  }
}
