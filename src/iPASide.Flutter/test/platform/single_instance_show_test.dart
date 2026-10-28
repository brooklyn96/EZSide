import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/platform/single_instance.dart';

void main() {
  group('singleInstanceIsHeld', () {
    test(
      'follows the guard: held while acquired, free once disposed',
      () {
        final String name = 'EZSide.Test.Held.$pid.'
            '${DateTime.now().microsecondsSinceEpoch}';
        expect(singleInstanceIsHeld(name), isFalse);

        final WindowsSingleInstanceGuard guard =
            WindowsSingleInstanceGuard(name);
        expect(guard.tryAcquire(), isTrue);
        expect(singleInstanceIsHeld(name), isTrue);

        guard.dispose();
        expect(singleInstanceIsHeld(name), isFalse);
      },
      skip: !Platform.isWindows,
    );
  });

  group('showRunningInstance', () {
    test('reports false when no instance has a tray window', () {
      final Stopwatch clock = Stopwatch()..start();

      final bool posted = showRunningInstance(
        windowClass: 'EZSide.Test.NoSuchWindow.$pid',
        attempts: 2,
        interval: const Duration(milliseconds: 10),
      );

      expect(posted, isFalse);
      // It looks again, but gives up rather than holding the launch open.
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('the window class and message match the runner', () {
      // flutter test runs from the package root.
      final String runner =
          File('windows/runner/tray_icon.cpp').readAsStringSync();

      expect(
        runner,
        contains('kHostClassName[] = L"$trayHostWindowClass";'),
      );
      expect(runner, contains('kShowAppMessage = WM_APP + 2;'));
    });
  });
}
