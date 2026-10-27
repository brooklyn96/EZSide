import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/main.dart';

void main() {
  group('runShutdownSequence', () {
    /// Records the order the steps ran in; each step also yields, so a step
    /// that was not awaited would show up out of order.
    Future<void> Function() step(List<String> log, String name) => () async {
          await Future<void>.delayed(Duration.zero);
          log.add(name);
        };

    test('hides the window before spending any time on the engine', () async {
      final List<String> log = <String>[];

      await runShutdownSequence(
        hideWindow: step(log, 'hide'),
        disposeEngine: step(log, 'engine'),
        destroyWindow: step(log, 'destroy'),
      );

      expect(log, <String>['hide', 'engine', 'destroy']);
    });

    test('still destroys the window when the engine teardown fails', () async {
      final List<String> log = <String>[];

      await expectLater(
        runShutdownSequence(
          hideWindow: step(log, 'hide'),
          disposeEngine: () async => throw StateError('engine wedged'),
          destroyWindow: step(log, 'destroy'),
        ),
        throwsStateError,
      );

      // A hidden process that never destroyed its window would be invisible and
      // unclosable.
      expect(log, <String>['hide', 'destroy']);
    });

    test('still destroys the window when hiding it fails', () async {
      final List<String> log = <String>[];

      await expectLater(
        runShutdownSequence(
          hideWindow: () async => throw StateError('no window'),
          disposeEngine: step(log, 'engine'),
          destroyWindow: step(log, 'destroy'),
        ),
        throwsStateError,
      );

      expect(log, <String>['destroy']);
    });
  });
}
