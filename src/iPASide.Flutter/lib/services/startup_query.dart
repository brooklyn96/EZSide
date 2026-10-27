// Ported from iPASide.App/Services/StartupQuery.cs.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Startup overrides the e2e/screenshot harness passes through the
/// `IPASIDE_STARTUP_QUERY` environment variable.
///
/// All values are optional; [StartupOptions.empty] is the normal interactive
/// launch.
@immutable
class StartupOptions {
  /// Creates a set of overrides.
  const StartupOptions({
    this.view,
    this.theme,
    this.ipaPath,
    this.tweakPaths = const <String>[],
    this.advancedOpen = false,
  });

  /// The normal interactive launch: no overrides at all.
  static const StartupOptions empty = StartupOptions();

  /// Navigation key of the screen to open instead of Home.
  final String? view;

  /// Theme override, `light` or `dark`, or null for no override.
  ///
  /// It applies for this run only and is NEVER persisted, so a screenshot run
  /// cannot change the user's saved theme.
  final String? theme;

  /// `.ipa` preloaded into the Sideload screen.
  final String? ipaPath;

  /// Tweak paths applied after the IPA loads.
  final List<String> tweakPaths;

  /// Whether the Sideload screen starts with its Advanced section expanded.
  final bool advancedOpen;

  /// [theme] mapped to a mode, or null when there is no override.
  ThemeMode? get themeOverride => StartupQuery.toThemeMode(theme);

  @override
  bool operator ==(Object other) =>
      other is StartupOptions &&
      other.view == view &&
      other.theme == theme &&
      other.ipaPath == ipaPath &&
      other.advancedOpen == advancedOpen &&
      listEquals(other.tweakPaths, tweakPaths);

  @override
  int get hashCode => Object.hash(
    view,
    theme,
    ipaPath,
    advancedOpen,
    Object.hashAll(tweakPaths),
  );
}

/// Parses `IPASIDE_STARTUP_QUERY` with the same keys the legacy WebView2 shell
/// forwarded as its `location.search` query, preserving the e2e/screenshot
/// harness.
///
/// Recognised keys: `view` (navigation key), `theme` (`light`/`dark` override,
/// not persisted), `ipa` (path preloaded into the Sideload session), `tweaks`
/// (pipe-joined tweak paths, applied after the IPA loads) and `adv` (`1` starts
/// with Advanced expanded).
///
/// This is an environment variable rather than a CLI argument on purpose: the
/// harness launches the shipped executable unchanged.
abstract final class StartupQuery {
  /// Environment variable carrying the query string.
  static const String environmentVariableName = 'IPASIDE_STARTUP_QUERY';

  /// Reads and parses [environmentVariableName], defaulting to the current
  /// process environment.
  ///
  /// A missing or blank value yields [StartupOptions.empty].
  static StartupOptions fromEnvironment([Map<String, String>? environment]) =>
      parse((environment ?? Platform.environment)[environmentVariableName]);

  /// Parses a query string; a leading `?` is optional.
  ///
  /// Decoding matches the legacy `URLSearchParams` semantics: percent-escapes and
  /// `+` as space, with the FIRST occurrence of a key winning.
  static StartupOptions parse(String? query) {
    if (query == null || query.trim().isEmpty) return StartupOptions.empty;

    String trimmed = query.trim();
    if (trimmed.startsWith('?')) trimmed = trimmed.substring(1);

    final Map<String, String> values = <String, String>{};
    for (final String pair in trimmed.split('&')) {
      if (pair.isEmpty) continue;
      final int separator = pair.indexOf('=');
      // Rejects both a valueless key and an empty key name.
      if (separator <= 0) continue;
      values.putIfAbsent(
        _decode(pair.substring(0, separator)),
        () => _decode(pair.substring(separator + 1)),
      );
    }

    final String? joinedTweaks = _nonEmpty(values, 'tweaks');

    return StartupOptions(
      view: _nonEmpty(values, 'view'),
      theme: switch (_nonEmpty(values, 'theme')) {
        'light' => 'light',
        'dark' => 'dark',
        _ => null,
      },
      ipaPath: _nonEmpty(values, 'ipa'),
      tweakPaths: joinedTweaks == null
          ? const <String>[]
          : List<String>.unmodifiable(
              joinedTweaks.split('|').where((String path) => path.isNotEmpty),
            ),
      advancedOpen: values['adv'] == '1',
    );
  }

  /// Maps a parsed theme override to a mode; null means no override.
  static ThemeMode? toThemeMode(String? theme) => switch (theme) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => null,
  };

  static String _decode(String value) {
    try {
      return Uri.decodeQueryComponent(value);
    } catch (_) {
      // Uri rejects malformed percent-escapes and invalid UTF-8; WebUtility
      // .UrlDecode left them alone, and a harness typo must not fail startup.
      return value.replaceAll('+', ' ');
    }
  }

  static String? _nonEmpty(Map<String, String> values, String key) {
    final String? value = values[key];
    return value != null && value.isNotEmpty ? value : null;
  }
}
