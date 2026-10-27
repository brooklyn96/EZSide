import '../engine/engine.dart';

/// The phases one kind of run reports, in the order a stepper draws them.
///
/// Which phase names exist, what to call them, and which of them can honestly
/// report a percentage are all properties of the *flow*, not of the state folding
/// its frames in. Keeping them here means a flow with different phases is a new
/// constant rather than a second copy of [SideloadProgressState].
class ProgressSchedule {
  /// Creates a schedule. [steps], [phases] and [labels] are parallel lists.
  const ProgressSchedule({
    required this.steps,
    required this.phases,
    required this.labels,
    required this.determinate,
  });

  /// Titles the stepper shows, e.g. `Provision`.
  final List<String> steps;

  /// Engine phase names, in the same order as [steps].
  final List<String> phases;

  /// Step text to fall back on for a frame that names a phase but no step.
  final List<String> labels;

  /// Phases whose reported percentage means something.
  ///
  /// The rest are Apple round trips or a zip, neither of which can honestly
  /// report a share of the work done, so their bar should sweep rather than fill.
  final Set<String> determinate;

  /// Provision → sign → install: a plain sideload, and a refresh, which is one.
  static const ProgressSchedule sideload = ProgressSchedule(
    steps: <String>['Provision', 'Sign', 'Install'],
    phases: <String>['provision', 'sign', 'install'],
    labels: <String>['Provisioning\u2026', 'Signing\u2026', 'Installing\u2026'],
    determinate: <String>{'install'},
  );

  /// A LiveContainer setup, which downloads the app first and hands it the
  /// signing certificate afterwards.
  static const ProgressSchedule liveContainer = ProgressSchedule(
    steps: <String>['Download', 'Provision', 'Sign', 'Install', 'Finish'],
    phases: <String>['download', 'provision', 'sign', 'install', 'finalize'],
    labels: <String>[
      'Downloading\u2026',
      'Provisioning\u2026',
      'Signing\u2026',
      'Installing\u2026',
      'Finishing\u2026',
    ],
    determinate: <String>{'download', 'install'},
  );

  /// Installing a jailbreak (Dopamine): download the IPA, then sideload it. Same
  /// phases as a LiveContainer setup minus the certificate hand-off at the end.
  static const ProgressSchedule jailbreak = ProgressSchedule(
    steps: <String>['Download', 'Provision', 'Sign', 'Install'],
    phases: <String>['download', 'provision', 'sign', 'install'],
    labels: <String>[
      'Downloading\u2026',
      'Provisioning\u2026',
      'Signing\u2026',
      'Installing\u2026',
    ],
    determinate: <String>{'download', 'install'},
  );

  /// The step index a phase name maps to, or null for one this flow does not draw.
  int? indexOf(String? phase) {
    if (phase == null) return null;
    final int index = phases.indexOf(phase);
    return index < 0 ? null : index;
  }
}

/// The live state of a run, in the terms the stepper draws it.
///
/// This exists because several screens watch the same phases: Sideload runs them
/// directly, Library's refresh re-signs, which *is* a sideload, and LiveContainer
/// setup wraps one. Folding a frame in is the only place that knows a phase name
/// maps to a step index, or that a percentage is only meaningful in some phases —
/// so it lives here once rather than in each view model, where the copies would
/// drift the first time a phase was added.
class SideloadProgressState {
  /// Creates a state; the default is a run that has not reported yet.
  const SideloadProgressState({
    this.activeIndex = 0,
    this.stepText,
    this.percent = 0,
    this.isIndeterminate = true,
  });

  /// A run that has been started but has produced no frame yet.
  static const SideloadProgressState starting = SideloadProgressState(
    stepText: 'Starting\u2026',
  );

  /// Fallback labels for a plain sideload.
  static const List<String> phaseLabels = <String>[
    'Provisioning\u2026',
    'Signing\u2026',
    'Installing\u2026',
  ];

  /// Index of the step in progress, into the schedule's steps.
  final int activeIndex;

  /// What is happening right now, e.g. `Uploading to iPhone · 120 / 232 MB`.
  final String? stepText;

  /// Progress, 0–100. Only meaningful when [isIndeterminate] is false.
  final double percent;

  /// Whether the work is unquantified, so the bar should sweep rather than fill.
  final bool isIndeterminate;

  /// The step index a sideload phase maps to, or null for one we do not draw.
  static int? indexForPhase(String? phase) =>
      ProgressSchedule.sideload.indexOf(phase);

  /// Folds one progress frame in, returning the state after it.
  ///
  /// A frame naming a phase the schedule does not list leaves the state untouched
  /// rather than resetting the stepper to somewhere misleading.
  SideloadProgressState apply(
    SideloadProgress progress, {
    ProgressSchedule schedule = ProgressSchedule.sideload,
  }) {
    final int? index = schedule.indexOf(progress.phase);
    if (index == null) return this;

    final String? step = progress.step;
    final double? reported = progress.percent;
    final bool determinate =
        reported != null && schedule.determinate.contains(progress.phase);

    return SideloadProgressState(
      activeIndex: index,
      stepText: (step != null && step.isNotEmpty) ? step : schedule.labels[index],
      percent: determinate ? reported : percent,
      isIndeterminate: !determinate,
    );
  }

  /// The terminal state after a successful run.
  SideloadProgressState completed({
    String stepText = 'Installed',
    ProgressSchedule schedule = ProgressSchedule.sideload,
  }) =>
      SideloadProgressState(
        activeIndex: schedule.steps.length - 1,
        stepText: stepText,
        percent: 100,
        isIndeterminate: false,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SideloadProgressState &&
          other.activeIndex == activeIndex &&
          other.stepText == stepText &&
          other.percent == percent &&
          other.isIndeterminate == isIndeterminate;

  @override
  int get hashCode =>
      Object.hash(activeIndex, stepText, percent, isIndeterminate);

  @override
  String toString() =>
      'SideloadProgressState(activeIndex: $activeIndex, stepText: $stepText, '
      'percent: $percent, isIndeterminate: $isIndeterminate)';
}
