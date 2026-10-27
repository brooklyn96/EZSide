import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine_api.dart';
import 'package:ipaside/engine/engine_client.dart';
import 'package:ipaside/engine/engine_exception.dart';
import 'package:ipaside/services/installer_launcher.dart';
import 'package:ipaside/viewmodels/apple_support_view_model.dart';

/// A transport stand-in: answers each `apple-support` variant from memory, so no
/// test touches the network, PowerShell, or a 198 MB download.
class _FakeRunner with EngineCommandRunner {
  /// What `apple-support` reports, newest first when a test queues several.
  final List<Map<String, dynamic>> statuses = <Map<String, dynamic>>[
    _status('missing'),
  ];

  /// What `apple-support --download` reports.
  Map<String, dynamic> download = <String, dynamic>{
    'path': r'C:\data\downloads\iTunes64Setup.exe',
    'bytes': 208064480,
    'signer': 'CN=Apple Inc., O=Apple Inc., C=US',
    'signature_status': 'Valid',
  };

  /// What `apple-support --start-service` reports.
  Map<String, dynamic> serviceStart = <String, dynamic>{
    'started': true,
    'reason': 'started',
    'detail': 'running now',
    'status': <String, dynamic>{'state': 'running'},
  };

  /// Progress lines replayed during a download.
  List<String> progress = <String>[];

  /// Thrown instead of answering, keyed by the action being asked for.
  Object? statusFailure;
  Object? downloadFailure;
  Object? startFailure;

  /// Holds a call open so a test can observe the in-flight state.
  Completer<void>? gate;

  final List<List<String>> calls = <List<String>>[];

  static Map<String, dynamic> _status(String state) => <String, dynamic>{
        'state': state,
        'service_name': 'Apple Mobile Device Service',
        'service_state': state == 'missing' ? null : state.toUpperCase(),
        'itunes_installed': false,
        'detail': 'Apple Mobile Device Service detail sentence.',
      };

  /// Queues the states successive probes will report.
  void willReport(List<String> states) {
    statuses
      ..clear()
      ..addAll(states.map(_status));
  }

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

    if (args.contains('--download')) {
      for (final String line in progress) {
        onProgress?.call(line);
      }
      if (downloadFailure != null) throw downloadFailure!;
      return EngineResult(ok: true, data: download);
    }
    if (args.contains('--start-service')) {
      if (startFailure != null) throw startFailure!;
      return EngineResult(ok: true, data: serviceStart);
    }
    if (statusFailure != null) throw statusFailure!;
    final Map<String, dynamic> status =
        statuses.length > 1 ? statuses.removeAt(0) : statuses.first;
    return EngineResult(ok: true, data: status);
  }
}

/// An [InstallerLauncher] that records what it was handed instead of running it.
class _FakeLauncher implements InstallerLauncher {
  final List<String> launched = <String>[];
  bool succeeds = true;

  @override
  Future<bool> launch(String path) async {
    launched.add(path);
    return succeeds;
  }
}

/// Drains the microtask queue so an awaited command has settled.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeRunner runner;
  late _FakeLauncher launcher;
  AppleSupportViewModel? viewModel;

  setUp(() {
    runner = _FakeRunner();
    launcher = _FakeLauncher();
  });

  tearDown(() {
    final AppleSupportViewModel? model = viewModel;
    viewModel = null;
    if (model != null && !model.isDisposed) model.dispose();
  });

  AppleSupportViewModel build() {
    final AppleSupportViewModel model = AppleSupportViewModel(
      engine: EngineApi(runner),
      launcher: launcher,
    );
    viewModel = model;
    return model;
  }

  Future<AppleSupportViewModel> checked() async {
    final AppleSupportViewModel model = build();
    await model.refresh();
    return model;
  }

  group('AppleSupportViewModel states', () {
    test('says nothing before the first answer arrives', () {
      final AppleSupportViewModel model = build();

      expect(model.status, isNull);
      expect(model.hasNotice, isFalse, reason: 'nothing is known yet');
      expect(model.blocksDevices, isFalse);
      expect(model.canDownload, isFalse);
      expect(model.canStartService, isFalse);
    });

    test('a running service raises no notice at all', () async {
      runner.willReport(<String>['running']);
      final AppleSupportViewModel model = await checked();

      expect(runner.calls, <List<String>>[
        <String>['apple-support'],
      ]);
      expect(model.isReady, isTrue);
      expect(model.hasNotice, isFalse);
      expect(model.blocksDevices, isFalse);
      expect(model.usbBlockedReason, isNull);
      expect(model.deviceBlockedMessage, isNull);
    });

    test('a missing service offers the download, not a service start', () async {
      runner.willReport(<String>['missing']);
      final AppleSupportViewModel model = await checked();

      expect(model.hasNotice, isTrue);
      expect(model.isMissing, isTrue);
      expect(model.blocksDevices, isTrue);
      expect(model.canDownload, isTrue);
      expect(model.canStartService, isFalse);
      expect(model.message, contains('200 MB'));
      expect(model.usbBlockedReason, contains('installed'));
      expect(model.deviceBlockedMessage, contains('cannot reach an iPhone'));
    });

    test('a stopped service offers the start, not a 200 MB download', () async {
      runner.willReport(<String>['stopped']);
      final AppleSupportViewModel model = await checked();

      expect(model.hasNotice, isTrue);
      expect(model.isStopped, isTrue);
      expect(model.blocksDevices, isTrue);
      expect(model.canStartService, isTrue);
      expect(model.canDownload, isFalse);
      expect(model.title, contains('running'));
      expect(model.usbBlockedReason, contains('running'));
    });

    test('a non-Windows host is not nagged about a service it cannot have', () async {
      runner.willReport(<String>['unsupported']);
      final AppleSupportViewModel model = await checked();

      expect(model.hasNotice, isFalse);
      expect(model.blocksDevices, isFalse);
      expect(model.canDownload, isFalse);
      expect(model.canStartService, isFalse);
    });

    test('the engine sentence is carried, not paraphrased', () async {
      runner.willReport(<String>['stopped']);
      final AppleSupportViewModel model = await checked();

      expect(model.message, 'Apple Mobile Device Service detail sentence.');
    });

    test('a probe in flight is busy and offers no buttons', () async {
      runner.gate = Completer<void>();
      final AppleSupportViewModel model = build();
      final Future<void> checking = model.refresh();
      await _settle();

      expect(model.isChecking, isTrue);
      expect(model.isBusy, isTrue);
      expect(model.canRecheck, isFalse);

      runner.gate!.complete();
      await checking;

      expect(model.isChecking, isFalse);
      expect(model.canRecheck, isTrue);
    });

    test('a failed probe is reported without claiming a verdict', () async {
      runner.statusFailure = EngineException('engine exited unexpectedly');
      final AppleSupportViewModel model = await checked();

      expect(model.problem, 'engine exited unexpectedly');
      expect(model.status, isNull);
      expect(
        model.hasNotice,
        isFalse,
        reason: 'not knowing is not the same as knowing it is broken',
      );
    });

    test('a shutdown during the probe leaves nothing behind', () async {
      runner.statusFailure = EngineShutdownException();
      final AppleSupportViewModel model = await checked();

      expect(model.problem, isNull);
      expect(model.isChecking, isFalse);
    });

    test('overlapping probes are collapsed into the one in flight', () async {
      runner.gate = Completer<void>();
      final AppleSupportViewModel model = build();
      final Future<void> first = model.refresh();
      await _settle();

      await model.refresh();
      expect(runner.calls, hasLength(1));

      runner.gate!.complete();
      await first;
    });
  });

  group('AppleSupportViewModel install', () {
    test('the installer runs only after the engine verified it', () async {
      runner.willReport(<String>['missing', 'running']);
      final AppleSupportViewModel model = await checked();

      await model.installItunes();

      expect(
        runner.calls,
        <List<String>>[
          <String>['apple-support'],
          <String>['apple-support', '--download'],
          <String>['apple-support'],
        ],
        reason: 'download, then a re-check so the UI stops lying',
      );
      expect(launcher.launched, <String>[r'C:\data\downloads\iTunes64Setup.exe']);
      expect(model.installerRunning, isFalse, reason: 'the service came up');
      expect(model.hasNotice, isFalse);
      expect(model.problem, isNull);
    });

    test('a refused signature launches nothing and says why', () async {
      // The whole point of the split: the engine deletes what it cannot verify and
      // raises, so there is no path here that can run an unverified installer.
      runner.willReport(<String>['missing']);
      final AppleSupportViewModel model = await checked();
      runner.downloadFailure = EngineException(
        'The downloaded iTunes installer is signed by \'CN=Contoso Ltd\', '
        'not by Apple Inc., so it was not installed.',
      );

      await model.installItunes();

      expect(launcher.launched, isEmpty, reason: 'nothing verified, nothing run');
      expect(model.problem, contains('not by Apple Inc.'));
      expect(model.installerRunning, isFalse);
      expect(model.isDownloading, isFalse);
      expect(model.canDownload, isTrue, reason: 'the user can try again');
    });

    test('no internet reads as the engine sentence, not a stack', () async {
      runner.willReport(<String>['missing']);
      final AppleSupportViewModel model = await checked();
      runner.downloadFailure = EngineException(
        'Could not reach Apple to download iTunes. Check your internet '
        'connection and try again.',
      );

      await model.installItunes();

      expect(launcher.launched, isEmpty);
      expect(model.problem, startsWith('Could not reach Apple'));
    });

    test('a download that fails midway leaves the offer standing', () async {
      runner.willReport(<String>['missing']);
      final AppleSupportViewModel model = await checked();
      runner.downloadFailure = EngineException(
        'The iTunes download failed after 96.0 MB and was discarded.',
      );

      await model.installItunes();

      expect(model.problem, contains('was discarded'));
      expect(model.hasNotice, isTrue);
      expect(model.canDownload, isTrue);
    });

    test('a verified installer Windows will not start is reported with its path',
        () async {
      runner.willReport(<String>['missing']);
      final AppleSupportViewModel model = await checked();
      launcher.succeeds = false;

      await model.installItunes();

      expect(launcher.launched, hasLength(1));
      expect(model.installerRunning, isFalse);
      expect(model.problem, contains(r'C:\data\downloads\iTunes64Setup.exe'));
    });

    test('a payload with no path is refused rather than launched blind', () async {
      runner.willReport(<String>['missing']);
      final AppleSupportViewModel model = await checked();
      runner.download = <String, dynamic>{'bytes': 1};

      await model.installItunes();

      expect(launcher.launched, isEmpty);
      expect(model.problem, contains('where it saved'));
    });

    test('progress is surfaced as a percentage and a live step', () async {
      runner.willReport(<String>['missing']);
      runner.progress = <String>[
        '{"event":"progress","phase":"download","percent":0,'
            '"step":"Contacting Apple"}',
        '{"event":"progress","phase":"download","percent":47,'
            '"step":"Downloading iTunes \\u00b7 93.0 MB of 198.4 MB"}',
      ];
      final AppleSupportViewModel model = await checked();
      final List<double> seen = <double>[];
      model.addListener(() {
        if (model.isDownloading) seen.add(model.percent);
      });

      await model.installItunes();

      expect(seen, contains(47.0));
      expect(model.isDownloading, isFalse);
      expect(model.step, isNull, reason: 'the step retires with the download');
    });

    test('a download in flight blocks a second one', () async {
      runner.willReport(<String>['missing']);
      final AppleSupportViewModel model = await checked();
      runner.gate = Completer<void>();

      final Future<void> downloading = model.installItunes();
      await _settle();
      expect(model.isDownloading, isTrue);
      expect(model.canDownload, isFalse);

      await model.installItunes();
      await model.startService();
      expect(
        runner.calls.where((List<String> args) => args.length > 1).length,
        1,
        reason: 'one action at a time',
      );

      runner.gate!.complete();
      await downloading;
    });

    test('the offer retires while the installer is running', () async {
      // The service cannot come up until the user finishes installing, so the
      // banner has to stop offering a download it already made.
      runner.willReport(<String>['missing', 'missing']);
      final AppleSupportViewModel model = await checked();

      await model.installItunes();

      expect(model.installerRunning, isTrue);
      expect(model.canDownload, isFalse);
      expect(model.canRecheck, isTrue);
      expect(model.message, contains('check again'));
    });

    test('a re-check that finds the service up clears the installer state', () async {
      runner.willReport(<String>['missing', 'missing', 'running']);
      final AppleSupportViewModel model = await checked();
      await model.installItunes();
      expect(model.installerRunning, isTrue);

      await model.refresh();

      expect(model.installerRunning, isFalse);
      expect(model.hasNotice, isFalse);
    });
  });

  group('AppleSupportViewModel start service', () {
    test('a successful start adopts the status the engine read back', () async {
      runner.willReport(<String>['stopped']);
      final AppleSupportViewModel model = await checked();

      await model.startService();

      expect(runner.calls.last, <String>['apple-support', '--start-service']);
      expect(model.isReady, isTrue);
      expect(model.hasNotice, isFalse);
      expect(model.problem, isNull);
      expect(
        runner.calls.where((List<String> args) => args.length == 1).length,
        1,
        reason: 'the returned status saves a second round trip',
      );
    });

    test('a declined elevation changes nothing and keeps the offer', () async {
      runner.willReport(<String>['stopped']);
      final AppleSupportViewModel model = await checked();
      runner.serviceStart = <String, dynamic>{
        'started': false,
        'reason': 'elevation_declined',
        'detail': 'Starting it needs administrator rights, and the request was '
            'declined. Nothing was changed.',
        'status': <String, dynamic>{'state': 'stopped'},
      };

      await model.startService();

      expect(model.isStopped, isTrue);
      expect(model.hasNotice, isTrue);
      expect(model.canStartService, isTrue, reason: 'they can change their mind');
      expect(model.problem, contains('declined'));
    });

    test('a start that Windows refused is reported, not retried', () async {
      runner.willReport(<String>['stopped']);
      final AppleSupportViewModel model = await checked();
      runner.serviceStart = <String, dynamic>{
        'started': false,
        'reason': 'failed',
        'detail': 'Windows would not start it (Access is denied).',
        'status': <String, dynamic>{'state': 'stopped'},
      };

      await model.startService();

      expect(model.problem, contains('Access is denied'));
      expect(runner.calls.where((List<String> a) => a.length > 1), hasLength(1));
    });

    test('a start payload without a status is re-probed, never assumed', () async {
      runner.willReport(<String>['stopped', 'running']);
      final AppleSupportViewModel model = await checked();
      runner.serviceStart = <String, dynamic>{
        'started': true,
        'reason': 'started',
        'detail': 'running now',
      };

      await model.startService();

      expect(runner.calls.last, <String>['apple-support']);
      expect(model.isReady, isTrue);
    });

    test('an engine failure during the start is shown cleaned', () async {
      runner.willReport(<String>['stopped']);
      final AppleSupportViewModel model = await checked();
      runner.startFailure = EngineException(
        'There is no Apple Mobile Device Service to start on this machine.',
      );

      await model.startService();

      expect(model.problem, startsWith('There is no Apple'));
      expect(model.isStartingService, isFalse);
    });

    test('a shutdown during the start leaves no message behind', () async {
      runner.willReport(<String>['stopped']);
      final AppleSupportViewModel model = await checked();
      runner.startFailure = EngineShutdownException();

      await model.startService();

      expect(model.problem, isNull);
      expect(model.isStartingService, isFalse);
    });

    test('a completion after disposal notifies nobody', () async {
      runner.willReport(<String>['stopped']);
      final AppleSupportViewModel model = await checked();
      runner.gate = Completer<void>();

      final Future<void> starting = model.startService();
      await _settle();
      model.dispose();
      runner.gate!.complete();

      await expectLater(starting, completes);
    });
  });
}
