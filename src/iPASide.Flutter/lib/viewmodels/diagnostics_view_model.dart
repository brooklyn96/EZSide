import 'dart:async';

import '../engine/engine.dart';
import 'apple_support_view_model.dart';
import 'base_view_model.dart';

/// Status of one diagnostics row, or of the whole report.
enum DiagnosticsStatus {
  /// The check passed.
  ok,

  /// The check passed with a caveat, or its status was not recognised.
  warn,

  /// The check failed.
  fail,

  /// A status the engine reports that this build has no badge for.
  ///
  /// Only rows can be unknown: an unrecognised overall status falls back to
  /// [warn], the way the previous builds' banner did.
  unknown,
}

/// One `doctor` check: status badge, name and detail.
class DiagnosticsCheckRow {
  /// Creates a row for the diagnostics list.
  const DiagnosticsCheckRow({
    required this.status,
    required this.name,
    required this.detail,
  });

  /// Badge shown to the left of the row.
  final DiagnosticsStatus status;

  /// What was checked.
  final String name;

  /// Human-readable outcome, including any remediation hint.
  final String detail;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiagnosticsCheckRow &&
          other.status == status &&
          other.name == name &&
          other.detail == detail;

  @override
  int get hashCode => Object.hash(status, name, detail);

  @override
  String toString() =>
      'DiagnosticsCheckRow(status: $status, name: $name, detail: $detail)';
}

/// Diagnostics: runs `doctor` on creation, shows the overall banner and one
/// row per check, and can run the whole pass again.
///
/// A `fail` overall makes the engine exit non-zero, but [EngineApi.doctor]
/// still returns the report in that case — so a failing environment renders as
/// the report it is, not as an error.
class DiagnosticsViewModel extends BaseViewModel {
  /// Creates the view model and starts the first pass.
  ///
  /// [appleSupport] is optional and exists only to keep this screen honest: the
  /// Apple-service row reports what that model reports, so fixing the service from
  /// the banner above must not leave the row below still describing the old world.
  DiagnosticsViewModel({required this._engine, this._appleSupport}) {
    _appleState = _appleSupport?.status?.state;
    _appleSupport?.addListener(_onAppleSupportChanged);
    _load();
  }

  final EngineApi _engine;
  final AppleSupportViewModel? _appleSupport;

  /// The Apple-service verdict this report was built against.
  String? _appleState;

  bool _isLoading = true;
  String? _error;
  bool _hasReport = false;
  String _overallLabel = '';
  DiagnosticsStatus _overallStatus = DiagnosticsStatus.warn;
  List<DiagnosticsCheckRow> _checks = const <DiagnosticsCheckRow>[];

  bool get isLoading => _isLoading;

  /// Prefixed failure text, or null when the pass produced a report.
  String? get error => _error;

  bool get hasError => _error != null;

  /// True once a report is available to render.
  bool get hasReport => _hasReport;

  /// The banner sentence, e.g. `Overall status: OK`.
  String get overallLabel => _overallLabel;

  /// Tone of the banner; never [DiagnosticsStatus.unknown].
  DiagnosticsStatus get overallStatus => _overallStatus;

  /// One row per check. Replaced wholesale by each pass; treat as read-only.
  List<DiagnosticsCheckRow> get checks => _checks;

  /// Runs the checks again, unless a pass is already running.
  Future<void> reRun() async {
    if (_isLoading) return;
    await _load();
  }

  @override
  void dispose() {
    _appleSupport?.removeListener(_onAppleSupportChanged);
    super.dispose();
  }

  /// Re-runs the report when Apple's service verdict actually changed.
  ///
  /// Only on a change: a download in flight notifies on every chunk, and running
  /// the whole doctor pass 200 times would be a poor way to draw a progress bar.
  void _onAppleSupportChanged() {
    final String? next = _appleSupport?.status?.state;
    if (next == _appleState) return;
    _appleState = next;
    unawaited(reRun());
  }

  Future<void> _load() async {
    _isLoading = true;
    _error = null;
    _hasReport = false;
    _checks = const <DiagnosticsCheckRow>[];
    notify();

    try {
      final report = await _engine.doctor();

      // A missing overall renders as the warn banner, as does any status this
      // build has no badge for.
      final overall = report.overall == null || report.overall!.isEmpty
          ? 'warn'
          : report.overall!;
      _overallLabel = 'Overall status: ${overall.toUpperCase()}';
      _overallStatus = switch (overall) {
        'ok' => DiagnosticsStatus.ok,
        'fail' => DiagnosticsStatus.fail,
        _ => DiagnosticsStatus.warn,
      };

      _checks = <DiagnosticsCheckRow>[
        for (final check in report.checks)
          DiagnosticsCheckRow(
            status: _rowStatus(check.status),
            name: check.name ?? '',
            detail: check.detail ?? '',
          ),
      ];
      _hasReport = true;
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _error = 'Could not run diagnostics: ${BaseViewModel.errorText(error)}';
      }
    } finally {
      _isLoading = false;
      notify();
    }
  }

  static DiagnosticsStatus _rowStatus(String? status) => switch (status) {
    'ok' => DiagnosticsStatus.ok,
    'warn' => DiagnosticsStatus.warn,
    'fail' => DiagnosticsStatus.fail,
    _ => DiagnosticsStatus.unknown,
  };
}
