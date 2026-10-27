// Shared by Sideload and Library's refresh, because a refresh re-signs and so
// runs the same three phases. These assertions are the reason it is shared: the
// phase-to-step mapping and the "a percentage only means anything during
// install" rule would otherwise be written out twice and drift.

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine.dart';
import 'package:ipaside/viewmodels/sideload_progress_state.dart';

void main() {
  SideloadProgress frame(String? phase, {double? percent, String? step}) =>
      SideloadProgress(phase: phase, percent: percent, step: step);

  group('SideloadProgressState', () {
    test('starts before anything has been reported', () {
      const state = SideloadProgressState();
      expect(state.activeIndex, 0);
      expect(state.stepText, isNull);
      expect(state.percent, 0);
      expect(state.isIndeterminate, isTrue);
    });

    test('maps the three phases onto the three steps', () {
      expect(SideloadProgressState.indexForPhase('provision'), 0);
      expect(SideloadProgressState.indexForPhase('sign'), 1);
      expect(SideloadProgressState.indexForPhase('install'), 2);
    });

    test('advances the step and takes the engine step text', () {
      final state = const SideloadProgressState().apply(
        frame('sign', step: 'Signing the app\u2026'),
      );
      expect(state.activeIndex, 1);
      expect(state.stepText, 'Signing the app\u2026');
    });

    test('falls back to a phase label when the frame carries no step', () {
      expect(
        const SideloadProgressState().apply(frame('provision')).stepText,
        'Provisioning\u2026',
      );
    });

    test('an empty step is treated as no step', () {
      expect(
        const SideloadProgressState().apply(frame('install', step: '')).stepText,
        'Installing\u2026',
      );
    });

    test('only install with a number is determinate', () {
      // Provision is Apple round trips and sign is a zip; neither can honestly
      // report a share of the work done, so the bar sweeps instead of filling.
      expect(
        const SideloadProgressState().apply(frame('provision', percent: 50)).isIndeterminate,
        isTrue,
      );
      expect(
        const SideloadProgressState().apply(frame('sign', percent: 50)).isIndeterminate,
        isTrue,
      );

      final installing = const SideloadProgressState().apply(
        frame('install', percent: 40),
      );
      expect(installing.isIndeterminate, isFalse);
      expect(installing.percent, 40);
    });

    test('install with no number stays indeterminate', () {
      expect(
        const SideloadProgressState().apply(frame('install')).isIndeterminate,
        isTrue,
      );
    });

    test('a phase we do not draw leaves the state alone', () {
      // Returning an equal state is what lets callers skip a notify, and stops an
      // unknown phase resetting the stepper to somewhere misleading.
      final reached = const SideloadProgressState().apply(
        frame('install', percent: 80),
      );
      expect(reached.apply(frame('sandboxing', percent: 5)), reached);
      expect(reached.apply(frame(null)), reached);
    });

    test('a later install frame keeps the last percentage it knew', () {
      final at80 = const SideloadProgressState().apply(
        frame('install', percent: 80),
      );
      // A frame with a step but no number must not drop the bar back to zero.
      final stepOnly = at80.apply(frame('install', step: 'Sandboxing\u2026'));
      expect(stepOnly.percent, 80);
      expect(stepOnly.stepText, 'Sandboxing\u2026');
    });

    test('completion pins the last step at 100 and determinate', () {
      final done = const SideloadProgressState().apply(
        frame('install', percent: 80),
      ).completed();
      expect(done.activeIndex, 2);
      expect(done.percent, 100);
      expect(done.isIndeterminate, isFalse);
      expect(done.stepText, 'Installed');
    });

    test('the starting state says so before the first frame', () {
      expect(SideloadProgressState.starting.stepText, 'Starting\u2026');
      expect(SideloadProgressState.starting.isIndeterminate, isTrue);
    });
  });
}
