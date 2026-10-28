import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../engine/auto_refresh_status.dart';

/// What the tray asks the app to do. The names are the strings the native
/// menu returns (windows/runner/tray_icon.cpp, PopUpMenu).
enum TrayMenuItem {
  /// "Open EZSide", a click on the icon or its balloon, or a second launch.
  open,

  /// "Refresh due apps now".
  refreshNow,

  /// "Start with Windows".
  startWithWindows,

  /// "Quit EZSide", or the tray window being sent WM_CLOSE.
  quit,
}

/// The notification-area icon: its menu, its status line and its balloon.
///
/// The icon is drawn by the runner (windows/runner/tray_icon.cpp) over the
/// `ezside/tray` channel. The runner keeps trying to add the icon while it is
/// wanted and reports every add and every loss as `iconState`, so [isReady]
/// follows the shell, not just the first try. Every call is best-effort and
/// never throws: off Windows, or in a test with no native side, [isAvailable]
/// stays false and the rest are no-ops.
class TrayService {
  /// [channel] replaces the native side, for tests.
  TrayService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('ezside/tray');

  final MethodChannel _channel;
  bool _available = false;
  bool _ready = false;
  Completer<void>? _readyWaiter;
  void Function(TrayMenuItem item)? _onItem;
  Future<void> Function()? _onMenuOpening;

  /// True once the native side answered [init], until [dispose].
  bool get isAvailable => _available;

  /// True while the icon is in the tray.
  bool get isReady => _ready;

  /// Asks for the icon. [onItem] hears every menu choice and every click that
  /// should open the window; [onMenuOpening] runs before each menu is shown,
  /// so the app can call [setStartupChecked] with the real registry state.
  /// Returns whether the icon was added on the first try.
  Future<bool> init({
    required void Function(TrayMenuItem item) onItem,
    Future<void> Function()? onMenuOpening,
  }) async {
    _onItem = onItem;
    _onMenuOpening = onMenuOpening;
    _channel.setMethodCallHandler(_handle);
    final bool? added = await _call<bool>('init');
    if (added == null) {
      _channel.setMethodCallHandler(null);
      return false;
    }
    _available = true;
    _setReady(added);
    return added;
  }

  /// Waits up to [timeout] for the icon to appear, e.g. while the shell is
  /// still starting at sign-in. Returns whether it is there.
  Future<bool> waitUntilReady(Duration timeout) async {
    if (_ready) return true;
    if (!_available) return false;
    final Completer<void> waiter = _readyWaiter ??= Completer<void>();
    try {
      await waiter.future.timeout(timeout);
    } on TimeoutException {
      // Answered below.
    }
    return _ready;
  }

  /// The disabled status line in the menu. Kept natively even while the icon
  /// is missing, so it is right when the icon comes back.
  Future<void> setStatus(String line) async {
    if (_available) await _call<void>('setStatus', line);
  }

  /// The check mark on "Start with Windows".
  Future<void> setStartupChecked(bool on) async {
    if (_available) await _call<void>('setStartupChecked', on);
  }

  /// A balloon from the tray icon. Needs no AUMID and no Start-menu shortcut.
  /// Returns false when there is no icon to show it from.
  Future<bool> showNotice(String title, String body) async {
    if (!_available) return false;
    return await _call<bool>('showNotice', <String>[title, body]) ?? false;
  }

  /// Removes the icon.
  Future<void> dispose() async {
    if (!_available) return;
    _available = false;
    _setReady(false);
    _channel.setMethodCallHandler(null);
    await _call<void>('dispose');
  }

  void _setReady(bool on) {
    _ready = on;
    if (!on) return;
    _readyWaiter?.complete();
    _readyWaiter = null;
  }

  Future<void> _handle(MethodCall call) async {
    switch (call.method) {
      case 'iconState':
        _setReady(call.arguments == true);
      case 'open':
        _onItem?.call(TrayMenuItem.open);
      case 'quit':
        _onItem?.call(TrayMenuItem.quit);
      case 'menu':
        await _onMenuOpening?.call();
        final String? chosen = await _call<String>('popUpMenu');
        final TrayMenuItem? item = chosen == null
            ? null
            : TrayMenuItem.values.asNameMap()[chosen];
        if (item != null) _onItem?.call(item);
    }
  }

  Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// Tells the open Settings page that "Start with Windows" may have changed
/// behind its back: the tray toggled it, or the window came back from the
/// tray. Settings registers its re-read with [listen].
class StartupStateSignal {
  Future<void> Function()? _reload;

  /// The newest listener replaces the last: one Settings page is open at a
  /// time, and a closed one's re-read is a harmless no-op.
  void listen(Future<void> Function() reload) => _reload = reload;

  /// Runs the listener's re-read, if there is one.
  void changed() {
    final Future<void> Function()? reload = _reload;
    if (reload != null) unawaited(reload());
  }
}

/// Follows `autorefresh.log` for the GUI: the tray status line, and whether a
/// run that just finished failed in a way the user must hear about.
///
/// The scheduled task stays the only refresh scheduler; this only reads what
/// its runs (and the ones "Refresh due apps now" starts) wrote. Pure apart from
/// reading the log, so the rules are testable without a tray.
class AutoRefreshWatch {
  /// The run already in the log at construction is the baseline: it was seen
  /// before this GUI started, so it is announced only if it turns out to be
  /// unfinished and a later read shows it failed. Build it as soon as the
  /// single-instance mutex is held: from then on a run leaves its notice to
  /// the GUI.
  ///
  /// [claimNotice] is the shared 20-hour throttle
  /// (`AutoRefreshRunner.claimNotice`); [clock] replaces the clock, for tests.
  AutoRefreshWatch({
    required this.logPath,
    required this._claimNotice,
    this._clock = DateTime.now,
  }) {
    _stamp = _statLog();
    _last = lastAutoRefreshRun(logPath);
  }

  /// How often the app calls [poll].
  static const Duration pollInterval = Duration(seconds: 30);

  /// How long "Refreshing…" is shown for a run that never writes a result.
  static const Duration manualTimeout = Duration(minutes: 30);

  /// The log the headless run appends to (`AppPaths.autoRefreshLogPath`).
  final String logPath;

  final bool Function() _claimNotice;
  final DateTime Function() _clock;
  (DateTime, int)? _stamp;
  AutoRefreshRun? _last;

  /// When "Refresh due apps now" started a run that has not reported yet.
  DateTime? _manualSince;

  /// The newest run in the log when that run started; only a later one can
  /// be it.
  DateTime? _manualAfter;

  /// The run attributed to "Refresh due apps now", once it has reported.
  DateTime? _manualRunAt;

  /// The run whose failure was already announced.
  DateTime? _announcedAt;

  /// True while a run this GUI started has not written its result yet.
  bool get refreshing => _manualSince != null;

  /// The tray's status line.
  String get statusLine => refreshing
      ? 'Refreshing…'
      : autoRefreshStatusLine(_last, now: _clock());

  /// Records that "Refresh due apps now" started a run: the first run newer
  /// than every run in the log right now is that run's, and its failure is
  /// reported without the 20-hour limit.
  ///
  /// Read from the file rather than from the last poll, so a scheduled run
  /// that finished in the last 30 seconds is not mistaken for it. Compared by
  /// run time rather than by file offset, because the runner's trim rewrites
  /// the file and moves every offset. Run times have one-second precision, so
  /// a tray run that ends in the same second as the run before it is not
  /// matched; it is then reported like a scheduled run (an accepted limit).
  void manualStarted() {
    _manualSince = _clock();
    _manualAfter = lastAutoRefreshRun(logPath)?.at;
    _manualRunAt = null;
  }

  /// Re-reads the log when its time or length changed. Returns the run when
  /// it failed and a notice is due now, else null. A run is announced at most
  /// once.
  AutoRefreshRun? poll() {
    final DateTime? since = _manualSince;
    if (since != null && _clock().difference(since) >= manualTimeout) {
      _manualSince = null;
      _manualAfter = null;
    }

    final (DateTime, int)? stamp = _statLog();
    if (stamp == _stamp) return null;
    _stamp = stamp;

    final AutoRefreshRun? run = lastAutoRefreshRun(logPath);
    final AutoRefreshRun? previous = _last;
    _last = run;
    if (run == null) return null;
    if (previous != null) {
      // A trim or a rewrite changes the file without adding a run. The same
      // run read again counts only if more of it arrived: a read that landed
      // mid-append saw its first lines only.
      if (run.at.isBefore(previous.at)) return null;
      if (run.at.isAtSameMomentAs(previous.at) &&
          run.outcome == previous.outcome &&
          run.failedApps == previous.failedApps) {
        return null;
      }
    }

    final bool manual = _isManualRun(run);
    if (run.outcome != AutoRefreshOutcome.failed) return null;
    if (_same(_announcedAt, run.at)) return null;
    // The user asked for this run, so its failure is always worth saying.
    if (!manual && !_claimNotice()) return null;
    _announcedAt = run.at;
    return run;
  }

  /// Whether [run] is the one "Refresh due apps now" started; the first run
  /// after [_manualAfter] is claimed as it.
  bool _isManualRun(AutoRefreshRun run) {
    if (_same(_manualRunAt, run.at)) return true;
    if (_manualSince == null) return false;
    final DateTime? after = _manualAfter;
    if (after != null && !run.at.isAfter(after)) return false;
    _manualSince = null;
    _manualAfter = null;
    _manualRunAt = run.at;
    return true;
  }

  static bool _same(DateTime? a, DateTime b) =>
      a != null && a.isAtSameMomentAs(b);

  (DateTime, int)? _statLog() {
    final FileStat stat = FileStat.statSync(logPath);
    if (stat.type == FileSystemEntityType.notFound) return null;
    return (stat.modified, stat.size);
  }
}
