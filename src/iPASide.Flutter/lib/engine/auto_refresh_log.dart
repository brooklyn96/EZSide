// Ported from iPASide.App/Engine/AutoRefreshLog.cs.

import 'engine_exception.dart';
import 'models.dart';

/// Formats the log lines the headless `--auto-refresh` run appends to its log
/// file.
///
/// The engine reports `ok` for a refresh even when individual apps fail, so a
/// single overall line would hide failures; [formatLines] walks
/// [RefreshSummary.refreshed] and emits exactly ONE line per app. Everything
/// here is pure (the timestamp is injected) so the runner stays a thin driver
/// and the formatting stays testable.
abstract final class AutoRefreshLog {
  /// Renders one log line per refreshed app: the timestamp, the bundle id, the
  /// status, and - for failures - the cleaned error text.
  static List<String> formatLines(DateTime timestamp, RefreshSummary summary) {
    final String ts = formatTimestamp(timestamp);
    final List<String> lines = <String>[];

    for (final RefreshEntry entry in summary.refreshed) {
      final String bundleId =
          (entry.bundleId == null || entry.bundleId!.isEmpty)
              ? '?'
              : entry.bundleId!;
      final String status =
          (entry.status == null || entry.status!.isEmpty)
              ? 'unknown'
              : entry.status!;

      if (status == 'error') {
        String reason = (entry.error == null || entry.error!.trim().isEmpty)
            ? 'refresh failed'
            : EngineException.cleanError(entry.error);
        if (reason.isEmpty) {
          reason = 'refresh failed';
        }
        lines.add('$ts $bundleId error: $reason');
      } else {
        lines.add('$ts $bundleId $status');
      }
    }

    return lines;
  }

  /// The shared timestamp prefix used by every auto-refresh log line.
  ///
  /// ISO 8601 with a numeric offset (`2026-07-25T00:01:02+05:30`), matching the
  /// C# format string `yyyy-MM-dd'T'HH:mm:sszzz`. `DateTime.toIso8601String`
  /// cannot be used: it emits `Z` for UTC values and no offset at all for local
  /// ones. A UTC [timestamp] renders as `+00:00`.
  static String formatTimestamp(DateTime timestamp) {
    final Duration offset = timestamp.timeZoneOffset;
    final Duration magnitude = offset.abs();
    final String sign = offset.isNegative ? '-' : '+';

    return '${_pad(timestamp.year, 4)}-${_pad(timestamp.month, 2)}-'
        '${_pad(timestamp.day, 2)}T${_pad(timestamp.hour, 2)}:'
        '${_pad(timestamp.minute, 2)}:${_pad(timestamp.second, 2)}'
        '$sign${_pad(magnitude.inHours, 2)}:'
        '${_pad(magnitude.inMinutes.remainder(60), 2)}';
  }

  /// The single line written when a run finds nothing to refresh.
  static String formatNothingToRefresh(DateTime timestamp) =>
      '${formatTimestamp(timestamp)} nothing to refresh';

  /// The single line written when the whole run fails (engine unreachable, ...).
  static String formatRunFailure(DateTime timestamp, String? message) {
    String reason = EngineException.cleanError(message);
    if (reason.isEmpty) {
      reason = 'auto-refresh failed';
    }
    return '${formatTimestamp(timestamp)} error: $reason';
  }

  static String _pad(int value, int width) =>
      value.toString().padLeft(width, '0');
}
