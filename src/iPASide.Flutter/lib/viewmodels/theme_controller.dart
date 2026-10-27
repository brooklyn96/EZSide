import 'package:flutter/material.dart';

import '../services/settings_store.dart';

/// Holds the active theme mode and persists changes.
///
/// Both the title-bar toggle and the Settings screen drive this, so they always
/// agree. The startup-query override passes `persist: false` — a harness run
/// must never rewrite the user's saved choice.
class ThemeController extends ChangeNotifier {
  ThemeController({required SettingsStore store, ThemeMode? initial})
      : _store = store,
        _mode = initial ?? store.loadTheme();

  final SettingsStore _store;
  ThemeMode _mode;

  ThemeMode get mode => _mode;

  /// Whether dark is actually showing, resolving [ThemeMode.system] against the
  /// platform brightness.
  bool isDark(Brightness platformBrightness) => switch (_mode) {
    ThemeMode.dark => true,
    ThemeMode.light => false,
    ThemeMode.system => platformBrightness == Brightness.dark,
  };

  /// Flips to the opposite of what is currently showing, leaving "follow the
  /// OS" behind — the same behaviour as the previous title-bar toggle.
  void toggle(Brightness platformBrightness) =>
      setMode(isDark(platformBrightness) ? ThemeMode.light : ThemeMode.dark);

  void setMode(ThemeMode mode, {bool persist = true}) {
    if (mode == _mode) return;
    _mode = mode;
    if (persist) _store.saveTheme(mode);
    notifyListeners();
  }
}
