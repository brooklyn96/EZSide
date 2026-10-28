import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/auto_refresh_log.dart';
import 'package:ipaside/engine/auto_refresh_status.dart';
import 'package:ipaside/engine/models.dart';

void main() {
  late Directory temp;
  late String logPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('ipaside_refresh_status');
    logPath = '${temp.path}${Platform.pathSeparator}autorefresh.log';
  });

  tearDown(() => temp.deleteSync(recursive: true));

  final DateTime t1 = DateTime(2026, 10, 28, 8, 5, 3);
  final DateTime t2 = DateTime(2026, 10, 28, 9, 5, 4);

  /// Writes [lines] one per line the way the runner does, line end included.
  void write(List<String> lines) => File(logPath).writeAsStringSync(
        lines.map((String line) => '$line\n').join(),
      );

  List<String> summary(DateTime at, List<RefreshEntry> entries) =>
      AutoRefreshLog.formatLines(at, RefreshSummary(refreshed: entries));

  group('lastAutoRefreshRun', () {
    test('a missing file is null', () {
      expect(lastAutoRefreshRun(logPath), isNull);
    });

    test('an empty file is null', () {
      File(logPath).writeAsStringSync('');
      expect(lastAutoRefreshRun(logPath), isNull);
    });

    test('a file with no known line is null', () {
      write(<String>['hello', 'not a log line', '']);
      expect(lastAutoRefreshRun(logPath), isNull);
    });

    test('a directory in place of the file does not throw', () {
      Directory(logPath).createSync();
      expect(lastAutoRefreshRun(logPath), isNull);
    });

    test('nothing to refresh', () {
      write(<String>[AutoRefreshLog.formatNothingToRefresh(t1)]);

      final AutoRefreshRun run = lastAutoRefreshRun(logPath)!;

      expect(run.outcome, AutoRefreshOutcome.nothingDue);
      expect(run.refreshed, 0);
      expect(run.at, t1);
    });

    test('refreshed apps are counted', () {
      write(summary(t1, const <RefreshEntry>[
        RefreshEntry(bundleId: 'com.a', status: 'installed'),
        RefreshEntry(bundleId: 'com.b', status: 'installed'),
      ]));

      final AutoRefreshRun run = lastAutoRefreshRun(logPath)!;

      expect(run.outcome, AutoRefreshOutcome.refreshed);
      expect(run.refreshed, 2);
      expect(run.at, t1);
      expect(run.detail, 'com.a, com.b');
    });

    test('a failed app makes the run failed and keeps the success count', () {
      write(summary(t1, const <RefreshEntry>[
        RefreshEntry(bundleId: 'com.a', status: 'installed'),
        RefreshEntry(
          bundleId: 'com.b',
          status: 'error',
          error: 'device is not connected',
        ),
      ]));

      final AutoRefreshRun run = lastAutoRefreshRun(logPath)!;

      expect(run.outcome, AutoRefreshOutcome.failed);
      expect(run.refreshed, 1);
      expect(run.failedApps, 1);
      expect(run.detail, contains('device is not connected'));
    });

    test('a whole-run failure line is a failed run', () {
      write(<String>[AutoRefreshLog.formatRunFailure(t1, 'engine down')]);

      final AutoRefreshRun run = lastAutoRefreshRun(logPath)!;

      expect(run.outcome, AutoRefreshOutcome.failed);
      expect(run.refreshed, 0);
      expect(run.failedApps, 0, reason: 'the runner passes 0 for a thrown run');
      expect(run.detail, 'engine down');
    });

    test('failedApps counts every per-app error line of the run only', () {
      write(<String>[
        ...summary(t1, const <RefreshEntry>[
          RefreshEntry(bundleId: 'com.z', status: 'error', error: 'old'),
        ]),
        ...summary(t2, const <RefreshEntry>[
          RefreshEntry(bundleId: 'com.a', status: 'error', error: 'x'),
          RefreshEntry(bundleId: 'com.b', status: 'installed'),
          RefreshEntry(bundleId: 'com.c', status: 'error', error: 'y'),
          RefreshEntry(bundleId: 'com.d', status: 'deferred'),
        ]),
      ]);

      final AutoRefreshRun run = lastAutoRefreshRun(logPath)!;

      expect(run.failedApps, 2);
      expect(run.refreshed, 1);
    });

    test('apps only waiting for their phone are not a failure', () {
      write(summary(t1, const <RefreshEntry>[
        RefreshEntry(
          bundleId: 'com.a',
          status: 'deferred',
          error: 'iPhone not reachable',
        ),
      ]));

      final AutoRefreshRun run = lastAutoRefreshRun(logPath)!;

      expect(run.outcome, AutoRefreshOutcome.nothingDue);
      expect(run.detail, 'iPhone not reachable');
    });

    test('only the newest run counts, older runs are ignored', () {
      write(<String>[
        ...summary(t1, const <RefreshEntry>[
          RefreshEntry(bundleId: 'com.a', status: 'error', error: 'old'),
        ]),
        ...summary(t2, const <RefreshEntry>[
          RefreshEntry(bundleId: 'com.a', status: 'installed'),
        ]),
      ]);

      final AutoRefreshRun run = lastAutoRefreshRun(logPath)!;

      expect(run.outcome, AutoRefreshOutcome.refreshed);
      expect(run.refreshed, 1);
      expect(run.at, t2);
    });

    test('a newer nothing-due run hides an older failure', () {
      write(<String>[
        AutoRefreshLog.formatRunFailure(t1, 'engine down'),
        AutoRefreshLog.formatNothingToRefresh(t2),
      ]);

      expect(
        lastAutoRefreshRun(logPath)!.outcome,
        AutoRefreshOutcome.nothingDue,
      );
    });

    test('a line cut off mid-write is ignored', () {
      final List<String> lines = summary(t1, const <RefreshEntry>[
        RefreshEntry(bundleId: 'com.a', status: 'installed'),
        RefreshEntry(bundleId: 'com.b', status: 'error', error: 'x'),
      ]);
      // The second line has no line end and is cut short.
      File(logPath).writeAsStringSync(
        '${lines.first}\n${lines.last.substring(0, lines.last.length - 6)}',
      );

      final AutoRefreshRun run = lastAutoRefreshRun(logPath)!;

      expect(run.outcome, AutoRefreshOutcome.refreshed);
      expect(run.refreshed, 1);
    });

    test('reads Windows line ends', () {
      File(logPath).writeAsStringSync(
        '${AutoRefreshLog.formatNothingToRefresh(t1)}\r\n',
      );

      expect(
        lastAutoRefreshRun(logPath)!.outcome,
        AutoRefreshOutcome.nothingDue,
      );
    });

    test('a log far larger than the tail still yields the newest run', () {
      final StringBuffer buffer = StringBuffer();
      for (int i = 0; i < 5000; i++) {
        buffer.writeln(AutoRefreshLog.formatRunFailure(t1, 'filler $i'));
      }
      buffer.writeln(AutoRefreshLog.formatNothingToRefresh(t2));
      File(logPath).writeAsStringSync(buffer.toString());

      final AutoRefreshRun run = lastAutoRefreshRun(logPath)!;

      expect(run.outcome, AutoRefreshOutcome.nothingDue);
      expect(run.at, t2);
    });
  });

  group('autoRefreshStatusLine', () {
    final DateTime now = DateTime(2026, 10, 28, 12);

    AutoRefreshRun run(AutoRefreshOutcome outcome, DateTime at, [int n = 0]) =>
        AutoRefreshRun(
          at: at,
          outcome: outcome,
          refreshed: n,
          failedApps: 0,
          detail: '',
        );

    test('never', () {
      expect(autoRefreshStatusLine(null, now: now), 'Last refresh: never');
    });

    test('refreshed today shows the time and the count', () {
      expect(
        autoRefreshStatusLine(
          run(AutoRefreshOutcome.refreshed, DateTime(2026, 10, 28, 9, 5), 3),
          now: now,
        ),
        'Last refresh: 09:05 — 3 refreshed',
      );
    });

    test('nothing due', () {
      expect(
        autoRefreshStatusLine(
          run(AutoRefreshOutcome.nothingDue, DateTime(2026, 10, 28, 11, 0)),
          now: now,
        ),
        'Last refresh: 11:00 — nothing due',
      );
    });

    test('failed', () {
      expect(
        autoRefreshStatusLine(
          run(AutoRefreshOutcome.failed, DateTime(2026, 10, 28, 0, 7)),
          now: now,
        ),
        'Last refresh: 00:07 — failed',
      );
    });

    test('an earlier day shows dd/MM HH:mm', () {
      expect(
        autoRefreshStatusLine(
          run(AutoRefreshOutcome.refreshed, DateTime(2026, 10, 7, 23, 59), 1),
          now: now,
        ),
        'Last refresh: 07/10 23:59 — 1 refreshed',
      );
    });

    test('the same day in another month is not today', () {
      expect(
        autoRefreshStatusLine(
          run(AutoRefreshOutcome.nothingDue, DateTime(2026, 9, 28, 8, 0)),
          now: now,
        ),
        'Last refresh: 28/09 08:00 — nothing due',
      );
    });
  });
}
