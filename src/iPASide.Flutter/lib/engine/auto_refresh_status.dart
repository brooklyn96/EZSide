import 'dart:convert';
import 'dart:io';

/// How the last headless `--auto-refresh` run ended.
enum AutoRefreshOutcome {
  /// At least one app was re-signed and none failed.
  refreshed,

  /// Nothing was due, or every due app was waiting for its phone.
  nothingDue,

  /// The run threw, or at least one app came back with an error.
  failed,
}

/// The last run recorded in `autorefresh.log`, as [lastAutoRefreshRun] reads it.
class AutoRefreshRun {
  /// Creates a run summary.
  const AutoRefreshRun({
    required this.at,
    required this.outcome,
    required this.refreshed,
    required this.failedApps,
    required this.detail,
  });

  /// When the run wrote its lines (local time).
  final DateTime at;

  /// How it ended.
  final AutoRefreshOutcome outcome;

  /// How many apps were re-signed without error in this run.
  final int refreshed;

  /// How many apps came back with an error in this run: the count the runner
  /// passes to `AutoRefreshRunner.failureText`. 0 when the whole run failed
  /// before any app was tried.
  final int failedApps;

  /// The first error text for a failed run, the waiting reason when apps were
  /// waiting for their phone, else the re-signed bundle ids; may be empty.
  final String detail;
}

/// Only this much of the log's end is read: the file holds up to 2000 lines.
const int _tailBytes = 64 * 1024;

/// `<timestamp> <rest>`, the prefix `AutoRefreshLog.formatTimestamp` writes on
/// every line.
final RegExp _linePattern = RegExp(
  r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}) (.+)$',
);

/// Reads the newest run from the log at [logPath], or null when the file is
/// missing, empty, or holds no line in a known format. Never throws.
///
/// A run is the lines that share one timestamp: the runner stamps every line of
/// a run with the same instant. A last line that was cut off mid-write (no line
/// end) is ignored.
AutoRefreshRun? lastAutoRefreshRun(String logPath) {
  try {
    final File file = File(logPath);
    if (!file.existsSync()) return null;

    final List<int> bytes;
    final int start;
    final RandomAccessFile reader = file.openSync();
    try {
      final int length = reader.lengthSync();
      start = length > _tailBytes ? length - _tailBytes : 0;
      reader.setPositionSync(start);
      bytes = reader.readSync(length - start);
    } finally {
      reader.closeSync();
    }

    final List<String> lines =
        utf8.decode(bytes, allowMalformed: true).split('\n');
    // The last piece is either empty (the file ends with a line end) or a line
    // still being written; the first is cut off when the read began mid-file.
    if (lines.isNotEmpty) lines.removeLast();
    if (start > 0 && lines.isNotEmpty) lines.removeAt(0);

    String? stamp;
    int refreshed = 0;
    int failedApps = 0;
    bool failed = false;
    String? error;
    String? waiting;
    final List<String> apps = <String>[];

    for (final String raw in lines.reversed) {
      final Match? match = _linePattern.firstMatch(raw.trimRight());
      if (match == null) continue;
      stamp ??= match.group(1);
      if (match.group(1) != stamp) break;

      final String rest = match.group(2)!;
      if (rest == 'nothing to refresh') continue;
      if (rest.startsWith('error:')) {
        // The whole run failed; there is no bundle id in front.
        failed = true;
        error = _reason(rest, 'error:');
        continue;
      }
      final int space = rest.indexOf(' ');
      if (space <= 0) continue;
      final String bundleId = rest.substring(0, space);
      final String status = rest.substring(space + 1);
      if (status.startsWith('error:')) {
        failed = true;
        failedApps++;
        // Walking backwards: the last assignment is the run's first error line.
        error = _reason(status, 'error:');
      } else if (status.startsWith('waiting:')) {
        waiting = _reason(status, 'waiting:');
      } else {
        refreshed++;
        apps.add(bundleId);
      }
    }

    if (stamp == null) return null;
    final DateTime? at = DateTime.tryParse(stamp)?.toLocal();
    if (at == null) return null;

    final AutoRefreshOutcome outcome = failed
        ? AutoRefreshOutcome.failed
        : refreshed > 0
            ? AutoRefreshOutcome.refreshed
            : AutoRefreshOutcome.nothingDue;
    return AutoRefreshRun(
      at: at,
      outcome: outcome,
      refreshed: refreshed,
      failedApps: failedApps,
      detail: failed
          ? (error ?? '')
          : refreshed > 0
              ? apps.reversed.join(', ')
              : (waiting ?? ''),
    );
  } catch (_) {
    return null;
  }
}

String _reason(String text, String prefix) =>
    text.substring(prefix.length).trim();

/// The one-line tray status for [run] (null: no run recorded yet):
/// `Last refresh: HH:mm — N refreshed`, `… — nothing due`, `… — failed`, or
/// `Last refresh: never`. A run from an earlier day shows `dd/MM HH:mm`.
/// [now] replaces the clock, for tests.
String autoRefreshStatusLine(AutoRefreshRun? run, {DateTime? now}) {
  if (run == null) return 'Last refresh: never';

  final DateTime today = (now ?? DateTime.now()).toLocal();
  final DateTime at = run.at.toLocal();
  final String time = '${_two(at.hour)}:${_two(at.minute)}';
  final bool sameDay = at.year == today.year &&
      at.month == today.month &&
      at.day == today.day;
  final String when = sameDay ? time : '${_two(at.day)}/${_two(at.month)} $time';

  final String result = switch (run.outcome) {
    AutoRefreshOutcome.refreshed => '${run.refreshed} refreshed',
    AutoRefreshOutcome.nothingDue => 'nothing due',
    AutoRefreshOutcome.failed => 'failed',
  };
  return 'Last refresh: $when — $result';
}

String _two(int value) => value.toString().padLeft(2, '0');
