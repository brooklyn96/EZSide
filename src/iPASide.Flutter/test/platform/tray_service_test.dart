import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/auto_refresh_log.dart';
import 'package:ipaside/engine/auto_refresh_status.dart';
import 'package:ipaside/engine/models.dart';
import 'package:ipaside/main.dart';
import 'package:ipaside/platform/tray_service.dart';
import 'package:ipaside/services/auto_refresh_runner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AutoRefreshWatch', () {
    late Directory temp;
    late String logPath;
    late DateTime now;
    late int claims;
    late bool allowNotice;

    final DateTime t1 = DateTime(2026, 10, 28, 8, 5, 3);
    final DateTime t2 = DateTime(2026, 10, 28, 9, 5, 4);

    setUp(() {
      temp = Directory.systemTemp.createTempSync('ipaside_tray_watch');
      logPath = '${temp.path}${Platform.pathSeparator}autorefresh.log';
      now = DateTime(2026, 10, 28, 12);
      claims = 0;
      allowNotice = true;
    });

    tearDown(() => temp.deleteSync(recursive: true));

    AutoRefreshWatch watch() => AutoRefreshWatch(
          logPath: logPath,
          claimNotice: () {
            claims++;
            return allowNotice;
          },
          clock: () => now,
        );

    /// Appends [line] the way the runner does, line end included.
    void append(String line) => File(logPath)
        .writeAsStringSync('$line\n', mode: FileMode.append);

    String failure(DateTime at) => AutoRefreshLog.formatRunFailure(at, 'boom');

    String installed(DateTime at, String bundleId) => AutoRefreshLog.formatLines(
          at,
          RefreshSummary(
            refreshed: <RefreshEntry>[
              RefreshEntry(bundleId: bundleId, status: 'installed'),
            ],
          ),
        ).single;

    String appError(DateTime at, String bundleId) => AutoRefreshLog.formatLines(
          at,
          RefreshSummary(
            refreshed: <RefreshEntry>[
              RefreshEntry(bundleId: bundleId, status: 'error', error: 'boom'),
            ],
          ),
        ).single;

    test('no log yet reads as never', () {
      expect(watch().statusLine, 'Last refresh: never');
    });

    test('a failure already in the log at start is never announced', () {
      append(failure(t1));
      final AutoRefreshWatch w = watch();

      expect(w.poll(), isNull);
      expect(claims, 0);
      expect(w.statusLine, endsWith('failed'));
    });

    test('a new scheduled failure goes through the shared throttle', () {
      append(AutoRefreshLog.formatNothingToRefresh(t1));
      final AutoRefreshWatch w = watch();
      append(failure(t2));

      final AutoRefreshRun? run = w.poll();

      expect(run?.outcome, AutoRefreshOutcome.failed);
      expect(claims, 1);
      expect(w.statusLine, startsWith('Last refresh: 09:05'));
    });

    test('a throttled scheduled failure updates the status only', () {
      allowNotice = false;
      final AutoRefreshWatch w = watch();
      append(failure(t2));

      expect(w.poll(), isNull);
      expect(claims, 1);
      expect(w.statusLine, endsWith('failed'));
    });

    test('a new run that did not fail is not announced', () {
      final AutoRefreshWatch w = watch();
      append(AutoRefreshLog.formatNothingToRefresh(t2));

      expect(w.poll(), isNull);
      expect(claims, 0);
      expect(w.statusLine, endsWith('nothing due'));
    });

    test('an unchanged log is not read again', () {
      final AutoRefreshWatch w = watch();
      append(failure(t2));

      expect(w.poll(), isNotNull);
      expect(w.poll(), isNull);
      expect(claims, 1);
    });

    test('a rewrite with no newer run is not announced', () {
      append(failure(t2));
      final AutoRefreshWatch w = watch();
      // A trim rewrites the file: it changes, the newest run does not.
      File(logPath).writeAsStringSync(
        '${AutoRefreshLog.formatNothingToRefresh(t1)}\n${failure(t2)}\n',
      );

      expect(w.poll(), isNull);
      expect(claims, 0);
    });

    test('a run started from the tray skips the throttle', () {
      allowNotice = false;
      final AutoRefreshWatch w = watch();
      w.manualStarted();
      expect(w.refreshing, isTrue);
      expect(w.statusLine, 'Refreshing…');

      append(failure(t2));

      expect(w.poll()?.outcome, AutoRefreshOutcome.failed);
      expect(claims, 0);
      expect(w.refreshing, isFalse);
      expect(w.statusLine, endsWith('failed'));
    });

    test('only the next new run is the tray run', () {
      allowNotice = false;
      final AutoRefreshWatch w = watch();
      w.manualStarted();
      append(AutoRefreshLog.formatNothingToRefresh(t1));
      expect(w.poll(), isNull);

      append(failure(t2));

      expect(w.poll(), isNull);
      expect(claims, 1);
    });

    test('a tray run that never reports stops saying Refreshing', () {
      final AutoRefreshWatch w = watch();
      w.manualStarted();

      now = now.add(AutoRefreshWatch.manualTimeout);
      expect(w.poll(), isNull);

      expect(w.refreshing, isFalse);
      expect(w.statusLine, 'Last refresh: never');
    });

    test('a run read mid-append is judged again when the rest arrives', () {
      final AutoRefreshWatch w = watch();
      append(installed(t2, 'com.a'));
      expect(w.poll(), isNull);
      expect(w.statusLine, endsWith('1 refreshed'));

      append(appError(t2, 'com.b'));
      final AutoRefreshRun? run = w.poll();

      expect(run?.outcome, AutoRefreshOutcome.failed);
      expect(run?.failedApps, 1);
      expect(claims, 1);
    });

    test('a run is announced once, however much more of it arrives', () {
      final AutoRefreshWatch w = watch();
      append(appError(t2, 'com.a'));
      expect(w.poll(), isNotNull);

      append(appError(t2, 'com.b'));

      expect(w.poll(), isNull);
      expect(claims, 1);
      expect(w.statusLine, endsWith('failed'));
    });

    test('the baseline run, cut off at start, is judged when it completes', () {
      append(installed(t2, 'com.a'));
      final AutoRefreshWatch w = watch();
      append(appError(t2, 'com.b'));

      expect(w.poll()?.failedApps, 1);
      expect(claims, 1);
    });

    test('a run already written when the tray run starts is not that run', () {
      allowNotice = false;
      final AutoRefreshWatch w = watch();
      // Written after the last poll, before the click.
      append(failure(t1));
      w.manualStarted();

      expect(w.poll(), isNull);
      expect(claims, 1);
      expect(w.refreshing, isTrue);

      append(failure(t2));

      expect(w.poll()?.at, t2);
      expect(claims, 1);
      expect(w.refreshing, isFalse);
    });

    test('the tray run read mid-append still skips the throttle', () {
      allowNotice = false;
      final AutoRefreshWatch w = watch();
      w.manualStarted();
      append(installed(t2, 'com.a'));
      expect(w.poll(), isNull);

      append(appError(t2, 'com.b'));

      expect(w.poll()?.failedApps, 1);
      expect(claims, 0);
    });
  });

  group('announceRefreshFailure', () {
    final AutoRefreshRun run = AutoRefreshRun(
      at: DateTime(2026, 10, 28, 9),
      outcome: AutoRefreshOutcome.failed,
      refreshed: 0,
      detail: 'boom',
      failedApps: 2,
    );

    test('uses the balloon when the tray can show one', () async {
      final List<String> shown = <String>[];

      await announceRefreshFailure(
        run,
        balloon: (String title, String body) async {
          shown.add('balloon $title|$body');
          return true;
        },
        box: (String title, String body) async => shown.add('box'),
      );

      expect(shown, <String>[
        'balloon EZSide|${AutoRefreshRunner.failureText(2)}',
      ]);
    });

    test('falls back to the box with the same words', () async {
      final List<String> shown = <String>[];

      await announceRefreshFailure(
        run,
        balloon: (_, _) async => false,
        box: (String title, String body) async =>
            shown.add('box $title|$body'),
      );

      expect(shown, <String>[
        'box EZSide|${AutoRefreshRunner.failureText(2)}',
      ]);
    });
  });

  group('StartupStateSignal', () {
    test('runs only the newest listener, and nothing before one', () async {
      final StartupStateSignal signal = StartupStateSignal();
      final List<String> reads = <String>[];
      signal.changed();

      signal.listen(() async => reads.add('old'));
      signal.listen(() async => reads.add('new'));
      signal.changed();
      await Future<void>.delayed(Duration.zero);

      expect(reads, <String>['new']);
    });
  });

  group('TrayService', () {
    const MethodChannel channel = MethodChannel('test/tray');
    late List<MethodCall> calls;
    late Object? Function(MethodCall call) reply;

    TestDefaultBinaryMessenger messenger() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      calls = <MethodCall>[];
      reply = (MethodCall call) => call.method == 'init' ? true : null;
      messenger().setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return reply(call);
      });
    });

    tearDown(() => messenger().setMockMethodCallHandler(channel, null));

    /// Delivers [method] the way the runner does, and waits for Dart to finish.
    Future<void> fromNative(String method, [Object? arguments]) async {
      final Completer<void> done = Completer<void>();
      await messenger().handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, arguments),
        ),
        (_) => done.complete(),
      );
      await done.future;
    }

    test('forwards the status, the check mark and the notice', () async {
      final TrayService tray = TrayService(channel: channel);
      expect(await tray.init(onItem: (_) {}), isTrue);

      await tray.setStatus('Last refresh: never');
      await tray.setStartupChecked(true);
      await tray.showNotice('EZSide', 'failed');

      expect(
        calls.map((MethodCall call) => '${call.method} ${call.arguments}'),
        <String>[
          'init null',
          'setStatus Last refresh: never',
          'setStartupChecked true',
          'showNotice [EZSide, failed]',
        ],
      );
    });

    test('with no native side it is not ready and stays quiet', () async {
      messenger().setMockMethodCallHandler(channel, null);
      final TrayService tray = TrayService(channel: channel);

      expect(await tray.init(onItem: (_) {}), isFalse);
      expect(tray.isReady, isFalse);
      // None of these may throw: the app then simply closes for real.
      await tray.setStatus('x');
      expect(await tray.showNotice('EZSide', 'x'), isFalse);
      expect(
        await tray.waitUntilReady(const Duration(minutes: 2)),
        isFalse,
      );
      await tray.dispose();
    });

    test('an icon added later is heard, and its loss too', () async {
      reply = (MethodCall call) => call.method == 'init' ? false : null;
      final TrayService tray = TrayService(channel: channel);
      expect(await tray.init(onItem: (_) {}), isFalse);
      expect(tray.isAvailable, isTrue);
      final Future<bool> waited =
          tray.waitUntilReady(const Duration(minutes: 2));

      await fromNative('iconState', true);

      expect(await waited, isTrue);
      expect(tray.isReady, isTrue);

      await fromNative('iconState', false);
      expect(tray.isReady, isFalse);
    });

    test('waiting for an icon that never comes gives up', () async {
      reply = (MethodCall call) => call.method == 'init' ? false : null;
      final TrayService tray = TrayService(channel: channel);
      await tray.init(onItem: (_) {});

      expect(
        await tray.waitUntilReady(const Duration(milliseconds: 20)),
        isFalse,
      );
    });

    test('the balloon reports whether the shell took it', () async {
      reply = (MethodCall call) => switch (call.method) {
            'init' => true,
            'showNotice' => false,
            _ => null,
          };
      final TrayService tray = TrayService(channel: channel);
      await tray.init(onItem: (_) {});

      expect(await tray.showNotice('EZSide', 'x'), isFalse);
    });

    test('WM_CLOSE on the tray window quits', () async {
      final List<TrayMenuItem> items = <TrayMenuItem>[];
      final TrayService tray = TrayService(channel: channel);
      await tray.init(onItem: items.add);

      await fromNative('quit');

      expect(items, <TrayMenuItem>[TrayMenuItem.quit]);
    });

    test('a click on the icon opens the window', () async {
      final List<TrayMenuItem> items = <TrayMenuItem>[];
      final TrayService tray = TrayService(channel: channel);
      await tray.init(onItem: items.add);

      await fromNative('open');

      expect(items, <TrayMenuItem>[TrayMenuItem.open]);
    });

    test('the menu reads the startup state first, then reports the choice',
        () async {
      reply = (MethodCall call) => switch (call.method) {
            'init' => true,
            'popUpMenu' => 'startWithWindows',
            _ => null,
          };
      final List<TrayMenuItem> items = <TrayMenuItem>[];
      final TrayService tray = TrayService(channel: channel);
      await tray.init(
        onItem: items.add,
        onMenuOpening: () => tray.setStartupChecked(false),
      );

      await fromNative('menu');

      expect(
        calls.map((MethodCall call) => call.method),
        <String>['init', 'setStartupChecked', 'popUpMenu'],
      );
      expect(items, <TrayMenuItem>[TrayMenuItem.startWithWindows]);
    });

    test('a dismissed menu reports nothing', () async {
      final List<TrayMenuItem> items = <TrayMenuItem>[];
      final TrayService tray = TrayService(channel: channel);
      await tray.init(onItem: items.add);

      await fromNative('menu');

      expect(items, isEmpty);
    });

    test('dispose removes the icon once', () async {
      final TrayService tray = TrayService(channel: channel);
      await tray.init(onItem: (_) {});

      await tray.dispose();
      await tray.dispose();
      await tray.setStatus('x');

      expect(
        calls.map((MethodCall call) => call.method),
        <String>['init', 'dispose'],
      );
      expect(tray.isReady, isFalse);
    });
  });
}
