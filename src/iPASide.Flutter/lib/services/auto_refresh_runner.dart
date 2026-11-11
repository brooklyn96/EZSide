// Ported from iPASide.App/Services/AutoRefreshRunner.cs.

import 'dart:io';

import '../engine/engine.dart';
import '../platform/app_paths.dart';
import '../platform/native_dialog.dart';
import '../platform/single_instance.dart';
import '../platform/windows_child_process_reaper.dart';
import 'settings_store.dart';

/// The headless `EZSide --auto-refresh` path run by the OS scheduled task: no
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
/// When the run throws, or any app comes back with status `error`, one native
/// warning box is shown AFTER the engine has exited and the log is written, and
/// the exit code is 1. Nothing is shown when nothing was due or all succeeded,
/// and an app the engine `deferred` (phone not reachable, time left) is logged as
/// waiting and counts as neither. The box is shown at most once per 20 hours
/// (see [claimNotice]); the exit code does not depend on it. The running-app
/// marker stays held until the box is closed. When the GUI is running (see
/// [guiIsRunning]) the box is skipped and the stamp left alone: the GUI watches
/// the log and shows the notice itself.
///
/// Apps signed with the imported certificate are never refreshed; when the
/// engine reports some of them close to expiry ([RefreshSummary.customExpiring])
/// the same box also warns about them ([expiryText]), at most once per 20 hours
/// on its own stamp, GUI open or not. The warning never changes the exit code.
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
  /// the run completed and every app succeeded, 1 when it threw or any app failed.
  ///
  /// Unlike the C# original - where `Program.Main` held the marker for both paths
  /// before branching - this also holds the installer's running-app marker for the
  /// duration of the run, so the headless path carries it even if the GUI entry
  /// point forgets to. Holding it twice in one process is harmless.
  /// [transport] replaces the engine process, for tests: this path is the one
  /// nobody is watching, so it has to be provable without spawning a real engine
  /// and re-signing the user's actual apps. Production passes nothing and gets
  /// exactly the client it always did, disposed the same way.
  ///
  /// [notice] replaces the message box, for the same reason: tests must not open
  /// a real window.
  ///
  /// [now] replaces the clock, so the 20-hour notice limit can be proven without
  /// waiting.
  ///
  /// [guiRunning] replaces the "is the GUI instance up" check, so tests do not
  /// depend on a real EZSide being open.
  static Future<int> run({
    AppPaths? paths,
    SettingsStore? settings,
    EngineCommandRunner? transport,
    NoticeDialog notice = showWarningNotice,
    DateTime Function() now = DateTime.now,
    bool Function() guiRunning = guiIsRunning,
  }) async {
    final AppPaths appPaths = paths ?? AppPaths.instance;
    final SettingsStore store = settings ?? SettingsStore(paths: appPaths);
    final RunningAppMarker marker = RunningAppMarker.hold();
    final List<String> lines = <String>[];
    int exitCode = 0;
    int failedApps = 0;
    List<CustomExpiringApp> expiring = const <CustomExpiringApp>[];

    try {
      appPaths.ensureRootExists();

      final SignedIpaSettings signed = store.loadSignedIpa();
      // Only a client this method created is a client this method closes.
      final EngineClient? owned = transport == null
          ? EngineClient(
              locator: EngineLocator(),
              reaper: createChildProcessReaper(),
              paths: appPaths,
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
          // A phone that is asleep or off the network is tried again next hour
          // rather than reported; only a real failure counts below.
          unattended: true,
        );
        // Apps on the imported certificate are never refreshed; the engine only
        // reports the ones close to stopping, and only the user can fix that.
        expiring = summary.customExpiring;
        if (summary.refreshed.isEmpty) {
          lines.add(AutoRefreshLog.formatNothingToRefresh(now()));
        } else {
          lines.addAll(AutoRefreshLog.formatLines(now(), summary));
          failedApps = summary.refreshed
              .where((RefreshEntry entry) => entry.status == 'error')
              .length;
          if (failedApps > 0) exitCode = 1;
        }
      } finally {
        await owned?.dispose();
      }
    } catch (error) {
      lines.add(
        AutoRefreshLog.formatRunFailure(now(), _messageOf(error)),
      );
      exitCode = 1;
    }

    // The marker is held until the notice is closed: the box keeps this process
    // alive, and the installer must still see EZSide running meanwhile.
    try {
      await _appendLines(appPaths.autoRefreshLogPath, lines);
      // The task runs every hour, so a failure that persists must not raise a
      // box every hour; the log above still records every run. With the GUI
      // open it shows the notice (from this same log), so this run stays quiet
      // and, above all, leaves the stamp for the GUI to claim.
      final bool showFailure = exitCode != 0 &&
          !guiRunning() &&
          claimNotice(paths: appPaths, now: now());
      // Its own stamp, so a failure notice and this warning never silence each
      // other, and shown with the GUI open too: the GUI does not raise it itself.
      final bool showExpiry = expiring.isNotEmpty &&
          _claimStamp(_expiryStampPath(appPaths), now());
      if (showFailure || showExpiry) {
        try {
          notice('EZSide', <String>[
            if (showFailure) failureText(failedApps),
            if (showExpiry) expiryText(expiring),
          ].join('\n\n'));
        } catch (_) {
          // The log already holds the failure; a notice that cannot be shown
          // must not change the exit code.
        }
      }
    } finally {
      marker.dispose();
    }
    return exitCode;
  }

  /// The English + Vietnamese text of the failure notice. [failedApps] is 0 when
  /// the run itself could not complete.
  static String failureText(int failedApps) {
    final String english = failedApps > 0
        ? 'EZSide could not refresh $failedApps app(s).'
        : 'EZSide could not refresh your apps.';
    final String vietnamese = failedApps > 0
        ? 'EZSide không thể làm mới $failedApps ứng dụng.'
        : 'EZSide không thể làm mới các ứng dụng.';
    return '$english\n$vietnamese\n\n'
        'Open EZSide > Library to retry.\n'
        'Mở EZSide > Library để thử lại.';
  }

  /// Checks the 20-hour limit and, when a failure notice may be shown now,
  /// writes the stamp and returns true. The run and the GUI share this, so one
  /// stamp throttles both.
  ///
  /// The stamp is written BEFORE the caller shows anything: a message box blocks
  /// until closed and the task's 1-hour limit kills a process whose box nobody
  /// answered, so a stamp written afterwards would never exist in exactly the
  /// unattended case.
  ///
  /// A missing, unreadable or garbled stamp, or one in the future, means "no
  /// notice shown yet": a notice that is shown twice is better than one that is
  /// never shown. Never throws, so it cannot change the exit code. [paths]
  /// defaults to [AppPaths.instance], [now] to the clock.
  static bool claimNotice({AppPaths? paths, DateTime? now}) => _claimStamp(
        (paths ?? AppPaths.instance).autoRefreshNoticeStampPath,
        now ?? DateTime.now(),
      );

  /// The English + Vietnamese warning that apps signed with the imported
  /// certificate are about to stop opening (or already have), one line per app
  /// with its days left, ending with the steps that fix it: a new certificate,
  /// then a re-sign, since the apps keep the old date until they are re-signed.
  static String expiryText(List<CustomExpiringApp> apps) {
    String days(CustomExpiringApp app, {required bool english}) {
      final double? left = app.daysLeft;
      if (left == null) return english ? 'soon' : 'sắp hết hạn';
      if (left <= 0) return english ? 'expired' : 'đã hết hạn';
      final int whole = left.floor();
      if (whole < 1) return english ? 'under a day left' : 'còn chưa tới 1 ngày';
      return english
          ? '$whole day${whole == 1 ? '' : 's'} left'
          : 'còn $whole ngày';
    }

    String list({required bool english}) => apps
        .map((CustomExpiringApp app) =>
            '- ${app.name ?? app.bundleId ?? '?'}: ${days(app, english: english)}')
        .join('\n');

    // The list also carries apps already past their date: "about to" would be
    // wrong for those.
    final bool anyExpired =
        apps.any((CustomExpiringApp app) => (app.daysLeft ?? 1) <= 0);
    final String english = anyExpired
        ? 'Your imported certificate has expired. These apps have stopped '
            'opening or will stop soon:'
        : 'Your imported certificate is about to expire. These apps will stop '
            'opening:';
    final String vietnamese = anyExpired
        ? 'Chứng chỉ bạn đã nhập đã hết hạn. Các ứng dụng này đã ngừng mở hoặc '
            'sắp ngừng mở:'
        : 'Chứng chỉ bạn đã nhập sắp hết hạn. Các ứng dụng này sẽ ngừng mở:';
    // The Account page button, as labelled there.
    const String resign = '"Re-sign all apps with this certificate"';

    return '$english\n'
        '${list(english: true)}\n'
        'Renew the certificate with the seller, import the new one on the '
        'Account page, then press $resign.\n\n'
        '$vietnamese\n'
        '${list(english: false)}\n'
        'Hãy gia hạn chứng chỉ với người bán, nhập chứng chỉ mới ở trang '
        'Account, rồi bấm $resign.';
  }

  /// Next to the failure stamp: the expiry warning is limited the same way.
  static String _expiryStampPath(AppPaths paths) =>
      '${File(paths.autoRefreshNoticeStampPath).parent.path}'
      '${Platform.pathSeparator}auto-refresh-last-expiry-notice.txt';

  static bool _claimStamp(String stampPath, DateTime at) {
    if (!_noticeDue(stampPath, at)) return false;
    _writeNoticeStamp(stampPath, at);
    return true;
  }

  /// At most one failure notice per this long.
  static const Duration _noticeInterval = Duration(hours: 20);

  static bool _noticeDue(String stampPath, DateTime at) {
    try {
      final DateTime? last =
          DateTime.tryParse(File(stampPath).readAsStringSync().trim());
      if (last == null) return true;
      final Duration since = at.difference(last);
      return since.isNegative || since >= _noticeInterval;
    } catch (_) {
      return true;
    }
  }

  static void _writeNoticeStamp(String stampPath, DateTime at) {
    try {
      File(stampPath).writeAsStringSync(at.toUtc().toIso8601String());
    } catch (_) {
      // Worst case the next failure shows its notice again.
    }
  }

  /// True when a GUI instance is running: its single-instance mutex exists.
  ///
  /// Delegates to [singleInstanceIsHeld], which only opens the mutex. False off
  /// Windows and on any error: an unanswered check must not silence the notice.
  static bool guiIsRunning() => singleInstanceIsHeld();

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
      return;
    }
    await _trimLog(path);
  }

  /// The task runs every hour, so the log is kept to the newest [_maxLogLines].
  static const int _maxLogLines = 2000;

  /// Runs after the new lines are appended and writes through a temp file, so a
  /// failure here (never rethrown) leaves the full log, new lines included.
  static Future<void> _trimLog(String path) async {
    final File temp = File('$path.tmp');
    try {
      final List<String> all = await File(path).readAsLines();
      if (all.length <= _maxLogLines) return;
      await temp.writeAsString(
        all
            .sublist(all.length - _maxLogLines)
            .map((String line) => '$line${Platform.lineTerminator}')
            .join(),
        flush: true,
      );
      await temp.rename(path);
    } catch (_) {
      try {
        if (temp.existsSync()) temp.deleteSync();
      } catch (_) {
        // A stray temp file is overwritten by the next trim.
      }
    }
  }
}
