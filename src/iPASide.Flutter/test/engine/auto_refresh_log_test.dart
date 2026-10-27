import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/auto_refresh_log.dart';
import 'package:ipaside/engine/models.dart';

/// 2026-07-25T00:01:02 UTC, i.e. offset `+00:00`.
final DateTime _utc = DateTime.utc(2026, 7, 25, 0, 1, 2);
const String _utcStamp = '2026-07-25T00:01:02+00:00';

void main() {
  group('AutoRefreshLog.formatTimestamp', () {
    test('renders a UTC timestamp with a numeric zero offset', () {
      expect(AutoRefreshLog.formatTimestamp(_utc), _utcStamp);
    });

    test('zero-pads every field', () {
      expect(
        AutoRefreshLog.formatTimestamp(DateTime.utc(2026, 1, 2, 3, 4, 5)),
        '2026-01-02T03:04:05+00:00',
      );
    });

    test('drops sub-second precision', () {
      expect(
        AutoRefreshLog.formatTimestamp(
          DateTime.utc(2026, 7, 25, 0, 1, 2, 999, 999),
        ),
        _utcStamp,
      );
    });

    test('renders a local timestamp with this machine\'s offset', () {
      final DateTime local = DateTime(2026, 7, 25, 0, 1, 2);
      final Duration offset = local.timeZoneOffset;
      final String sign = offset.isNegative ? '-' : '+';
      final Duration magnitude = offset.abs();
      final String expected = '2026-07-25T00:01:02$sign'
          '${magnitude.inHours.toString().padLeft(2, '0')}:'
          '${magnitude.inMinutes.remainder(60).toString().padLeft(2, '0')}';

      expect(AutoRefreshLog.formatTimestamp(local), expected);
      expect(
        AutoRefreshLog.formatTimestamp(local),
        matches(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$'),
      );
    });
  });

  group('AutoRefreshLog.formatLines', () {
    test('emits one line per app', () {
      final List<String> lines = AutoRefreshLog.formatLines(
        _utc,
        const RefreshSummary(
          refreshed: <RefreshEntry>[
            RefreshEntry(bundleId: 'com.a', status: 'refreshed'),
            RefreshEntry(bundleId: 'com.b', status: 'skipped'),
          ],
        ),
      );

      expect(lines, <String>[
        '$_utcStamp com.a refreshed',
        '$_utcStamp com.b skipped',
      ]);
    });

    test('renders a failure with its cleaned reason', () {
      final List<String> lines = AutoRefreshLog.formatLines(
        _utc,
        const RefreshSummary(
          refreshed: <RefreshEntry>[
            RefreshEntry(
              bundleId: 'com.a',
              status: 'error',
              error: 'Engine exited with code 1. Sideload failed: no device',
            ),
          ],
        ),
      );

      expect(lines, <String>['$_utcStamp com.a error: no device']);
    });

    test('substitutes a default reason for a blank error', () {
      final List<String> lines = AutoRefreshLog.formatLines(
        _utc,
        const RefreshSummary(
          refreshed: <RefreshEntry>[
            RefreshEntry(bundleId: 'com.a', status: 'error', error: '   '),
            RefreshEntry(bundleId: 'com.b', status: 'error'),
          ],
        ),
      );

      expect(lines, <String>[
        '$_utcStamp com.a error: refresh failed',
        '$_utcStamp com.b error: refresh failed',
      ]);
    });

    test('substitutes a default reason when cleaning empties the error', () {
      final List<String> lines = AutoRefreshLog.formatLines(
        _utc,
        const RefreshSummary(
          refreshed: <RefreshEntry>[
            RefreshEntry(
              bundleId: 'com.a',
              status: 'error',
              error: 'Login failed:  ',
            ),
          ],
        ),
      );

      expect(lines, <String>['$_utcStamp com.a error: refresh failed']);
    });

    test('substitutes placeholders for a blank bundle id and status', () {
      final List<String> lines = AutoRefreshLog.formatLines(
        _utc,
        const RefreshSummary(
          refreshed: <RefreshEntry>[
            RefreshEntry(bundleId: '', status: ''),
            RefreshEntry(),
          ],
        ),
      );

      expect(lines, <String>[
        '$_utcStamp ? unknown',
        '$_utcStamp ? unknown',
      ]);
    });

    test('an empty summary emits nothing', () {
      expect(AutoRefreshLog.formatLines(_utc, const RefreshSummary()), isEmpty);
    });
  });

  group('AutoRefreshLog single-line helpers', () {
    test('nothing-to-refresh line', () {
      expect(
        AutoRefreshLog.formatNothingToRefresh(_utc),
        '$_utcStamp nothing to refresh',
      );
    });

    test('run failure cleans the message', () {
      expect(
        AutoRefreshLog.formatRunFailure(_utc, 'Sideload failed: no device'),
        '$_utcStamp error: no device',
      );
    });

    test('run failure falls back when the message is blank', () {
      expect(
        AutoRefreshLog.formatRunFailure(_utc, '   '),
        '$_utcStamp error: auto-refresh failed',
      );
    });

    test('a null message keeps cleanError\'s "error" literal', () {
      expect(
        AutoRefreshLog.formatRunFailure(_utc, null),
        '$_utcStamp error: error',
      );
    });
  });
}
