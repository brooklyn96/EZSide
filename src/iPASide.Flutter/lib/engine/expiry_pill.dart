// Ported from iPASide.App/Engine/ExpiryPill.cs.

import 'dart:math' as math;

import 'models.dart';

/// Severity of a library app's free-signature expiry pill.
enum ExpiryLevel {
  /// Signature already expired.
  expired,

  /// Expiry could not be determined.
  unknown,

  /// Comfortable time remaining.
  ok,

  /// Expiring soon (two days or fewer).
  warn,
}

/// A classified expiry pill: its severity and the exact label to show.
class ExpiryPill {
  /// Creates a pill.
  const ExpiryPill(this.level, this.text);

  /// How urgent the expiry is.
  final ExpiryLevel level;

  /// The label to render, e.g. `3 days left`.
  final String text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExpiryPill && other.level == level && other.text == text;

  @override
  int get hashCode => Object.hash(level, text);

  @override
  String toString() => 'ExpiryPill(level: ${level.name}, text: $text)';
}

/// Classifies an install record's expiry into a pill, verbatim from the web UI's
/// `libRow()` logic: expired wins, then unknown when days are null, otherwise the
/// day count is floored and clamped at zero, `warn` when two days or fewer
/// remain, and the label reads `under a day` below one day.
abstract final class ExpiryPills {
  /// Classifies a library record.
  static ExpiryPill classifyRecord(InstallRecord record) =>
      classify(record.expired, record.daysLeft);

  /// Classifies raw expiry data.
  static ExpiryPill classify(bool expired, double? daysLeft) {
    if (expired) {
      return const ExpiryPill(ExpiryLevel.expired, 'Expired');
    }

    // JSON cannot carry NaN or Infinity, but `floor()` throws on them in Dart
    // (unlike the C# cast), so a hand-built value can never crash a pill.
    if (daysLeft == null || !daysLeft.isFinite) {
      return const ExpiryPill(ExpiryLevel.unknown, 'unknown');
    }

    final int days = math.max(0, daysLeft.floor());
    final ExpiryLevel level =
        daysLeft <= 2 ? ExpiryLevel.warn : ExpiryLevel.ok;
    final String text = switch (days) {
      < 1 => 'under a day',
      1 => '1 day left',
      _ => '$days days left',
    };

    return ExpiryPill(level, text);
  }
}
