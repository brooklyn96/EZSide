// Ported from iPASide.App/Services/AutoRefreshRunner.cs.

import 'dart:io';

import '../engine/engine.dart';
import '../platform/app_paths.dart';
import '../platform/single_instance.dart';
import '../platform/windows_child_process_reaper.dart';
import 'settings_store.dart';

/// The headless `iPASide --auto-refresh` path run by the OS scheduled task: no
/// window, no Flutter binding.
///
/// It runs one `refresh` with NEITHER a bundle id nor `--all`, which is how the
/// engine is told to re-sign only the apps that are actually due. Because the
/// engine reports success even when individual apps fail, every per-app outcome
/// in [RefreshSummary.refreshed] is written as its own line to
/// [AppPaths.autoRefreshLogPath].
///
/// It reads the keep-signed setting off disk and passes it through, so a refresh
/// nobody is watching leaves the same files behind as one the user ran by hand.
/// Without that, the engine's own default would quietly delete signed IPAs the
/// user asked to keep — every night, and with nothing on screen to notice it.
///
/// [run] must be awaited before any window is created, and its result passed to
/// `exit`.
abstract final class AutoRefreshRunner {
  /// CLI argument that selects this path over the GUI.
  static const String cliArgument = '--auto-refresh';

  /// True when [arguments] ask for a headless refresh.
  ///
  /// Case-insensitive, matching the C# `StringComparer.OrdinalIgnoreCase`.
  static bool isRequested(List<String> arguments) =>
      arguments.any((String argument) => argument.toLowerCase() == cliArgument);

  /// Runs the refresh, appends the log, and returns the process exit code: 0 when
  /// the run completed, 1 when it threw.
  ///
  /// Unlike the C# original - where `Program.Main` held the marker for both paths
  /// before branching - this also holds the installer's running-app marker for the
  /// duration of the run, so the headless path carries it even if the GUI entry
  /// point forgets to. Holding it twice in one process is harmless.
  /// [transport] replaces the engine process, for tests: this path is the one
  /// nobody is watching, so it has to be provable without spawning a real engine
  /// and re-signing the user's actual apps. Production passes nothing and gets
  /// exactly the client it always did, disposed the same way.
  static Future<int> run({
    AppPaths? paths,
    SettingsStore? settings,
    EngineCommandRunner? transport,
  }) async {
    final AppPaths appPaths = paths ?? AppPaths.instance;
    final SettingsStore store = settings ?? SettingsStore(paths: appPaths);
    final RunningAppMarker marker = RunningAppMarker.hold();
    final List<String> lines = <String>[];
    int exitCode = 0;

    try {
      appPaths.ensureRootExists();

      final SignedIpaSettings signed = store.loadSignedIpa();
      // Only a client this method created is a client this method closes.
      final EngineClient? owned = transport == null
          ? EngineClient(
              locator: EngineLocator(),
              reaper: createChildProcessReaper(),
            )
          : null;
      try {
        final RefreshSummary summary =
            await EngineApi(transport ?? owned!).refresh(
          keepSigned: signed.keep,
          signedDirectory: signed.directory,
          // Read here rather than carried in: this runs with no window, and the
          // transport the user chose has to hold for the unattended run too.
          // 'auto' is dropped on the way out, so it costs nothing to pass.
          connection: store.loadConnection(),
        );
        if (summary.refreshed.isEmpty) {
          lines.add(AutoRefreshLog.formatNothingToRefresh(DateTime.now()));
        } else {
          lines.addAll(AutoRefreshLog.formatLines(DateTime.now(), summary));
        }
      } finally {
        await owned?.dispose();
      }
    } catch (error) {
      lines.add(
        AutoRefreshLog.formatRunFailure(DateTime.now(), _messageOf(error)),
      );
      exitCode = 1;
    } finally {
      marker.dispose();
    }

    await _appendLines(appPaths.autoRefreshLogPath, lines);
    return exitCode;
  }

  static String _messageOf(Object error) =>
      error is EngineException ? error.message : error.toString();

  static Future<void> _appendLines(String path, List<String> lines) async {
    if (lines.isEmpty) return;

    final String text = lines
        .map((String line) => '$line${Platform.lineTerminator}')
        .join();
    try {
      await File(path).writeAsString(text, mode: FileMode.append);
    } on FileSystemException {
      // The refresh itself already happened; failing the run over an unwritable
      // log would only make the scheduled task look broken.
    }
  }
}
