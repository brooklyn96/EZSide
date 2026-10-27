// Ported from iPASide.App/Services/ThemeSettingsStore.cs, generalised past the
// single theme key that store was built for.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../platform/app_paths.dart';

/// The `signedIpa` section of the settings file.
///
/// The engine writes the signed `.ipa` it just installed to a working
/// directory; [keep] decides whether it is left there afterwards and
/// [directory] where "there" is.
@immutable
class SignedIpaSettings {
  /// Creates a section, defaulting to the engine's own behaviour: delete the
  /// signed IPA, into the engine's own directory.
  const SignedIpaSettings({this.keep = false, this.directory});

  /// Reads the section, degrading any unusable value to its default.
  ///
  /// A blank [directory] is the same as an absent one: an empty string is not a
  /// folder anybody meant to choose.
  factory SignedIpaSettings.fromJson(Map<String, dynamic> json) {
    final Object? keep = json[_keepKey];
    final Object? directory = json[_directoryKey];
    final String? trimmed = directory is String ? directory.trim() : null;

    return SignedIpaSettings(
      keep: keep is bool ? keep : false,
      directory: trimmed == null || trimmed.isEmpty ? null : trimmed,
    );
  }

  static const String _keepKey = 'keep';
  static const String _directoryKey = 'directory';

  /// Whether the signed `.ipa` survives a successful install.
  final bool keep;

  /// Where a kept `.ipa` is written; null means the engine's own default, which
  /// only the engine knows the path of.
  final String? directory;

  /// Whether [directory] leaves the choice of folder to the engine.
  bool get usesDefaultDirectory => directory == null;

  /// Returns a copy with [keep] replaced.
  SignedIpaSettings withKeep(bool keep) =>
      SignedIpaSettings(keep: keep, directory: directory);

  /// Returns a copy pointed at [directory], or at the engine's default when it
  /// is null.
  ///
  /// Unlike a `copyWith`, null here means "use the default" rather than "leave
  /// it alone" — resetting to the default is one of the two things callers do.
  SignedIpaSettings withDirectory(String? directory) =>
      SignedIpaSettings(keep: keep, directory: directory);

  /// Writes this section's own keys into [json], leaving every other key —
  /// including ones a newer build added — exactly as it found them.
  void writeInto(Map<String, dynamic> json) {
    json[_keepKey] = keep;
    json[_directoryKey] = directory;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SignedIpaSettings &&
          other.keep == keep &&
          other.directory == directory;

  @override
  int get hashCode => Object.hash(keep, directory);

  @override
  String toString() =>
      'SignedIpaSettings(keep: $keep, directory: $directory)';
}

/// Persists the app's own settings as one small JSON object at
/// [AppPaths.settingsPath]:
///
/// ```json
/// {
///   "theme": "default",
///   "deviceUdid": null,
///   "connection": "auto",
///   "signedIpa": { "keep": false, "directory": null }
///  }
/// ```
///
/// Every write is a read-modify-write of that object, touching only the keys it
/// was asked to change. A key this build has never heard of — one a newer
/// version wrote before the user rolled back — therefore survives being saved
/// over, and a section keeps its unknown members too.
///
/// First launch has no file and every getter answers with its default, so the
/// theme resolves to [ThemeMode.system] and the app follows the OS. The legacy
/// WebView2 localStorage theme is intentionally not migrated, and no transient
/// UI state (e.g. the Advanced section's open state) is ever written here.
///
/// Both directions are synchronous and best-effort: [loadTheme] runs before the
/// first frame, and a file that cannot be read or written must never be able to
/// block startup or lose an in-memory value.
class SettingsStore {
  /// Creates a store over [paths], defaulting to the app's real data root.
  SettingsStore({AppPaths? paths}) : _paths = paths ?? AppPaths.instance;

  static const String _themeKey = 'theme';
  static const String _deviceUdidKey = 'deviceUdid';
  static const String _connectionKey = 'connection';
  static const String _signedIpaKey = 'signedIpa';

  /// Prefer USB and fall back to Wi-Fi - the engine's own default.
  static const String _autoConnection = 'auto';

  final AppPaths _paths;

  /// Reads the persisted mode; a missing, unreadable or corrupt file falls back
  /// to [ThemeMode.system].
  ThemeMode loadTheme() {
    final Object? theme = _read()[_themeKey];
    return theme is String ? _parseTheme(theme) : ThemeMode.system;
  }

  /// Persists [mode], leaving every other setting in the file untouched.
  void saveTheme(ThemeMode mode) {
    final Map<String, dynamic> document = _read();
    document[_themeKey] = _themeName(mode);
    _write(document);
  }

  /// Reads the UDID of the device the user last chose to install to, or null
  /// when they have never chosen one.
  ///
  /// This is a PREFERENCE, not a live selection: the device it names may not be
  /// connected now, or ever again. Callers must treat it as "target this one if
  /// it is here" and fall back on their own.
  String? loadDeviceUdid() {
    final Object? udid = _read()[_deviceUdidKey];
    if (udid is! String) return null;
    final String trimmed = udid.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Persists the chosen device, or clears the preference with null.
  void saveDeviceUdid(String? udid) {
    final Map<String, dynamic> document = _read();
    final String? trimmed = udid?.trim();
    document[_deviceUdidKey] =
        trimmed == null || trimmed.isEmpty ? null : trimmed;
    _write(document);
  }

  /// The transport to reach the device by, as the engine's wire word: `usb`,
  /// `wifi`, or `auto`. Anything unrecognised reads as `auto`, which is what the
  /// engine does by default anyway.
  String loadConnection() {
    final Object? value = _read()[_connectionKey];
    if (value is! String) return _autoConnection;
    final String trimmed = value.trim().toLowerCase();
    return const <String>{'usb', 'wifi', _autoConnection}.contains(trimmed)
        ? trimmed
        : _autoConnection;
  }

  /// Persists the transport choice.
  void saveConnection(String connection) {
    final Map<String, dynamic> document = _read();
    document[_connectionKey] = connection;
    _write(document);
  }

  /// Reads the signed-IPA section, defaulting to "delete it, in the engine's
  /// own directory".
  SignedIpaSettings loadSignedIpa() =>
      SignedIpaSettings.fromJson(_section(_read()[_signedIpaKey]));

  /// Persists [settings], leaving the theme — and anything else in the file or
  /// in the section — untouched.
  void saveSignedIpa(SignedIpaSettings settings) {
    final Map<String, dynamic> document = _read();
    final Map<String, dynamic> section = _section(document[_signedIpaKey]);
    settings.writeInto(section);
    document[_signedIpaKey] = section;
    _write(document);
  }

  /// The settings object as it is on disk, or an empty one when there is
  /// nothing usable there.
  ///
  /// Returning empty for a corrupt file is what lets the next save repair it:
  /// the unreadable bytes are replaced by a document holding the one key the
  /// caller asked to change.
  Map<String, dynamic> _read() {
    try {
      final File file = File(_paths.settingsPath);
      if (!file.existsSync()) return <String, dynamic>{};

      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) return decoded;
    } on FileSystemException {
      // A broken settings file must never block startup; follow the defaults.
    } on FormatException {
      // Same for JSON that is not parseable, or not an object.
    }

    return <String, dynamic>{};
  }

  /// Best-effort persistence; the in-memory value applies even if the write
  /// fails.
  void _write(Map<String, dynamic> document) {
    try {
      _paths.ensureRootExists();
      File(_paths.settingsPath).writeAsStringSync(jsonEncode(document));
    } on FileSystemException {
      // Settings persistence is best-effort by design.
    }
  }

  /// A nested section as a mutable map, or an empty one when the file holds
  /// something else under that key.
  static Map<String, dynamic> _section(Object? value) =>
      value is Map<String, dynamic> ? value : <String, dynamic>{};

  static ThemeMode _parseTheme(String theme) => switch (theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static String _themeName(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'default',
      };
}
