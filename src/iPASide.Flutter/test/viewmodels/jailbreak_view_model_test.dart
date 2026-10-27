import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine.dart';
import 'package:ipaside/services/settings_store.dart';
import 'package:ipaside/ui/shell/nav_destination.dart';
import 'package:ipaside/viewmodels/device_selection.dart';
import 'package:ipaside/viewmodels/jailbreak_view_model.dart';
import 'package:ipaside/viewmodels/navigation_state.dart';
import 'package:ipaside/viewmodels/sideload_progress_state.dart';

/// A transport stand-in scripted per engine command: records every argv, replays
/// canned frames, and can emit progress lines before the result. Same shape as the
/// LiveContainer test's runner.
class _FakeRunner with EngineCommandRunner {
  final Map<String, Queue<Object>> _scripted = <String, Queue<Object>>{};
  final Map<String, Object> _defaults = <String, Object>{};

  final List<List<String>> calls = <List<String>>[];
  final Map<String, List<String>> progress = <String, List<String>>{};

  void always(String command, Object outcome) => _defaults[command] = outcome;

  void next(String command, Object outcome) =>
      (_scripted[command] ??= Queue<Object>()).add(outcome);

  @override
  Future<EngineResult> run(
    List<String> args, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  }) async {
    calls.add(args);

    final String command = args.first;
    if (onProgress != null) {
      for (final String line in progress[command] ?? const <String>[]) {
        onProgress(line);
      }
    }

    final Queue<Object>? queued = _scripted[command];
    final Object outcome = queued != null && queued.isNotEmpty
        ? queued.removeFirst()
        : _defaults[command] ??
            const EngineResult(ok: true, data: <String, dynamic>{});
    if (outcome is EngineResult) {
      return outcome;
    }
    throw outcome;
  }
}

EngineResult _ok(Object data) => EngineResult(ok: true, data: data);

EngineResult _failed(String error) => EngineResult(ok: false, error: error);

final EngineResult _authenticated = _ok(<String, dynamic>{'authenticated': true});
final EngineResult _signedOut = _ok(<String, dynamic>{'authenticated': false});

class _FakeSettings extends SettingsStore {
  SignedIpaSettings signed = const SignedIpaSettings();
  String? deviceUdid;

  @override
  SignedIpaSettings loadSignedIpa() => signed;

  @override
  String? loadDeviceUdid() => deviceUdid;

  @override
  void saveDeviceUdid(String? udid) => deviceUdid = udid;
}

DeviceSelection _noDevice() {
  final DeviceSelection selection = DeviceSelection(
    engine: EngineApi(_FakeRunner()),
    settings: _FakeSettings(),
  );
  addTearDown(selection.dispose);
  return selection;
}

/// An advise payload for one device, defaulting to the supported A13 case.
Map<String, dynamic> _advice({
  String outcome = 'supported',
  bool canInstall = true,
  String productType = 'iPhone12,1',
  String deviceName = 'iPhone 11',
  String chip = 'A13',
  String ios = '16.7.15',
  String? maxSupported = '26.0.1',
  String summary = 'iPhone 11 (A13) on iOS 16.7.15 is supported by Dopamine.',
}) =>
    <String, dynamic>{
      'tool': <String, dynamic>{
        'id': 'dopamine',
        'name': 'Dopamine',
        'kind': 'Semi-untethered \u00b7 rootless',
        'developer': 'opa334 (Lars Fr\u00f6der)',
        'project_url': 'https://github.com/opa334/Dopamine',
        'known_version': '3.0',
      },
      'product_type': productType,
      'device_name': deviceName,
      'chip': chip,
      'ios_version': ios,
      'max_supported': ?maxSupported,
      'outcome': outcome,
      'can_install': canInstall,
      'summary': summary,
    };

Map<String, dynamic> _installed() => <String, dynamic>{
      'status': 'installed',
      'bundle_id': 'com.opa334.dopamine',
      'name': 'Dopamine',
      'dopamine_version': '3.0',
    };

JailbreakViewModel _model(
  _FakeRunner runner, {
  DeviceSelection? devices,
  NavigationState? navigation,
  _FakeSettings? settings,
  List<String>? openedUrls,
}) {
  final JailbreakViewModel vm = JailbreakViewModel(
    engine: EngineApi(runner),
    navigation: navigation ?? NavigationState(),
    settings: settings ?? _FakeSettings(),
    devices: devices ?? _noDevice(),
    launchUrl: openedUrls == null
        ? null
        : (String url) async {
            openedUrls.add(url);
            return true;
          },
  );
  addTearDown(vm.dispose);
  return vm;
}

String _frame(String phase, {double? percent, String? step}) =>
    '{"event":"progress","phase":"$phase"'
    '${percent == null ? '' : ',"percent":$percent'}'
    '${step == null ? '' : ',"step":"$step"'}}';

void main() {
  group('JailbreakViewModel advice', () {
    test('reads the device and reports a supported result', () async {
      final _FakeRunner runner = _FakeRunner()..always('jailbreak', _ok(_advice()));

      final JailbreakViewModel vm = _model(runner);
      await vm.load();

      expect(runner.calls.first, <String>['jailbreak']);
      expect(vm.advice?.isSupported, isTrue);
      expect(vm.canInstall, isTrue);
      expect(vm.advice?.chip, 'A13');
      expect(vm.tool?.name, 'Dopamine');
      expect(vm.error, isNull);
      expect(vm.isLoading, isFalse);
    });

    test('an unsupported iOS cannot be installed', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'jailbreak',
          _ok(_advice(
            outcome: 'unsupported_version',
            canInstall: false,
            chip: 'A17',
            productType: 'iPhone16,1',
            deviceName: 'iPhone 15 Pro',
            ios: '18.0',
            maxSupported: '17.3.1',
            summary: 'iPhone 15 Pro (A17) on iOS 18.0 is too new for Dopamine.',
          )),
        );

      final JailbreakViewModel vm = _model(runner);
      await vm.load();

      expect(vm.canInstall, isFalse);
      expect(vm.advice?.outcome, 'unsupported_version');
    });

    test('a chip with no jailbreak is reported and blocks install', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'jailbreak',
          _ok(_advice(
            outcome: 'no_jailbreak',
            canInstall: false,
            chip: 'A18',
            productType: 'iPhone17,1',
            deviceName: 'iPhone 16 Pro',
            ios: '26.0',
            maxSupported: null,
          )),
        );

      final JailbreakViewModel vm = _model(runner);
      await vm.load();

      expect(vm.advice?.hasNoJailbreak, isTrue);
      expect(vm.canInstall, isFalse);
    });

    test('the selected device and transport are passed through', () async {
      final _FakeRunner runner = _FakeRunner()..always('jailbreak', _ok(_advice()));

      final JailbreakViewModel vm =
          _model(runner, devices: await _deviceSelection('AAAA1111'));
      await vm.load();

      expect(runner.calls.first, <String>['jailbreak', '--udid', 'AAAA1111']);
    });

    test('a read failure is shown cleaned, not thrown', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('jailbreak', _failed('device is locked'));

      final JailbreakViewModel vm = _model(runner);
      await vm.load();

      expect(vm.error, contains('locked'));
      expect(vm.isLoading, isFalse);
    });

    test('retrying after a fetch failure clears the error and shows advice', () async {
      // First read fails (e.g. the compatibility list could not be fetched); the second
      // succeeds. This is exactly what the Retry button drives.
      final _FakeRunner runner = _FakeRunner()
        ..next('jailbreak', _failed("Couldn't fetch the jailbreak compatibility list."))
        ..next('jailbreak', _ok(_advice()));

      final JailbreakViewModel vm = _model(runner);
      await vm.load();
      expect(vm.error, isNotNull);
      expect(vm.advice, isNull);

      await vm.load(); // the Retry

      expect(vm.error, isNull);
      expect(vm.advice?.isSupported, isTrue);
    });
  });

  group('JailbreakViewModel project page', () {
    test('opens the tool project page from the advice', () async {
      final _FakeRunner runner = _FakeRunner()..always('jailbreak', _ok(_advice()));
      final List<String> opened = <String>[];

      final JailbreakViewModel vm = _model(runner, openedUrls: opened);
      await vm.load();
      await vm.openProjectPage();

      expect(opened, <String>['https://github.com/opa334/Dopamine']);
    });

    test('falls back to the Dopamine repo before any advice is read', () async {
      final _FakeRunner runner = _FakeRunner();
      final List<String> opened = <String>[];

      final JailbreakViewModel vm = _model(runner, openedUrls: opened);
      await vm.openProjectPage();

      expect(opened.single, contains('github.com/opa334/Dopamine'));
    });
  });

  group('JailbreakViewModel install', () {
    test('signs, installs, and reports the version', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('jailbreak', _ok(_advice()))
        ..always('login', _authenticated);
      // The advise read and the install share the `jailbreak` command; script the
      // install result to follow the advise the load() performs.
      runner.next('jailbreak', _ok(_advice()));
      runner.next('jailbreak', _ok(_installed()));

      final JailbreakViewModel vm = _model(runner);
      await vm.load();
      await vm.install();

      expect(vm.isSucceeded, isTrue);
      expect(vm.isFailed, isFalse);
      expect(vm.result?.version, '3.0');
      expect(vm.isRunning, isFalse);
    });

    test('asks for --install, and no --ipa so the engine fetches the release',
        () async {
      final _FakeRunner runner = _FakeRunner()..always('login', _authenticated);
      runner.next('jailbreak', _ok(_advice()));
      runner.next('jailbreak', _ok(_installed()));

      final JailbreakViewModel vm = _model(runner);
      await vm.load();
      await vm.install();

      final List<String> argv =
          runner.calls.firstWhere((List<String> c) => c.contains('--install'));
      expect(argv.first, 'jailbreak');
      expect(argv, contains('--install'));
      expect(argv, isNot(contains('--ipa')));
    });

    test('refuses to install when the device is not supported', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..always('jailbreak', _ok(_advice(outcome: 'no_jailbreak', canInstall: false)));

      final JailbreakViewModel vm = _model(runner);
      await vm.load();
      await vm.install();

      expect(
        runner.calls.any((List<String> c) => c.contains('--install')),
        isFalse,
        reason: 'an unsupported device must never sign and install',
      );
      expect(vm.isRunning, isFalse);
    });

    test("the user's keep-signed preference is honoured", () async {
      final _FakeSettings settings = _FakeSettings()
        ..signed = const SignedIpaSettings(keep: true, directory: r'D:\signed');
      final _FakeRunner runner = _FakeRunner()..always('login', _authenticated);
      runner.next('jailbreak', _ok(_advice()));
      runner.next('jailbreak', _ok(_installed()));

      final JailbreakViewModel vm = _model(runner, settings: settings);
      await vm.load();
      await vm.install();

      final List<String> argv =
          runner.calls.firstWhere((List<String> c) => c.contains('--install'));
      expect(argv, contains('--keep-signed'));
      expect(argv[argv.indexOf('--signed-dir') + 1], r'D:\signed');
    });

    test('a signed-out session goes to sign-in without touching the device',
        () async {
      final NavigationState navigation = NavigationState();
      addTearDown(navigation.dispose);
      final _FakeRunner runner = _FakeRunner()..always('login', _signedOut);
      runner.next('jailbreak', _ok(_advice()));

      final JailbreakViewModel vm = _model(runner, navigation: navigation);
      await vm.load();
      await vm.install();

      expect(navigation.current, NavKey.signIn);
      expect(
        runner.calls.any((List<String> c) => c.contains('--install')),
        isFalse,
        reason: 'nothing should be downloaded before Apple has been asked',
      );
      expect(vm.isRunning, isFalse);
    });

    test('a failure is reported and the stepper stays visible', () async {
      final _FakeRunner runner = _FakeRunner()..always('login', _authenticated);
      runner.next('jailbreak', _ok(_advice()));
      runner.next('jailbreak', _failed('zsign failed'));

      final JailbreakViewModel vm = _model(runner);
      await vm.load();
      await vm.install();

      expect(vm.isFailed, isTrue);
      expect(vm.failureMessage, contains('zsign'));
      expect(vm.showStepper, isTrue);
      expect(vm.isRunning, isFalse);
    });

    test('a second install while one runs is ignored', () async {
      final _FakeRunner runner = _FakeRunner()..always('login', _authenticated);
      runner.next('jailbreak', _ok(_advice()));
      runner.always('jailbreak', _ok(_installed()));

      final JailbreakViewModel vm = _model(runner);
      await vm.load();
      await Future.wait<void>(<Future<void>>[vm.install(), vm.install()]);

      expect(
        runner.calls.where((List<String> c) => c.contains('--install')).length,
        1,
      );
    });
  });

  group('JailbreakViewModel progress', () {
    test('download and install report a percentage; provision/sign sweep', () async {
      final _FakeRunner runner = _FakeRunner()..always('login', _authenticated);
      runner.next('jailbreak', _ok(_advice()));
      runner.next('jailbreak', _ok(_installed()));
      runner.progress['jailbreak'] = <String>[
        _frame('download', percent: 45, step: 'Downloading Dopamine'),
        _frame('sign', step: 'Signing the app'),
      ];

      final JailbreakViewModel vm = _model(runner);
      await vm.load();
      final List<SideloadProgressState> seen = <SideloadProgressState>[];
      vm.addListener(() => seen.add(vm.progress));
      await vm.install();

      final SideloadProgressState downloading = seen.firstWhere(
        (SideloadProgressState s) => s.stepText == 'Downloading Dopamine',
      );
      expect(downloading.activeIndex, 0);
      expect(downloading.percent, 45);
      expect(downloading.isIndeterminate, isFalse);

      final SideloadProgressState signing = seen.firstWhere(
        (SideloadProgressState s) => s.stepText == 'Signing the app',
      );
      expect(signing.activeIndex, 2, reason: 'download, provision, then sign');
      expect(signing.isIndeterminate, isTrue);
    });
  });

  group('ProgressSchedule.jailbreak', () {
    test('is download -> provision -> sign -> install', () {
      const ProgressSchedule schedule = ProgressSchedule.jailbreak;
      expect(schedule.indexOf('download'), 0);
      expect(schedule.indexOf('provision'), 1);
      expect(schedule.indexOf('sign'), 2);
      expect(schedule.indexOf('install'), 3);
      expect(schedule.indexOf('finalize'), isNull);
      expect(schedule.steps.length, schedule.phases.length);
      expect(schedule.labels.length, schedule.phases.length);
      expect(schedule.determinate, <String>{'download', 'install'});
    });
  });
}

/// A selection resolved to [udid] over its own transport, so the enumeration never
/// lands in the call list a test asserts on.
Future<DeviceSelection> _deviceSelection(String udid) async {
  final _FakeRunner runner = _FakeRunner()
    ..always(
      'devices',
      _ok(<dynamic>[
        <String, dynamic>{'serial': udid, 'connection_type': 'USB'},
      ]),
    )
    ..always('device-info', _ok(<String, dynamic>{'DeviceName': 'Test iPhone'}));

  final DeviceSelection selection = DeviceSelection(
    engine: EngineApi(runner),
    settings: _FakeSettings(),
  );
  addTearDown(selection.dispose);
  await selection.refresh();
  return selection;
}
