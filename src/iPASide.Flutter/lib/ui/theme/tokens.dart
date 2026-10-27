/// Variant-invariant design tokens: spacing (4-pt grid), radii, motion and
/// sizing. Colour lives in `palette.dart`, type in `typography.dart`.
///
/// Values mirror the previous Avalonia `Tokens.axaml` so the two builds are
/// visually interchangeable during the migration.
library;

import 'package:flutter/widgets.dart';

/// 4-pt spacing grid.
abstract final class Space {
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  static const double s6 = 24;
  static const double s7 = 28;
  static const double s8 = 32;
}

/// Common composed paddings.
abstract final class Pad {
  static const button = EdgeInsets.symmetric(horizontal: 14, vertical: 8);
  static const buttonSmall = EdgeInsets.symmetric(horizontal: 10, vertical: 5);
  static const input = EdgeInsets.symmetric(horizontal: 10, vertical: 7);
  static const card = EdgeInsets.all(16);
  static const cardLarge = EdgeInsets.all(20);
  static const chip = EdgeInsets.symmetric(horizontal: 10, vertical: 3);
  static const alert = EdgeInsets.symmetric(horizontal: 14, vertical: 12);
  static const listItem = EdgeInsets.symmetric(horizontal: 10, vertical: 7);
  static const page = EdgeInsets.all(24);
  static const dialog = EdgeInsets.all(20);

  /// A settings section's header, above the rule that separates it from the
  /// first row.
  static const settingsHeader = EdgeInsets.fromLTRB(20, 20, 20, 12);

  /// One settings row: the section's horizontal inset, and the vertical rhythm
  /// every row in every section repeats.
  static const settingsRow = EdgeInsets.symmetric(horizontal: 20, vertical: 16);

  /// One label/value line inside a status card. Shared by every kind of row that
  /// appears in one, so cards sitting side by side keep the same rhythm and their
  /// lines land at the same heights.
  static const statusRow = EdgeInsets.symmetric(vertical: 3);

  static const dropzone = EdgeInsets.all(32);
  static const sidebarList = EdgeInsets.all(8);
  static const expanderHeader = EdgeInsets.symmetric(horizontal: 16, vertical: 12);
  static const titleBarBrand = EdgeInsets.symmetric(horizontal: 16);
  static const titleBarActions = EdgeInsets.symmetric(horizontal: 8);
}

/// Corner radii.
abstract final class Radii {
  static const double tiny = 4;
  static const double small = 6;
  static const double medium = 10;
  static const double large = 14;
  static const double full = 999;

  static const rTiny = BorderRadius.all(Radius.circular(tiny));
  static const rSmall = BorderRadius.all(Radius.circular(small));
  static const rMedium = BorderRadius.all(Radius.circular(medium));
  static const rLarge = BorderRadius.all(Radius.circular(large));
  static const rFull = BorderRadius.all(Radius.circular(full));
}

/// Animation durations and the shared easing curve.
abstract final class Motion {
  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 180);
  static const page = Duration(milliseconds: 260);

  /// How long one card takes to arrive.
  ///
  /// Kept short deliberately. At 460ms, with the stagger below, Home's last tile
  /// landed 900ms after the tab was clicked — long enough that switching tabs felt
  /// slow, and long enough that the items arriving one by one read as raggedness
  /// rather than as one intended movement.
  static const entrance = Duration(milliseconds: 220);
  static const spin = Duration(milliseconds: 900);
  static const curve = Curves.easeOutCubic;

  /// Settle time for one mouse-wheel notch. Short enough that a fast scroll
  /// still tracks the wheel rather than trailing behind it.
  static const wheel = Duration(milliseconds: 130);

  /// Per-item delay for staggered list/card entrances.
  static const stagger = Duration(milliseconds: 20);

  /// How many items the stagger applies to before it stops accumulating.
  ///
  /// Home has nine. Without a cap the ninth waits for eight delays before it even
  /// begins, so the further down the page you look the later it arrives — which is
  /// the opposite of what a stagger is for. Capped, the whole page is settled in
  /// [entrance] plus a fifth of a second, however many cards it holds.
  static const staggerLimit = 5;
}

/// Fixed pixel sizes for chrome and controls.
abstract final class Sizes {
  static const double icon = 16;
  static const double iconLarge = 20;
  static const double iconXl = 28;
  static const double spinner = 16;

  /// Spinner that sits inside a button or beside a line of text.
  static const double spinnerSmall = 14;
  static const double spinnerLarge = 28;
  static const double strokeSpinner = 2.5;
  static const double appIcon = 56;
  static const double appIconSmall = 40;
  static const double statusDot = 8;
  static const double stepDot = 12;
  static const double strokeStepDot = 2;
  static const double stepConnector = 24;
  static const double stepConnectorThickness = 2;
  static const double progressBar = 8;
  static const double hairline = 1;
  static const double input = 34;
  static const double iconButton = 32;
  static const double captionButtonWidth = 46;
  static const double captionButtonHeight = 32;
  static const double titleBar = 46;
  static const double sidebar = 220;
  static const double sidebarItem = 36;
  static const double dialogMax = 440;
  static const double dialogMin = 320;
  static const double contentMax = 860;
  static const double logoMark = 26;
  static const double windowWidth = 1120;
  static const double windowHeight = 720;
  static const double windowMinWidth = 920;
  static const double windowMinHeight = 600;
}

/// Type scale (sizes only — colour is applied from the palette).
abstract final class FontSizes {
  static const double display = 26;
  static const double title = 18;
  static const double body = 14;
  static const double small = 12.5;
  static const double caption = 11.5;
  static const double wordmark = 15;
}

/// Font families. Inter ships with the app; mono falls back through the stack.
abstract final class Fonts {
  static const String sans = 'Inter';
  static const List<String> monoFallback = ['Menlo', 'monospace'];
  static const String mono = 'Consolas';
}
