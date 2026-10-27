// Ported from iPASide.App/Platform/AppPaths.cs.

import 'dart:io';

/// The host OS families whose per-user data directory differs.
///
/// The layout is resolved from an [AppDataHost] rather than straight from
/// [Platform] so the derivation stays a pure function of its inputs.
enum AppDataHost {
  /// Windows: `%LOCALAPPDATA%`.
  windows,

  /// macOS: `~/Library/Application Support`.
  macOS,

  /// Everything else: `$XDG_DATA_HOME`, else `~/.local/share`.
  other;

  /// The family this process is running on.
  static AppDataHost get current {
    if (Platform.isWindows) return AppDataHost.windows;
    if (Platform.isMacOS) return AppDataHost.macOS;
    return AppDataHost.other;
  }
}

/// Well-known per-user data locations: `%LOCALAPPDATA%\iPASide` on Windows and
/// the platform-native per-user data directory elsewhere.
///
/// The app reads [AppPaths.instance]; [AppPaths.rooted] exists so tests can
/// point the same layout at a scratch directory. The Inno Setup uninstaller
/// knows this root, so the fallbacks below deliberately rebuild the canonical
/// location instead of inventing a new one.
class AppPaths {
  /// Creates a layout rooted at [root].
  const AppPaths.rooted(this.root);

  /// The layout the app uses, derived once from the process environment.
  static final AppPaths instance = AppPaths.rooted(
    resolveRoot(Platform.environment),
  );

  /// Folder holding every piece of persisted app data.
  final String root;

  /// Log appended by the headless `--auto-refresh` run (one line per app).
  String get autoRefreshLogPath => _join(root, 'autorefresh.log');

  /// Theme-only UI settings JSON.
  String get settingsPath => _join(root, 'settings.json');

  /// Creates [root] and any missing parents.
  ///
  /// Throws [FileSystemException] if the directory cannot be created; callers
  /// that must not fail (theme persistence) treat that as best-effort.
  void ensureRootExists() => Directory(root).createSync(recursive: true);

  /// Derives the data root from [environment] for the given [host].
  ///
  /// [host] defaults to the running OS; pass it explicitly to exercise another
  /// family's derivation.
  static String resolveRoot(
    Map<String, String> environment, {
    AppDataHost? host,
  }) {
    final String? dataHome = switch (host ?? AppDataHost.current) {
      AppDataHost.windows => _windowsDataHome(environment),
      AppDataHost.macOS => _macDataHome(environment),
      AppDataHost.other => _xdgDataHome(environment),
    };
    // A process with no home directory at all (stripped service environment)
    // still has to put its settings and log somewhere writable.
    return _join(dataHome ?? Directory.systemTemp.path, _folderName);
  }

  static const String _folderName = 'iPASide';

  static String? _windowsDataHome(Map<String, String> environment) {
    final String? localAppData = _nonEmpty(environment['LOCALAPPDATA']);
    if (localAppData != null) return localAppData;

    final String? profile =
        _nonEmpty(environment['USERPROFILE']) ?? _homeDrivePath(environment);
    if (profile != null) return _join(_join(profile, 'AppData'), 'Local');

    return null;
  }

  static String? _homeDrivePath(Map<String, String> environment) {
    final String? drive = _nonEmpty(environment['HOMEDRIVE']);
    final String? path = _nonEmpty(environment['HOMEPATH']);
    if (drive == null || path == null) return null;
    return '$drive$path';
  }

  static String? _macDataHome(Map<String, String> environment) {
    final String? home = _nonEmpty(environment['HOME']);
    if (home == null) return null;
    return _join(_join(home, 'Library'), 'Application Support');
  }

  static String? _xdgDataHome(Map<String, String> environment) {
    final String? xdg = _nonEmpty(environment['XDG_DATA_HOME']);
    if (xdg != null) return xdg;

    final String? home = _nonEmpty(environment['HOME']);
    if (home == null) return null;
    return _join(_join(home, '.local'), 'share');
  }

  static String? _nonEmpty(String? value) =>
      value != null && value.trim().isNotEmpty ? value : null;

  static String _join(String parent, String child) {
    final String separator = Platform.pathSeparator;
    return parent.endsWith(separator) || parent.endsWith('/')
        ? '$parent$child'
        : '$parent$separator$child';
  }
}
