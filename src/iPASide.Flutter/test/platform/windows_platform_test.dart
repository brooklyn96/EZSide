import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/platform/background_refresh_scheduler.dart';
import 'package:ipaside/platform/child_process_reaper.dart';
import 'package:ipaside/platform/reduced_motion.dart';
import 'package:ipaside/platform/single_instance.dart';
import 'package:ipaside/platform/windows_child_process_reaper.dart';
import 'package:win32/win32.dart';

/// A mutex name no other process on the machine can be holding.
String _uniqueMutexName(String label) =>
    'iPASide.Test.$label.$pid.${DateTime.now().microsecondsSinceEpoch}';

/// Whether [process] belongs to any job object.
/// Whether this machine has the auto-refresh task registered right now.
///
/// Used to skip a test that would otherwise delete it. Synchronous because
/// `skip:` is evaluated while the test is being declared.
bool _autoRefreshTaskExists() {
  try {
    return Process.runSync(
          'schtasks',
          <String>['/Query', '/TN', autoRefreshTaskName],
        ).exitCode ==
        0;
  } on ProcessException {
    return false;
  }
}

bool _isInAnyJob(HANDLE process) {
  final Pointer<Int32> result = calloc<Int32>();
  try {
    final bool queried = IsProcessInJob(process, null, result).value;
    return queried && result.value != FALSE;
  } finally {
    calloc.free(result);
  }
}

void main() {
  group('Non-Windows fallbacks', () {
    test('the null guard always reports first instance', () {
      const NullSingleInstanceGuard guard = NullSingleInstanceGuard();

      expect(guard.tryAcquire(), isTrue);
      expect(guard.tryAcquire(), isTrue);
      expect(guard.dispose, returnsNormally);
    });

    test('the default reduced-motion provider leaves motion enabled', () {
      expect(const DefaultReducedMotionProvider().isReducedMotion(), isFalse);
    });

    test('the no-op reaper accepts any pid', () {
      expect(() => const NoopChildProcessReaper().adopt(1), returnsNormally);
    });

    test('the unsupported scheduler reports no integration', () async {
      const UnsupportedBackgroundRefreshScheduler scheduler =
          UnsupportedBackgroundRefreshScheduler();

      expect(scheduler.isSupported, isFalse);
      expect(await scheduler.isEnabled(), isFalse);
      expect(scheduler.setEnabled(true), throwsUnsupportedError);
    });

    test('the running marker is a no-op that still disposes cleanly', () {
      // On Windows this holds a real mutex; either way disposal must be safe.
      final RunningAppMarker marker = RunningAppMarker.hold(
        _uniqueMutexName('noop'),
      );

      expect(marker.dispose, returnsNormally);
    });
  });

  group(
    'Windows platform services',
    skip: Platform.isWindows ? null : 'Win32 integration; Windows only',
    () {
      test('the OS factories pick the Windows implementations', () {
        expect(createSingleInstanceGuard(), isA<WindowsSingleInstanceGuard>());
        expect(
          createReducedMotionProvider(),
          isA<WindowsReducedMotionProvider>(),
        );
        expect(createChildProcessReaper(), isA<WindowsChildProcessReaper>());
        expect(
          createBackgroundRefreshScheduler(),
          isA<WindowsBackgroundRefreshScheduler>(),
        );
      });

      test('reading the client-area animation setting succeeds', () {
        expect(
          const WindowsReducedMotionProvider().isReducedMotion(),
          isA<bool>(),
        );
      });

      test('the first guard acquires and a second one is denied', () {
        final String name = _uniqueMutexName('single');
        final WindowsSingleInstanceGuard first = WindowsSingleInstanceGuard(
          name,
        );
        final WindowsSingleInstanceGuard second = WindowsSingleInstanceGuard(
          name,
        );
        addTearDown(first.dispose);
        addTearDown(second.dispose);

        expect(first.tryAcquire(), isTrue);
        expect(second.tryAcquire(), isFalse);
      });

      test('the outcome is cached, so tryAcquire is idempotent', () {
        final String name = _uniqueMutexName('idempotent');
        final WindowsSingleInstanceGuard first = WindowsSingleInstanceGuard(
          name,
        );
        final WindowsSingleInstanceGuard second = WindowsSingleInstanceGuard(
          name,
        );
        addTearDown(first.dispose);
        addTearDown(second.dispose);

        expect(first.tryAcquire(), isTrue);
        expect(first.tryAcquire(), isTrue);
        expect(second.tryAcquire(), isFalse);
        expect(second.tryAcquire(), isFalse);
      });

      test('disposing releases the name for the next instance', () {
        final String name = _uniqueMutexName('release');

        final WindowsSingleInstanceGuard first = WindowsSingleInstanceGuard(
          name,
        );
        expect(first.tryAcquire(), isTrue);
        first.dispose();
        expect(first.dispose, returnsNormally); // idempotent

        final WindowsSingleInstanceGuard second = WindowsSingleInstanceGuard(
          name,
        );
        addTearDown(second.dispose);
        expect(second.tryAcquire(), isTrue);
      });

      test('the running marker creates a real named object', () {
        final String name = _uniqueMutexName('marker');
        final RunningAppMarker marker = RunningAppMarker.hold(name);
        addTearDown(marker.dispose);

        // A guard over the same name now sees an existing mutex, which is
        // exactly what the installer's AppMutex check observes.
        final WindowsSingleInstanceGuard guard = WindowsSingleInstanceGuard(
          name,
        );
        addTearDown(guard.dispose);

        expect(guard.tryAcquire(), isFalse);
      });

      test('the marker can be held twice in one process', () {
        final String name = _uniqueMutexName('double');
        final RunningAppMarker gui = RunningAppMarker.hold(name);
        final RunningAppMarker headless = RunningAppMarker.hold(name);

        expect(gui.dispose, returnsNormally);
        expect(headless.dispose, returnsNormally);
      });

      test('adopting a pid that does not exist is ignored', () {
        expect(
          () => WindowsChildProcessReaper().adopt(0x7FFFFFF0),
          returnsNormally,
        );
      });

      test(
        'adoption assigns the child to a job object without killing it',
        () async {
          final Process child = await Process.start('ping', <String>[
            '-n',
            '30',
            '127.0.0.1',
          ]);
          final HANDLE handle = OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION,
            false,
            child.pid,
          ).value;
          expect(handle.isValid, isTrue);

          try {
            expect(_isInAnyJob(handle), isFalse, reason: 'not yet adopted');

            createChildProcessReaper().adopt(child.pid);

            expect(_isInAnyJob(handle), isTrue);
            expect(
              child.kill(),
              isTrue,
              reason: 'adoption must not kill the child',
            );
          } finally {
            CloseHandle(handle);
            await child.exitCode;
          }
        },
        // When the runner is itself inside a job, children inherit one and the
        // assertions above cannot tell adoption apart from inheritance.
        skip: Platform.isWindows && _isInAnyJob(GetCurrentProcess())
            ? 'the test host is already inside a job object'
            : null,
      );

      test('querying the auto-refresh task reaches schtasks', () async {
        expect(
          await const WindowsBackgroundRefreshScheduler().isEnabled(),
          isA<bool>(),
        );
      });

      test('the Windows scheduler reports itself supported', () {
        expect(const WindowsBackgroundRefreshScheduler().isSupported, isTrue);
      });

      test('turning auto-refresh off when it is already off is not an error',
          () async {
        const WindowsBackgroundRefreshScheduler scheduler =
            WindowsBackgroundRefreshScheduler();

        // `schtasks /Delete` answers "cannot find the file specified" for a task
        // that is not there, which surfaced in Settings as a failure for having
        // done nothing — and would greet anyone whose task had been removed from
        // Task Scheduler by hand.
        await expectLater(scheduler.setEnabled(false), completes);
        expect(await scheduler.isEnabled(), isFalse);
      },
          // Never run against a machine that has the task: it would delete the
          // real one and quietly turn off a feature the user had switched on.
          skip: _autoRefreshTaskExists()
              ? 'this machine has the task registered; refusing to delete it'
              : null);

      group('the auto-refresh task definition', () {
        // Each of these is a way the feature silently does nothing, and each is
        // the Windows default that registering from a command line would leave in
        // place. They are the entire reason the task is registered from XML.
        final String xml =
            WindowsBackgroundRefreshScheduler.taskDefinitionXml();

        test('catches up a run missed while the machine was off', () {
          // Signatures last 7 days; a laptop closed at noon must not just skip.
          expect(xml, contains('<StartWhenAvailable>true</StartWhenAvailable>'));
        });

        test('runs on battery, and is not killed by unplugging mid-run', () {
          expect(
            xml,
            contains(
              '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>',
            ),
          );
          expect(
            xml,
            contains('<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'),
          );
        });

        test('does not overlap a slow run with the next day', () {
          expect(
            xml,
            contains('<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'),
          );
        });

        test('runs this executable headlessly, daily at noon', () {
          expect(xml, contains('<Arguments>--auto-refresh</Arguments>'));
          expect(xml, contains(Platform.resolvedExecutable));
          expect(xml, contains('<StartBoundary>2026-01-01T12:00:00</StartBoundary>'));
          expect(xml, contains('<DaysInterval>1</DaysInterval>'));
        });

        test('is well-formed XML', () {
          // A malformed definition fails inside schtasks with a message nobody
          // could act on, so the shape is worth asserting here.
          expect(xml.trimLeft(), startsWith('<?xml'));
          expect(
            RegExp('<').allMatches(xml).length,
            RegExp('>').allMatches(xml).length,
          );
        });
      });
    },
  );
}
