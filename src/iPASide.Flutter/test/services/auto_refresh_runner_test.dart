import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine.dart';
import 'package:ipaside/platform/app_paths.dart';
import 'package:ipaside/services/auto_refresh_runner.dart';
import 'package:ipaside/services/settings_store.dart';

/// A transport stand-in that records argv and replays one canned frame.
class _FakeRunner with EngineCommandRunner {
  _FakeRunner({this.outcome});

  /// The result frame to answer with, or an error to throw. Null answers with an
  /// empty summary.
  Object? outcome;

  final List<List<String>> calls = <List<String>>[];

  @override
  Future<EngineResult> run(
    List<String> args, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  }) async {
    calls.add(args);
    final Object? result = outcome;
    if (result == null) {
      return const EngineResult(ok: true, data: <String, dynamic>{});
    }
    if (result is EngineResult) return result;
    throw result;
  }
}

/// An in-memory settings store, so the headless run never reads the real file.
class _FakeSettings extends SettingsStore {
  _FakeSettings({
    this.signedIpa = const SignedIpaSettings(),
    this.connection = 'auto',
  });

  SignedIpaSettings signedIpa;
  String connection;
  int reads = 0;

  @override
  String loadConnection() => connection;

  @override
  SignedIpaSettings loadSignedIpa() {
    reads++;
    return signedIpa;
  }
}

void main() {
  late Directory temp;
  late AppPaths paths;

  /// Every notice the run asked to show; a real message box would block CI.
  final List<(String, String)> notices = <(String, String)>[];
  void notice(String title, String message) => notices.add((title, message));

  setUp(() {
    notices.clear();
    temp = Directory.systemTemp.createTempSync('ipaside_autorefresh');
    paths = AppPaths.rooted(temp.path);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  String log() {
    final File file = File(paths.autoRefreshLogPath);
    return file.existsSync() ? file.readAsStringSync() : '';
  }

  group('AutoRefreshRunner.isRequested', () {
    test('matches the flag whatever its case', () {
      expect(AutoRefreshRunner.isRequested(<String>['--AUTO-REFRESH']), isTrue);
      expect(AutoRefreshRunner.isRequested(<String>['--auto-refresh']), isTrue);
      expect(AutoRefreshRunner.isRequested(<String>['-x', '--auto-refresh']),
          isTrue);
    });

    test('is absent from an ordinary launch', () {
      expect(AutoRefreshRunner.isRequested(const <String>[]), isFalse);
      expect(AutoRefreshRunner.isRequested(<String>['--autorefresh']), isFalse);
    });
  });

  // The scheduled run is the one nobody watches: if it ignored the keep-signed
  // setting it would quietly delete the files the user asked to keep, every
  // night, with nothing on screen to notice.
  group('AutoRefreshRunner keep-signed setting', () {
    test('refreshes only what is due, with neither flag by default', () async {
      final _FakeRunner runner = _FakeRunner();

      final int code = await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: runner,
        notice: notice,
      );

      expect(code, 0);
      expect(
        runner.calls.single,
        <String>['refresh', '--unattended'],
        reason: 'neither --all nor --bundle-id is how the engine is told '
            '"only the ones that are due"; --unattended makes it check the '
            'phone first',
      );
    });

    test('passes the stored connection to the engine', () async {
      final _FakeRunner runner = _FakeRunner();

      await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(connection: 'wifi'),
        transport: runner,
        notice: notice,
      );

      expect(
        runner.calls.single,
        <String>['refresh', '--unattended', '--connection', 'wifi'],
      );
    });

    test('passes --keep-signed when the setting is on', () async {
      final _FakeRunner runner = _FakeRunner();

      await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(
          signedIpa: const SignedIpaSettings(keep: true),
        ),
        transport: runner,
        notice: notice,
      );

      expect(
        runner.calls.single,
        <String>['refresh', '--unattended', '--keep-signed'],
      );
    });

    test('passes the configured folder too', () async {
      final _FakeRunner runner = _FakeRunner();

      await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(
          signedIpa: const SignedIpaSettings(
            keep: true,
            directory: r'D:\Signed',
          ),
        ),
        transport: runner,
        notice: notice,
      );

      expect(runner.calls.single, <String>[
        'refresh',
        '--unattended',
        '--keep-signed',
        '--signed-dir',
        r'D:\Signed',
      ]);
    });

    test('reads the setting on the run, not at import time', () async {
      final _FakeSettings settings = _FakeSettings();

      await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: settings,
        transport: _FakeRunner(),
        notice: notice,
      );

      expect(settings.reads, 1);
    });
  });

  group('AutoRefreshRunner failure notice', () {
    test('a failed app shows one notice, after the log is written', () async {
      String? logAtNotice;
      final _FakeRunner runner = _FakeRunner(
        outcome: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'refreshed': <dynamic>[
              <String, dynamic>{'bundle_id': 'com.a', 'status': 'error'},
              <String, dynamic>{'bundle_id': 'com.b', 'status': 'error'},
              <String, dynamic>{'bundle_id': 'com.c', 'status': 'installed'},
            ],
          },
        ),
      );

      final int code = await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: runner,
        notice: (String title, String message) {
          logAtNotice = log();
          notice(title, message);
        },
      );

      expect(code, 1);
      expect(notices, hasLength(1));
      expect(notices.single.$1, 'EZSide');
      expect(notices.single.$2, contains('2 app(s)'));
      expect(notices.single.$2, contains('Library'));
      expect(notices.single.$2, contains('thử lại'));
      expect(logAtNotice, contains('com.a'));
    });

    test('a partial failure frame (ok: false) still lists the failed app',
        () async {
      // Engine exit code 2: the serve frame is ok:false but carries the list.
      final int code = await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: _FakeRunner(
          outcome: const EngineResult(
            ok: false,
            data: <String, dynamic>{
              'status': 'done',
              'count': 2,
              'refreshed': <dynamic>[
                <String, dynamic>{'bundle_id': 'com.a', 'status': 'ok'},
                <String, dynamic>{
                  'bundle_id': 'com.b',
                  'status': 'error',
                  'error': 'device is not connected',
                },
              ],
            },
          ),
        ),
        notice: notice,
      );

      expect(code, 1);
      expect(notices, hasLength(1));
      expect(notices.single.$2, contains('1 app(s)'));
      expect(log(), contains('com.a'));
      expect(log(), contains('com.b'));
      expect(log(), contains('device is not connected'));
    });

    test('a thrown run shows one notice and exits 1', () async {
      final int code = await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: _FakeRunner(outcome: EngineException('engine down')),
        notice: notice,
      );

      expect(code, 1);
      expect(notices, hasLength(1));
      expect(notices.single.$2, contains('could not refresh'));
    });

    test('all apps succeeding shows nothing', () async {
      final int code = await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: _FakeRunner(
          outcome: const EngineResult(
            ok: true,
            data: <String, dynamic>{
              'refreshed': <dynamic>[
                <String, dynamic>{'bundle_id': 'com.a', 'status': 'installed'},
              ],
            },
          ),
        ),
        notice: notice,
      );

      expect(code, 0);
      expect(notices, isEmpty);
    });

    test('nothing due shows nothing', () async {
      final int code = await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: _FakeRunner(),
        notice: notice,
      );

      expect(code, 0);
      expect(notices, isEmpty);
    });

    test('a notice that throws does not change the exit code', () async {
      final int code = await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: _FakeRunner(outcome: EngineException('engine down')),
        notice: (String title, String message) => throw StateError('no ui'),
      );

      expect(code, 1);
    });
  });

  /// A summary with one app per status; every status but 'ok' carries an error
  /// text, as the engine's deferred and error entries do.
  EngineResult summaryOf(List<String> statuses) => EngineResult(
        ok: true,
        data: <String, dynamic>{
          'refreshed': <dynamic>[
            for (int i = 0; i < statuses.length; i++)
              <String, dynamic>{
                'bundle_id': 'com.app$i',
                'status': statuses[i],
                if (statuses[i] != 'ok') 'error': 'Device X is not connected.',
              },
          ],
        },
      );

  group('AutoRefreshRunner deferred apps', () {
    test('ok and deferred only: exit 0, no notice, logged as waiting',
        () async {
      final int code = await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: _FakeRunner(outcome: summaryOf(<String>['ok', 'deferred'])),
        notice: notice,
      );

      expect(code, 0);
      expect(notices, isEmpty);
      expect(log(), contains('com.app0 ok'));
      expect(
        log(),
        matches(RegExp(r'\S+ com\.app1 waiting: Device X is not connected\.')),
      );
      expect(File(paths.autoRefreshNoticeStampPath).existsSync(), isFalse);
    });

    test('a deferred app next to a failed one counts only the failure',
        () async {
      final int code = await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport:
            _FakeRunner(outcome: summaryOf(<String>['deferred', 'error'])),
        notice: notice,
      );

      expect(code, 1);
      expect(notices.single.$2, contains('1 app(s)'));
    });
  });

  group('AutoRefreshRunner notice rate limit', () {
    final DateTime t0 = DateTime.utc(2026, 10, 28, 8);

    Future<int> failingRun(DateTime at) => AutoRefreshRunner.run(
          guiRunning: () => false,
          paths: paths,
          settings: _FakeSettings(),
          transport: _FakeRunner(outcome: summaryOf(<String>['error'])),
          notice: notice,
          now: () => at,
        );

    File stamp() => File(paths.autoRefreshNoticeStampPath);

    test('the first failure shows the notice and stamps the time', () async {
      expect(await failingRun(t0), 1);

      expect(notices, hasLength(1));
      expect(DateTime.parse(stamp().readAsStringSync()), t0);
    });

    test('a failure within 20 hours logs and exits 1 but shows nothing',
        () async {
      await failingRun(t0);
      notices.clear();

      final int code = await failingRun(t0.add(const Duration(hours: 19)));

      expect(code, 1);
      expect(notices, isEmpty);
      expect(
        RegExp('com.app0 error').allMatches(log()),
        hasLength(2),
        reason: 'the log is written on every run',
      );
      expect(
        DateTime.parse(stamp().readAsStringSync()),
        t0,
        reason: 'a suppressed notice does not move the stamp',
      );
    });

    test('after 20 hours the notice is shown again and the stamp moves',
        () async {
      await failingRun(t0);
      notices.clear();
      final DateTime later = t0.add(const Duration(hours: 20));

      await failingRun(later);

      expect(notices, hasLength(1));
      expect(DateTime.parse(stamp().readAsStringSync()), later);
    });

    test('a garbled stamp counts as no notice shown yet', () async {
      stamp().writeAsStringSync('not a time');

      expect(await failingRun(t0), 1);

      expect(notices, hasLength(1));
      expect(DateTime.parse(stamp().readAsStringSync()), t0);
    });

    test('a stamp from the future does not silence the notice', () async {
      stamp().writeAsStringSync(
        t0.add(const Duration(days: 3)).toIso8601String(),
      );

      await failingRun(t0);

      expect(notices, hasLength(1));
    });

    test('a stamp that cannot be read or written leaves the exit code alone',
        () async {
      // A folder where the file should be: reading and writing both fail.
      Directory(paths.autoRefreshNoticeStampPath).createSync();

      final int code = await failingRun(t0);

      expect(code, 1);
      expect(notices, hasLength(1));
    });

    test('the stamp is already written when the notice is shown', () async {
      // The box blocks until closed and the task's 1-hour limit can kill the
      // process meanwhile, so the stamp must not wait for notice() to return.
      bool stampedAtNotice = false;

      await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: _FakeRunner(outcome: summaryOf(<String>['error'])),
        notice: (String title, String message) {
          stampedAtNotice = stamp().existsSync();
        },
        now: () => t0,
      );

      expect(stampedAtNotice, isTrue);
      expect(DateTime.parse(stamp().readAsStringSync()), t0);
    });

    test('a notice that throws still leaves the stamp and exit code 1',
        () async {
      final int code = await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: _FakeRunner(outcome: summaryOf(<String>['error'])),
        notice: (String title, String message) => throw StateError('no ui'),
        now: () => t0,
      );

      expect(code, 1);
      expect(DateTime.parse(stamp().readAsStringSync()), t0);
    });

    test('a run killed during the notice is not noticed again next hour',
        () async {
      // First run: the box is left open and the process is killed - modelled by
      // a notice that throws after the stamp was written.
      await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: _FakeRunner(outcome: summaryOf(<String>['error'])),
        notice: (String title, String message) => throw StateError('killed'),
        now: () => t0,
      );

      await failingRun(t0.add(const Duration(hours: 1)));

      expect(notices, isEmpty);
    });

    test('a thrown run is rate limited the same way', () async {
      Future<int> thrown(DateTime at) => AutoRefreshRunner.run(
            guiRunning: () => false,
            paths: paths,
            settings: _FakeSettings(),
            transport: _FakeRunner(outcome: EngineException('engine down')),
            notice: notice,
            now: () => at,
          );

      await thrown(t0);
      await thrown(t0.add(const Duration(hours: 1)));

      expect(notices, hasLength(1));
    });
  });

  group('AutoRefreshRunner logging', () {
    test('records that there was nothing to do', () async {
      await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: _FakeRunner(),
        notice: notice,
      );

      expect(log(), contains('nothing to refresh'));
    });

    test('writes one line per app the engine reported on', () async {
      final _FakeRunner runner = _FakeRunner(
        outcome: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'refreshed': <dynamic>[
              <String, dynamic>{'bundle_id': 'com.a', 'status': 'installed'},
              <String, dynamic>{
                'bundle_id': 'com.b',
                'status': 'error',
                'error': 'device is not connected',
              },
            ],
          },
        ),
      );

      final int code = await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: runner,
        notice: notice,
      );

      expect(code, 1, reason: 'a failed app makes the scheduled task fail');
      expect(log(), contains('com.a'));
      expect(log(), contains('com.b'));
      expect(log(), contains('device is not connected'));
    });

    test('a thrown run is logged and exits non-zero', () async {
      final _FakeRunner runner = _FakeRunner(
        outcome: EngineException('the engine could not be started'),
      );

      final int code = await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: runner,
        notice: notice,
      );

      expect(code, 1);
      expect(log(), contains('the engine could not be started'));
    });

    test('creates the data root it logs into', () async {
      final AppPaths nested = AppPaths.rooted(
        '${temp.path}${Platform.pathSeparator}fresh',
      );

      await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: nested,
        settings: _FakeSettings(),
        transport: _FakeRunner(),
        notice: notice,
      );

      expect(File(nested.autoRefreshLogPath).existsSync(), isTrue);
    });

    test('keeps only the newest 2000 lines', () async {
      File(paths.autoRefreshLogPath).writeAsStringSync(
        '${List<String>.generate(3000, (int i) => 'old $i').join('\n')}\n',
      );

      await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: _FakeRunner(),
        notice: notice,
      );

      final List<String> lines =
          File(paths.autoRefreshLogPath).readAsLinesSync();
      expect(lines, hasLength(2000));
      expect(lines.first, 'old 1001');
      expect(lines[1998], 'old 2999');
      expect(lines.last, contains('nothing to refresh'));
      expect(File('${paths.autoRefreshLogPath}.tmp').existsSync(), isFalse);
    });

    test('a log under the limit is left alone', () async {
      File(paths.autoRefreshLogPath).writeAsStringSync('old 0\nold 1\n');

      await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: _FakeRunner(),
        notice: notice,
      );

      final List<String> lines =
          File(paths.autoRefreshLogPath).readAsLinesSync();
      expect(lines, hasLength(3));
      expect(lines.first, 'old 0');
    });

    test('a log that cannot be trimmed keeps the new line and the exit code',
        () async {
      File(paths.autoRefreshLogPath).writeAsStringSync(
        '${List<String>.generate(2500, (int i) => 'old $i').join('\n')}\n',
      );
      // A folder where the temp file should go: the trim cannot write.
      Directory('${paths.autoRefreshLogPath}.tmp').createSync();

      final int code = await AutoRefreshRunner.run(
        guiRunning: () => false,
        paths: paths,
        settings: _FakeSettings(),
        transport: _FakeRunner(),
        notice: notice,
      );

      expect(code, 0);
      final List<String> lines =
          File(paths.autoRefreshLogPath).readAsLinesSync();
      expect(lines, hasLength(2501));
      expect(lines.last, contains('nothing to refresh'));
    });
  });

  group('AutoRefreshRunner.claimNotice', () {
    final DateTime t0 = DateTime.utc(2026, 10, 28, 8);
    File stamp() => File(paths.autoRefreshNoticeStampPath);

    test('the first claim succeeds and writes the stamp', () {
      expect(AutoRefreshRunner.claimNotice(paths: paths, now: t0), isTrue);
      expect(DateTime.parse(stamp().readAsStringSync()), t0);
    });

    test('a second claim within 20 hours is refused and keeps the stamp', () {
      AutoRefreshRunner.claimNotice(paths: paths, now: t0);

      expect(
        AutoRefreshRunner.claimNotice(
          paths: paths,
          now: t0.add(const Duration(hours: 19, minutes: 59)),
        ),
        isFalse,
      );
      expect(DateTime.parse(stamp().readAsStringSync()), t0);
    });

    test('after 20 hours the claim succeeds and moves the stamp', () {
      AutoRefreshRunner.claimNotice(paths: paths, now: t0);
      final DateTime later = t0.add(const Duration(hours: 20));

      expect(AutoRefreshRunner.claimNotice(paths: paths, now: later), isTrue);
      expect(DateTime.parse(stamp().readAsStringSync()), later);
    });

    test('a garbled stamp or one in the future does not block a claim', () {
      stamp().writeAsStringSync('not a time');
      expect(AutoRefreshRunner.claimNotice(paths: paths, now: t0), isTrue);

      stamp().writeAsStringSync(
        t0.add(const Duration(days: 3)).toIso8601String(),
      );
      expect(AutoRefreshRunner.claimNotice(paths: paths, now: t0), isTrue);
    });

    test('an unwritable stamp still allows the claim and never throws', () {
      Directory(paths.autoRefreshNoticeStampPath).createSync();

      expect(AutoRefreshRunner.claimNotice(paths: paths, now: t0), isTrue);
    });
  });

  group('AutoRefreshRunner with the GUI open', () {
    final DateTime t0 = DateTime.utc(2026, 10, 28, 8);

    Future<int> failingRun({required bool gui}) => AutoRefreshRunner.run(
          paths: paths,
          settings: _FakeSettings(),
          transport: _FakeRunner(outcome: EngineException('engine down')),
          notice: notice,
          now: () => t0,
          guiRunning: () => gui,
        );

    test('a failure shows no box and leaves no stamp, but is logged', () async {
      final int code = await failingRun(gui: true);

      expect(code, 1);
      expect(notices, isEmpty);
      expect(File(paths.autoRefreshNoticeStampPath).existsSync(), isFalse);
      expect(log(), contains('engine down'));
    });

    test('the stamp stays free for the GUI to claim', () async {
      await failingRun(gui: true);

      expect(AutoRefreshRunner.claimNotice(paths: paths, now: t0), isTrue);
    });

    test('without the GUI the box and the stamp are as before', () async {
      final int code = await failingRun(gui: false);

      expect(code, 1);
      expect(notices, hasLength(1));
      expect(
        DateTime.parse(File(paths.autoRefreshNoticeStampPath).readAsStringSync()),
        t0,
      );
    });
  });
}
