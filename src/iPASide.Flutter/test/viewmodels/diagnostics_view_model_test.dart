import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine_api.dart';
import 'package:ipaside/engine/engine_client.dart';
import 'package:ipaside/engine/engine_exception.dart';
import 'package:ipaside/services/installer_launcher.dart';
import 'package:ipaside/viewmodels/apple_support_view_model.dart';
import 'package:ipaside/viewmodels/diagnostics_view_model.dart';

/// A transport stand-in: replays a canned `doctor` frame and counts the runs.
class _FakeRunner with EngineCommandRunner {
  EngineResult result = const EngineResult(
    ok: true,
    data: <String, dynamic>{'overall': 'ok', 'checks': <dynamic>[]},
  );

  /// Thrown instead of returning [result] when set.
  Object? failure;

  /// Holds the call open so the test can observe the loading state.
  Completer<void>? gate;

  final List<List<String>> calls = <List<String>>[];

  @override
  Future<EngineResult> run(
    List<String> args, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  }) async {
    calls.add(args);

    final Completer<void>? parked = gate;
    if (parked != null) {
      await parked.future;
    }
    final Object? error = failure;
    if (error != null) {
      throw error;
    }
    return result;
  }
}

/// Drains the microtask queue so the load started in the constructor has
/// settled.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// One `doctor` check payload.
Map<String, dynamic> _check(String status, String name, String detail) =>
    <String, dynamic>{'status': status, 'name': name, 'detail': detail};

void main() {
  late _FakeRunner runner;
  DiagnosticsViewModel? viewModel;

  setUp(() => runner = _FakeRunner());

  tearDown(() {
    final DiagnosticsViewModel? model = viewModel;
    viewModel = null;
    if (model != null && !model.isDisposed) model.dispose();
  });

  Future<DiagnosticsViewModel> load() async {
    final DiagnosticsViewModel model = DiagnosticsViewModel(
      engine: EngineApi(runner),
    );
    viewModel = model;
    await _settle();
    return model;
  }

  group('DiagnosticsViewModel loading', () {
    test('runs doctor once on creation', () async {
      final DiagnosticsViewModel model = await load();

      expect(runner.calls, <List<String>>[
        <String>['doctor'],
      ]);
      expect(model.isLoading, isFalse);
      expect(model.hasReport, isTrue);
      expect(model.hasError, isFalse);
    });

    test('reports the loading state until the report arrives', () async {
      runner.gate = Completer<void>();
      final DiagnosticsViewModel model = DiagnosticsViewModel(
        engine: EngineApi(runner),
      );
      viewModel = model;
      await _settle();

      expect(model.isLoading, isTrue);
      expect(model.hasReport, isFalse);
      expect(model.checks, isEmpty);

      runner.gate!.complete();
      await _settle();

      expect(model.isLoading, isFalse);
      expect(model.hasReport, isTrue);
    });
  });

  group('DiagnosticsViewModel overall status', () {
    test('an ok report banners as OK', () async {
      final DiagnosticsViewModel model = await load();

      expect(model.overallLabel, 'Overall status: OK');
      expect(model.overallStatus, DiagnosticsStatus.ok);
    });

    test('a warn report banners as WARN', () async {
      runner.result = const EngineResult(
        ok: true,
        data: <String, dynamic>{'overall': 'warn', 'checks': <dynamic>[]},
      );

      final DiagnosticsViewModel model = await load();

      expect(model.overallLabel, 'Overall status: WARN');
      expect(model.overallStatus, DiagnosticsStatus.warn);
    });

    test('a missing overall falls back to WARN', () async {
      runner.result = const EngineResult(
        ok: true,
        data: <String, dynamic>{'checks': <dynamic>[]},
      );

      final DiagnosticsViewModel model = await load();

      expect(model.overallLabel, 'Overall status: WARN');
      expect(model.overallStatus, DiagnosticsStatus.warn);
      expect(model.hasReport, isTrue);
    });

    test('an empty overall falls back to WARN', () async {
      runner.result = const EngineResult(
        ok: true,
        data: <String, dynamic>{'overall': '', 'checks': <dynamic>[]},
      );

      final DiagnosticsViewModel model = await load();

      expect(model.overallLabel, 'Overall status: WARN');
      expect(model.overallStatus, DiagnosticsStatus.warn);
    });

    test('an unrecognised overall keeps its label but warns', () async {
      runner.result = const EngineResult(
        ok: true,
        data: <String, dynamic>{'overall': 'degraded', 'checks': <dynamic>[]},
      );

      final DiagnosticsViewModel model = await load();

      expect(model.overallLabel, 'Overall status: DEGRADED');
      expect(model.overallStatus, DiagnosticsStatus.warn);
    });

    test('a failing run still renders its report', () async {
      // The engine exits non-zero on a fail overall, so the frame arrives with
      // ok: false while still carrying the whole report.
      runner.result = EngineResult(
        ok: false,
        error: 'engine error',
        data: <String, dynamic>{
          'overall': 'fail',
          'checks': <dynamic>[
            _check('fail', 'iTunes', 'Apple Mobile Device Service is not running'),
          ],
        },
      );

      final DiagnosticsViewModel model = await load();

      expect(model.hasError, isFalse);
      expect(model.error, isNull);
      expect(model.hasReport, isTrue);
      expect(model.overallLabel, 'Overall status: FAIL');
      expect(model.overallStatus, DiagnosticsStatus.fail);
      expect(model.checks, <DiagnosticsCheckRow>[
        const DiagnosticsCheckRow(
          status: DiagnosticsStatus.fail,
          name: 'iTunes',
          detail: 'Apple Mobile Device Service is not running',
        ),
      ]);
    });
  });

  group('DiagnosticsViewModel check rows', () {
    test('maps every status to its badge', () async {
      runner.result = EngineResult(
        ok: true,
        data: <String, dynamic>{
          'overall': 'warn',
          'checks': <dynamic>[
            _check('ok', 'Python', '3.12.2'),
            _check('warn', 'Anisette', 'not provisioned yet'),
            _check('fail', 'Device', 'no device connected'),
            _check('mystery', 'Future check', 'from a newer engine'),
          ],
        },
      );

      final DiagnosticsViewModel model = await load();

      expect(
        model.checks.map((DiagnosticsCheckRow row) => row.status).toList(),
        <DiagnosticsStatus>[
          DiagnosticsStatus.ok,
          DiagnosticsStatus.warn,
          DiagnosticsStatus.fail,
          DiagnosticsStatus.unknown,
        ],
      );
      expect(model.checks.first.name, 'Python');
      expect(model.checks.first.detail, '3.12.2');
    });

    test('a check with no name or detail renders as empty text', () async {
      runner.result = const EngineResult(
        ok: true,
        data: <String, dynamic>{
          'overall': 'ok',
          'checks': <dynamic>[
            <String, dynamic>{'status': 'ok'},
          ],
        },
      );

      final DiagnosticsViewModel model = await load();

      expect(model.checks.single.name, isEmpty);
      expect(model.checks.single.detail, isEmpty);
    });

    test('a report without checks renders no rows', () async {
      runner.result = const EngineResult(
        ok: true,
        data: <String, dynamic>{'overall': 'ok'},
      );

      final DiagnosticsViewModel model = await load();

      expect(model.hasReport, isTrue);
      expect(model.checks, isEmpty);
    });
  });

  group('DiagnosticsViewModel failures', () {
    test('an unusable failure is prefixed', () async {
      runner.result = const EngineResult(
        ok: false,
        data: <String, dynamic>{'status': 'error', 'error': 'engine crashed'},
        error: 'engine crashed',
      );

      final DiagnosticsViewModel model = await load();

      expect(model.error, 'Could not run diagnostics: engine crashed');
      expect(model.hasError, isTrue);
      expect(model.hasReport, isFalse);
      expect(model.checks, isEmpty);
      expect(model.isLoading, isFalse);
    });

    test('a shutdown leaves no error behind', () async {
      runner.failure = EngineShutdownException();

      final DiagnosticsViewModel model = await load();

      expect(model.hasError, isFalse);
      expect(model.hasReport, isFalse);
      expect(model.isLoading, isFalse);
    });
  });

  group('DiagnosticsViewModel re-run', () {
    test('runs the whole pass again', () async {
      final DiagnosticsViewModel model = await load();

      runner.result = const EngineResult(
        ok: true,
        data: <String, dynamic>{'overall': 'warn', 'checks': <dynamic>[]},
      );
      await model.reRun();

      expect(runner.calls, hasLength(2));
      expect(model.overallLabel, 'Overall status: WARN');
    });

    test('clears the previous failure', () async {
      runner.result = const EngineResult(ok: false, error: 'engine crashed');
      final DiagnosticsViewModel model = await load();
      expect(model.hasError, isTrue);

      runner.result = const EngineResult(
        ok: true,
        data: <String, dynamic>{'overall': 'ok', 'checks': <dynamic>[]},
      );
      await model.reRun();

      expect(model.hasError, isFalse);
      expect(model.hasReport, isTrue);
      expect(model.overallStatus, DiagnosticsStatus.ok);
    });

    test('is ignored while a pass is already running', () async {
      runner.gate = Completer<void>();
      final DiagnosticsViewModel model = DiagnosticsViewModel(
        engine: EngineApi(runner),
      );
      viewModel = model;
      await _settle();

      await model.reRun();

      expect(runner.calls, hasLength(1));

      runner.gate!.complete();
      await _settle();
    });
  });

  group('DiagnosticsViewModel and Apple support', () {
    /// A model whose Apple-service verdict a test can move, without a transport.
    AppleSupportViewModel appleSupport(_FakeRunner transport) {
      final AppleSupportViewModel model = AppleSupportViewModel(
        engine: EngineApi(transport),
        launcher: _NoLauncher(),
      );
      addTearDown(model.dispose);
      return model;
    }

    test('a fixed service re-runs the report, so the row cannot go stale',
        () async {
      // The Apple row is this screen's own banner in list form. Leaving it saying
      // "not installed" under a banner that has just installed it would make the
      // one screen whose job is telling the truth the one screen that is wrong.
      final _FakeRunner appleRunner = _FakeRunner()
        ..result = const EngineResult(
          ok: true,
          data: <String, dynamic>{'state': 'missing'},
        );
      final AppleSupportViewModel apple = appleSupport(appleRunner);
      await apple.refresh();

      final DiagnosticsViewModel model = DiagnosticsViewModel(
        engine: EngineApi(runner),
        appleSupport: apple,
      );
      viewModel = model;
      await _settle();
      expect(runner.calls, hasLength(1));

      appleRunner.result = const EngineResult(
        ok: true,
        data: <String, dynamic>{'state': 'running'},
      );
      await apple.refresh();
      await _settle();

      expect(runner.calls, hasLength(2), reason: 'the verdict changed');
    });

    test('an unchanged verdict does not re-run anything', () async {
      final _FakeRunner appleRunner = _FakeRunner()
        ..result = const EngineResult(
          ok: true,
          data: <String, dynamic>{'state': 'missing'},
        );
      final AppleSupportViewModel apple = appleSupport(appleRunner);
      await apple.refresh();

      final DiagnosticsViewModel model = DiagnosticsViewModel(
        engine: EngineApi(runner),
        appleSupport: apple,
      );
      viewModel = model;
      await _settle();

      // A download notifies on every chunk; running the whole doctor pass per
      // chunk would be a very expensive progress bar.
      await apple.refresh();
      await _settle();

      expect(runner.calls, hasLength(1));
    });

    test('disposing stops listening to it', () async {
      final _FakeRunner appleRunner = _FakeRunner()
        ..result = const EngineResult(
          ok: true,
          data: <String, dynamic>{'state': 'missing'},
        );
      final AppleSupportViewModel apple = appleSupport(appleRunner);
      await apple.refresh();

      final DiagnosticsViewModel model = DiagnosticsViewModel(
        engine: EngineApi(runner),
        appleSupport: apple,
      );
      viewModel = model;
      await _settle();
      model.dispose();

      appleRunner.result = const EngineResult(
        ok: true,
        data: <String, dynamic>{'state': 'running'},
      );
      await apple.refresh();
      await _settle();

      expect(runner.calls, hasLength(1));
    });
  });
}

/// Never asked to launch anything: these tests only move the service verdict.
class _NoLauncher implements InstallerLauncher {
  @override
  Future<bool> launch(String path) async =>
      fail('diagnostics must not run an installer');
}
