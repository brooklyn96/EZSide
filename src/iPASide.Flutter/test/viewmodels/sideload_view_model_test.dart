import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine.dart';
import 'package:ipaside/services/file_picker.dart';
import 'package:ipaside/services/icon_cache.dart';
import 'package:ipaside/services/settings_store.dart';
import 'package:ipaside/ui/shell/app_dialogs.dart';
import 'package:ipaside/ui/shell/nav_destination.dart';
import 'package:ipaside/viewmodels/device_selection.dart';
import 'package:ipaside/viewmodels/navigation_state.dart';
import 'package:ipaside/viewmodels/sideload_view_model.dart';

/// A transport stand-in scripted per engine command: it records every argv and
/// replays canned result frames (or throws a canned error).
class _FakeRunner with EngineCommandRunner {
  final Map<String, Queue<Object>> _scripted = <String, Queue<Object>>{};
  final Map<String, Object> _defaults = <String, Object>{};

  /// Every argv the facade issued, in order.
  final List<List<String>> calls = <List<String>>[];

  /// Parks the sign-in probe until completed, so a test can move the selection
  /// while a run is past its click but not yet at the engine.
  Completer<void>? loginHold;

  /// Parks `cert-status` until completed, so a test can move the selection while
  /// the certificate is still being asked about.
  Completer<void>? certificateHold;

  void always(String command, Object outcome) => _defaults[command] = outcome;

  void next(String command, Object outcome) =>
      (_scripted[command] ??= Queue<Object>()).add(outcome);

  List<List<String>> callsTo(String command) => <List<String>>[
        for (final List<String> argv in calls)
          if (argv.first == command) argv,
      ];

  @override
  Future<EngineResult> run(
    List<String> args, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  }) async {
    calls.add(args);
    if (args.first == 'login') await loginHold?.future;
    if (args.first == 'cert-status') await certificateHold?.future;

    final String command = args.first;
    final Queue<Object>? queued = _scripted[command];
    final Object outcome = queued != null && queued.isNotEmpty
        ? queued.removeFirst()
        : _defaults[command] ??
            const EngineResult(ok: true, data: <String, dynamic>{});
    if (outcome is EngineResult) return outcome;
    throw outcome;
  }
}

/// Answers without a navigator; nothing here needs to record.
class _FakeDialogs extends DialogService {
  _FakeDialogs() : super(GlobalKey<NavigatorState>());

  @override
  Future<bool> confirm({
    required String title,
    required String message,
    String confirmLabel = 'OK',
    String cancelLabel = 'Cancel',
    bool danger = false,
  }) async =>
      true;

  @override
  Future<void> alert({required String title, required String message}) async {}
}

class _FakePicker implements FilePickerService {
  @override
  Future<String?> pickIpa() async => null;

  @override
  Future<List<String>> pickTweaks() async => const <String>[];

  @override
  Future<String?> pickSignedFolder() async => null;

  @override
  Future<String?> pickPairingFile() async => null;

  @override
  Future<String?> savePairingFile({required String suggestedName}) async =>
      null;

  @override
  Future<String?> pickCertificate() async => null;

  @override
  Future<String?> pickProvisioningProfile() async => null;
}

/// An in-memory settings store: nothing here touches the real settings file, and
/// a test can change a value between two runs to prove the model rereads it.
class _FakeSettings extends SettingsStore {
  SignedIpaSettings signedIpa = const SignedIpaSettings();
  String? deviceUdid;

  @override
  SignedIpaSettings loadSignedIpa() => signedIpa;

  @override
  void saveSignedIpa(SignedIpaSettings settings) => signedIpa = settings;

  @override
  String? loadDeviceUdid() => deviceUdid;

  @override
  void saveDeviceUdid(String? udid) => deviceUdid = udid;
}

EngineResult _ok(Object data) => EngineResult(ok: true, data: data);

/// `inspect` for a signable app: no `sc_info`, so nothing blocks the run.
EngineResult get _inspection => _ok(<String, dynamic>{
      'bundle_id': 'com.example.app',
      'display_name': 'Example',
      'version': '1.0',
    });

EngineResult get _authenticated =>
    _ok(<String, dynamic>{'authenticated': true, 'email': 'a@example.com'});

EngineResult get _installed =>
    _ok(<String, dynamic>{'status': 'installed', 'name': 'Example'});

/// `cert-status` with an imported certificate expiring [expiresIn] from now,
/// whose profile does ([deviceOk] true) or does not list the iPhone asked about.
EngineResult _certificate({
  bool deviceOk = true,
  Duration expiresIn = const Duration(days: 100, hours: 12),
}) =>
    _ok(<String, dynamic>{
      'status': 'ok',
      'certificate': <String, dynamic>{
        'name': 'iPhone Distribution: Seller Ltd',
        'team_id': 'SELLER1234',
        'expires': DateTime.now().toUtc().add(expiresIn).toIso8601String(),
        'app_id': 'SELLER1234.*',
        'wildcard': true,
        'device_ok': deviceOk,
      },
    });

EngineResult get _noCertificate =>
    _ok(<String, dynamic>{'status': 'ok', 'certificate': null});

/// A selection that has enumerated nothing, so it names no target.
DeviceSelection _noDevice() {
  final DeviceSelection selection = DeviceSelection(
    engine: EngineApi(_FakeRunner()),
    settings: _FakeSettings(),
  );
  addTearDown(selection.dispose);
  return selection;
}

/// A selection already resolved to [udid], over its OWN transport so the device
/// enumeration never lands in the call list the test is asserting on.
Future<DeviceSelection> _device(String udid) async {
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

/// A session with an IPA already inspected in, ready to run.
Future<SideloadViewModel> _withIpa(
  _FakeRunner runner, {
  SettingsStore? settings,
  DeviceSelection? devices,
  NavigationState? navigation,
}) async {
  runner
    ..always('inspect', _inspection)
    ..always('login', _authenticated)
    ..always('sideload', _installed);

  final SideloadViewModel vm = SideloadViewModel(
    engine: EngineApi(runner),
    navigation: navigation ?? NavigationState(),
    dialogs: _FakeDialogs(),
    picker: _FakePicker(),
    icons: IconCache(),
    settings: settings ?? _FakeSettings(),
    devices: devices ?? _noDevice(),
  );
  addTearDown(vm.dispose);

  await vm.loadIpa(r'C:\ipas\Example.ipa');
  return vm;
}

void main() {
  group('SideloadViewModel keep-signed setting', () {
    test('sends neither flag while the setting is off', () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(runner);

      await vm.sideload();

      expect(
        runner.callsTo('sideload').single,
        <String>['sideload', r'C:\ipas\Example.ipa'],
      );
      expect(vm.isSucceeded, isTrue);
    });

    test('passes --keep-signed once the setting is on', () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(
        runner,
        settings: _FakeSettings()
          ..signedIpa = const SignedIpaSettings(keep: true),
      );

      await vm.sideload();

      expect(
        runner.callsTo('sideload').single,
        <String>['sideload', r'C:\ipas\Example.ipa', '--keep-signed'],
      );
    });

    test('passes the configured folder alongside it', () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(
        runner,
        settings: _FakeSettings()
          ..signedIpa = const SignedIpaSettings(
            keep: true,
            directory: r'D:\Signed',
          ),
      );

      await vm.sideload();

      expect(runner.callsTo('sideload').single, <String>[
        'sideload',
        r'C:\ipas\Example.ipa',
        '--keep-signed',
        '--signed-dir',
        r'D:\Signed',
      ]);
    });

    test('passes a folder chosen without keeping', () async {
      // The folder follows the directory rather than the keeping: it is also
      // where a `signed` listing would look.
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(
        runner,
        settings: _FakeSettings()
          ..signedIpa = const SignedIpaSettings(directory: r'D:\Signed'),
      );

      await vm.sideload();

      expect(runner.callsTo('sideload').single, <String>[
        'sideload',
        r'C:\ipas\Example.ipa',
        '--signed-dir',
        r'D:\Signed',
      ]);
    });

    test('a change to the setting reaches the very next run', () async {
      // The point of reading at run time: this model is app-scoped and outlives
      // every visit to Settings, so a value cached at construction would be the
      // one the app launched with, for the rest of the session.
      final _FakeRunner runner = _FakeRunner();
      final _FakeSettings settings = _FakeSettings();
      final SideloadViewModel vm = await _withIpa(runner, settings: settings);

      await vm.sideload();
      settings.signedIpa = const SignedIpaSettings(keep: true);
      await vm.sideload();

      expect(runner.callsTo('sideload'), <List<String>>[
        <String>['sideload', r'C:\ipas\Example.ipa'],
        <String>['sideload', r'C:\ipas\Example.ipa', '--keep-signed'],
      ]);
    });
  });

  group('SideloadViewModel device target', () {
    test('installs to the selected device', () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm =
          await _withIpa(runner, devices: await _device('BBBB2222'));

      await vm.sideload();

      expect(runner.callsTo('sideload').single, <String>[
        'sideload',
        r'C:\ipas\Example.ipa',
        '--udid',
        'BBBB2222',
      ]);
    });

    test('a retarget between runs is honoured', () async {
      final _FakeRunner selectionRunner = _FakeRunner()
        ..always(
          'devices',
          _ok(<dynamic>[
            <String, dynamic>{'serial': 'AAAA1111', 'connection_type': 'USB'},
            <String, dynamic>{'serial': 'BBBB2222', 'connection_type': 'USB'},
          ]),
        );
      final DeviceSelection devices = DeviceSelection(
        engine: EngineApi(selectionRunner),
        settings: _FakeSettings(),
      );
      addTearDown(devices.dispose);
      await devices.refresh();

      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(runner, devices: devices);

      await vm.sideload();
      devices.select('BBBB2222');
      await vm.sideload();

      expect(
        runner.callsTo('sideload').map((List<String> argv) => argv.last),
        <String>['AAAA1111', 'BBBB2222'],
      );
    });

    test('installs to the phone clicked for, even if the selection moves during '
        'sign-in', () async {
      final _FakeRunner selectionRunner = _FakeRunner()
        ..always(
          'devices',
          _ok(<dynamic>[
            <String, dynamic>{'serial': 'AAAA1111', 'connection_type': 'USB'},
            <String, dynamic>{'serial': 'BBBB2222', 'connection_type': 'USB'},
          ]),
        );
      final DeviceSelection devices = DeviceSelection(
        engine: EngineApi(selectionRunner),
        settings: _FakeSettings(),
      );
      addTearDown(devices.dispose);
      await devices.refresh();
      devices.select('BBBB2222');

      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(runner, devices: devices);
      runner.loginHold = Completer<void>();

      final Future<void> run = vm.sideload();
      await pumpEventQueue();
      devices.select('AAAA1111'); // while the sign-in probe is out
      runner.loginHold!.complete();
      await run;

      expect(runner.callsTo('sideload').single.last, 'BBBB2222');
    });

    test('a phone that drops out during sign-in fails the run, and no other '
        'phone gets the install', () async {
      final _FakeRunner selectionRunner = _FakeRunner()
        ..next(
          'devices',
          _ok(<dynamic>[
            <String, dynamic>{'serial': 'AAAA1111', 'connection_type': 'USB'},
            <String, dynamic>{
              'serial': 'BBBB2222',
              'connection_type': 'Network',
            },
          ]),
        )
        ..always(
          'devices',
          _ok(<dynamic>[
            <String, dynamic>{'serial': 'AAAA1111', 'connection_type': 'USB'},
          ]),
        );
      final DeviceSelection devices = DeviceSelection(
        engine: EngineApi(selectionRunner),
        settings: _FakeSettings(),
      );
      addTearDown(devices.dispose);
      await devices.refresh();
      devices.select('BBBB2222');

      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(runner, devices: devices);
      runner.loginHold = Completer<void>();

      final Future<void> run = vm.sideload();
      await pumpEventQueue();
      await devices.refresh(); // the Wi-Fi phone leaves the listing
      runner.loginHold!.complete();
      await run;

      expect(runner.callsTo('sideload'), isEmpty);
      expect(vm.isFailed, isTrue);
      expect(vm.failureMessage, DeviceSelection.targetGoneMessage);
      expect(vm.isRunning, isFalse);
    });

    test('no phone at the click installs to none, even one plugged in during '
        'sign-in', () async {
      final _FakeRunner selectionRunner = _FakeRunner()
        ..next('devices', _ok(<dynamic>[]))
        ..always(
          'devices',
          _ok(<dynamic>[
            <String, dynamic>{'serial': 'AAAA1111', 'connection_type': 'USB'},
          ]),
        );
      final DeviceSelection devices = DeviceSelection(
        engine: EngineApi(selectionRunner),
        settings: _FakeSettings(),
      );
      addTearDown(devices.dispose);
      await devices.refresh();
      expect(devices.isEmpty, isTrue);

      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(runner, devices: devices);
      runner.loginHold = Completer<void>();

      final Future<void> run = vm.sideload();
      await pumpEventQueue();
      await devices.refresh(); // a phone is plugged in
      expect(devices.selectedUdid, 'AAAA1111');
      runner.loginHold!.complete();
      await run;

      expect(runner.callsTo('sideload'), isEmpty);
      expect(vm.failureMessage, DeviceSelection.targetGoneMessage);
    });

    test('both the target and the setting travel together', () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(
        runner,
        settings: _FakeSettings()
          ..signedIpa = const SignedIpaSettings(keep: true),
        devices: await _device('BBBB2222'),
      );

      await vm.sideload();

      expect(runner.callsTo('sideload').single, <String>[
        'sideload',
        r'C:\ipas\Example.ipa',
        '--udid',
        'BBBB2222',
        '--keep-signed',
      ]);
    });
  });

  group('SideloadViewModel pre-flight', () {
    test('a signed-out session goes to sign-in and runs nothing', () async {
      final _FakeRunner runner = _FakeRunner();
      final NavigationState navigation = NavigationState();
      addTearDown(navigation.dispose);
      final SideloadViewModel vm =
          await _withIpa(runner, navigation: navigation);
      runner.always('login', _ok(<String, dynamic>{'authenticated': false}));

      await vm.sideload();

      expect(navigation.current, NavKey.signIn);
      expect(runner.callsTo('sideload'), isEmpty);
    });

    test('two sideloads in one frame install once', () async {
      // The button is disabled while a run is on, but the guard has to hold on its
      // own: both calls would otherwise clear the sign-in probe before either set
      // the running flag, and the app would be installed twice.
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..always('sideload', _installed);
      final SideloadViewModel vm = await _withIpa(runner);

      await Future.wait<void>(<Future<void>>[vm.sideload(), vm.sideload()]);

      expect(runner.callsTo('sideload').length, 1);
      expect(vm.isSucceeded, isTrue);
      expect(vm.isRunning, isFalse);
    });

    test('a signed-out session leaves no half-started run on screen', () async {
      // The running flag is claimed before the probe, so bailing out to sign-in
      // has to put it back or the stepper would sit there forever.
      final _FakeRunner runner = _FakeRunner();
      final NavigationState navigation = NavigationState();
      addTearDown(navigation.dispose);
      final SideloadViewModel vm =
          await _withIpa(runner, navigation: navigation);
      runner.always('login', _ok(<String, dynamic>{'authenticated': false}));

      await vm.sideload();

      expect(vm.isRunning, isFalse);
      expect(vm.isFailed, isFalse);
      expect(vm.isSucceeded, isFalse);
    });

    test('no IPA selected runs nothing', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated);
      final SideloadViewModel vm = SideloadViewModel(
        engine: EngineApi(runner),
        navigation: NavigationState(),
        dialogs: _FakeDialogs(),
        picker: _FakePicker(),
        icons: IconCache(),
        settings: _FakeSettings(),
        devices: _noDevice(),
      );
      addTearDown(vm.dispose);

      await vm.sideload();

      expect(runner.calls, isEmpty);
    });
  });

  group('SideloadViewModel imported certificate', () {
    EngineResult signedOut() =>
        _ok(<String, dynamic>{'authenticated': false});

    /// Two phones listed, AAAA1111 selected.
    Future<DeviceSelection> twoPhones() async {
      final DeviceSelection devices = DeviceSelection(
        engine: EngineApi(
          _FakeRunner()
            ..always(
              'devices',
              _ok(<dynamic>[
                <String, dynamic>{'serial': 'AAAA1111', 'connection_type': 'USB'},
                <String, dynamic>{'serial': 'BBBB2222', 'connection_type': 'USB'},
              ]),
            ),
        ),
        settings: _FakeSettings(),
      );
      addTearDown(devices.dispose);
      await devices.refresh();
      return devices;
    }

    test('is read for the selected iPhone when the screen opens', () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm =
          await _withIpa(runner, devices: await _device('BBBB2222'));
      expect(runner.callsTo('cert-status'), isEmpty,
          reason: 'nothing is asked before the screen opens');
      expect(vm.hasReadCertificate, isFalse);

      await vm.loadCertificate();

      expect(runner.callsTo('cert-status').single,
          <String>['cert-status', '--udid', 'BBBB2222']);
      expect(vm.hasReadCertificate, isTrue);
    });

    test('is read again when the selected iPhone changes', () async {
      final _FakeRunner selectionRunner = _FakeRunner()
        ..always(
          'devices',
          _ok(<dynamic>[
            <String, dynamic>{'serial': 'AAAA1111', 'connection_type': 'USB'},
            <String, dynamic>{'serial': 'BBBB2222', 'connection_type': 'USB'},
          ]),
        );
      final DeviceSelection devices = DeviceSelection(
        engine: EngineApi(selectionRunner),
        settings: _FakeSettings(),
      );
      addTearDown(devices.dispose);
      await devices.refresh();

      final _FakeRunner runner = _FakeRunner()
        ..next('cert-status', _certificate(deviceOk: false))
        ..next('cert-status', _certificate());
      final SideloadViewModel vm = await _withIpa(runner, devices: devices);
      await vm.loadCertificate();
      expect(vm.canSignWithCertificate, isFalse);

      devices.select('BBBB2222');
      await pumpEventQueue();

      expect(
        runner.callsTo('cert-status').map((List<String> argv) => argv.last),
        <String>['AAAA1111', 'BBBB2222'],
      );
      expect(vm.canSignWithCertificate, isTrue);
    });

    test('an active certificate for this iPhone sideloads without an Apple ID',
        () async {
      final _FakeRunner runner = _FakeRunner();
      final NavigationState navigation = NavigationState();
      addTearDown(navigation.dispose);
      final SideloadViewModel vm = await _withIpa(
        runner,
        devices: await _device('BBBB2222'),
        navigation: navigation,
      );
      runner
        ..always('cert-status', _certificate())
        ..always('login', signedOut());
      await vm.loadCertificate();

      expect(vm.signsWithCertificate, isTrue);
      expect(vm.signerText, startsWith('Signing with your imported certificate (expires '));
      expect(vm.signerText, endsWith(', 100 days)'));
      expect(vm.certificateWarning, isNull);

      await vm.sideload();

      expect(runner.callsTo('login'), isEmpty);
      expect(navigation.current, isNot(NavKey.signIn));
      expect(runner.callsTo('sideload').single, <String>[
        'sideload',
        r'C:\ipas\Example.ipa',
        '--udid',
        'BBBB2222',
        '--signer',
        'custom',
      ], reason: 'a certificate removed or expired since the read must be '
          'refused by the engine, not swapped for the Apple ID');
      expect(vm.isSucceeded, isTrue);
    });

    test('less than a day left says "under a day", not "0 days"', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'cert-status',
          _certificate(expiresIn: const Duration(hours: 5)),
        );
      final SideloadViewModel vm =
          await _withIpa(runner, devices: await _device('BBBB2222'));
      await vm.loadCertificate();

      expect(vm.signsWithCertificate, isTrue);
      expect(vm.signerText, endsWith(', under a day)'));
    });

    test('a click asks about the clicked iPhone itself: a read still out for '
        'another one, selected again before it answers, does not decide',
        () async {
      final DeviceSelection devices = await twoPhones();
      final _FakeRunner runner = _FakeRunner()
        // In the order asked: the screen's read for AAAA1111, then the click's
        // own for BBBB2222.
        ..next('cert-status', _certificate(deviceOk: false))
        ..next('cert-status', _certificate());
      final SideloadViewModel vm = await _withIpa(runner, devices: devices);
      runner.always('login', signedOut());
      runner.certificateHold = Completer<void>();

      final Future<void> read = vm.loadCertificate(); // for AAAA1111, still out
      await pumpEventQueue();
      devices.select('BBBB2222');
      final Future<void> run = vm.sideload();
      await pumpEventQueue();
      devices.select('AAAA1111'); // back again before either answer
      runner.certificateHold!.complete();
      await run;
      await read;

      expect(
        runner.callsTo('cert-status').map((List<String> argv) => argv.last),
        <String>['AAAA1111', 'BBBB2222'],
      );
      expect(runner.callsTo('login'), isEmpty,
          reason: 'the certificate covers BBBB2222, so no Apple ID is needed');
      expect(runner.callsTo('sideload').single, <String>[
        'sideload',
        r'C:\ipas\Example.ipa',
        '--udid',
        'BBBB2222',
        '--signer',
        'custom',
      ]);
      expect(vm.isSucceeded, isTrue);
    });

    test('the answer shown for another iPhone does not skip the sign-in check: '
        'the click waits for its own', () async {
      final DeviceSelection devices = await twoPhones();
      final _FakeRunner runner = _FakeRunner()
        ..next('cert-status', _certificate())
        ..always('cert-status', _certificate(deviceOk: false));
      final SideloadViewModel vm = await _withIpa(runner, devices: devices);
      await vm.loadCertificate(); // for AAAA1111
      expect(vm.signsWithCertificate, isTrue);

      runner.certificateHold = Completer<void>();
      devices.select('BBBB2222');
      await pumpEventQueue();

      final Future<void> run = vm.sideload();
      await pumpEventQueue();
      expect(runner.callsTo('login'), isEmpty,
          reason: 'nothing is decided before the answer about BBBB2222');
      expect(runner.callsTo('sideload'), isEmpty);
      expect(vm.isRunning, isTrue);

      runner.certificateHold!.complete();
      await run;

      expect(runner.callsTo('login'), hasLength(1));
      expect(runner.callsTo('sideload').single, <String>[
        'sideload',
        r'C:\ipas\Example.ipa',
        '--udid',
        'BBBB2222',
      ]);
    });

    test('a click whose certificate read fails checks sign-in and lets the '
        'engine choose', () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm =
          await _withIpa(runner, devices: await _device('BBBB2222'));
      runner.always('cert-status', EngineException('engine busy'));

      await vm.sideload();

      expect(runner.callsTo('cert-status').single,
          <String>['cert-status', '--udid', 'BBBB2222']);
      expect(runner.callsTo('login'), hasLength(1));
      expect(runner.callsTo('sideload').single, <String>[
        'sideload',
        r'C:\ipas\Example.ipa',
        '--udid',
        'BBBB2222',
      ]);
      expect(vm.isSucceeded, isTrue);
    });

    test('the signer line says it is checking while the newly selected iPhone '
        'is being asked about', () async {
      final DeviceSelection devices = await twoPhones();
      final _FakeRunner runner = _FakeRunner()
        ..next('cert-status', _certificate())
        ..next('cert-status', _certificate(deviceOk: false));
      final SideloadViewModel vm = await _withIpa(runner, devices: devices);
      await vm.loadCertificate(); // for AAAA1111
      expect(vm.isCheckingCertificate, isFalse);

      runner.certificateHold = Completer<void>();
      devices.select('BBBB2222');
      await pumpEventQueue();

      expect(vm.isCheckingCertificate, isTrue);
      expect(vm.signerText, 'Checking your imported certificate\u2026');
      expect(vm.canSignWithCertificate, isFalse);
      expect(vm.certificateWarning, isNull);

      runner.certificateHold!.complete();
      await pumpEventQueue();

      expect(vm.isCheckingCertificate, isFalse);
      expect(vm.signerText, 'Signing with your Apple ID (7 days)');
      expect(vm.certificateWarning,
          'Your imported certificate does not include this iPhone.');
    });

    test('"Use my Apple ID instead" holds for another iPhone clicked while its '
        'read is still out', () async {
      final DeviceSelection devices = await twoPhones();
      final _FakeRunner runner = _FakeRunner()
        ..always('cert-status', _certificate());
      final SideloadViewModel vm = await _withIpa(runner, devices: devices);
      await vm.loadCertificate(); // for AAAA1111
      vm.useAppleId = true;

      runner.certificateHold = Completer<void>();
      devices.select('BBBB2222'); // in the certificate too, once it answers
      await pumpEventQueue();

      final Future<void> run = vm.sideload();
      await pumpEventQueue();
      runner.certificateHold!.complete();
      await run;

      expect(runner.callsTo('login'), hasLength(1));
      expect(runner.callsTo('sideload').single, <String>[
        'sideload',
        r'C:\ipas\Example.ipa',
        '--udid',
        'BBBB2222',
        '--signer',
        'apple',
      ], reason: 'the explicit choice never becomes auto, which would sign '
          'with the imported certificate');
    });

    test('a change of iPhone while the read is out reads the new one', () async {
      final DeviceSelection devices = await twoPhones();
      final _FakeRunner runner = _FakeRunner()
        ..next('cert-status', _certificate())
        ..next('cert-status', _certificate(deviceOk: false));
      final SideloadViewModel vm = await _withIpa(runner, devices: devices);
      runner.certificateHold = Completer<void>();

      final Future<void> read = vm.loadCertificate(); // for AAAA1111
      await pumpEventQueue();
      devices.select('BBBB2222');
      runner.certificateHold!.complete();
      await read;

      expect(
        runner.callsTo('cert-status').map((List<String> argv) => argv.last),
        <String>['AAAA1111', 'BBBB2222'],
      );
      expect(vm.canSignWithCertificate, isFalse,
          reason: "AAAA1111's answer must not stand for BBBB2222");
      expect(vm.certificateWarning,
          'Your imported certificate does not include this iPhone.');
    });

    test('"Use my Apple ID instead" sends --signer apple and checks sign-in',
        () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm =
          await _withIpa(runner, devices: await _device('BBBB2222'));
      runner.always('cert-status', _certificate());
      await vm.loadCertificate();

      vm.useAppleId = true;

      expect(vm.signsWithCertificate, isFalse);
      expect(vm.signerText, 'Signing with your Apple ID (7 days)');

      await vm.sideload();

      expect(runner.callsTo('cert-status'), hasLength(1),
          reason: 'the choice is made: the click asks nothing more');
      expect(runner.callsTo('login'), hasLength(1));
      expect(runner.callsTo('sideload').single, <String>[
        'sideload',
        r'C:\ipas\Example.ipa',
        '--udid',
        'BBBB2222',
        '--signer',
        'apple',
      ]);
    });

    test('a new IPA clears "Use my Apple ID instead"', () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm =
          await _withIpa(runner, devices: await _device('BBBB2222'));
      runner.always('cert-status', _certificate());
      await vm.loadCertificate();
      vm.useAppleId = true;

      await vm.loadIpa(r'C:\ipas\Other.ipa');

      expect(vm.useAppleId, isFalse);
      expect(vm.signsWithCertificate, isTrue);
    });

    test('a certificate without this iPhone says so and needs the Apple ID',
        () async {
      final _FakeRunner runner = _FakeRunner();
      final NavigationState navigation = NavigationState();
      addTearDown(navigation.dispose);
      final SideloadViewModel vm = await _withIpa(
        runner,
        devices: await _device('BBBB2222'),
        navigation: navigation,
      );
      runner
        ..always('cert-status', _certificate(deviceOk: false))
        ..always('login', signedOut());
      await vm.loadCertificate();

      expect(vm.canSignWithCertificate, isFalse);
      expect(vm.signerText, 'Signing with your Apple ID (7 days)');
      expect(vm.certificateWarning,
          'Your imported certificate does not include this iPhone.');

      await vm.sideload();

      expect(navigation.current, NavKey.signIn);
      expect(runner.callsTo('sideload'), isEmpty);
    });

    test('an expired certificate is the Apple ID path, without a warning',
        () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm =
          await _withIpa(runner, devices: await _device('BBBB2222'));
      runner.always(
        'cert-status',
        _certificate(expiresIn: const Duration(days: -1)),
      );
      await vm.loadCertificate();

      expect(vm.canSignWithCertificate, isFalse);
      expect(vm.signerText, 'Signing with your Apple ID (7 days)');
      expect(vm.certificateWarning, isNull);

      await vm.sideload();

      expect(runner.callsTo('login'), hasLength(1));
      expect(runner.callsTo('sideload').single, isNot(contains('--signer')));
    });

    test('no certificate, or an unreadable answer, is the Apple ID path',
        () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm =
          await _withIpa(runner, devices: await _device('BBBB2222'));
      runner
        ..next('cert-status', _noCertificate)
        ..next('cert-status', EngineException('engine busy'));

      await vm.loadCertificate();
      expect(vm.signerText, 'Signing with your Apple ID (7 days)');
      expect(vm.certificateWarning, isNull);

      await vm.loadCertificate();
      expect(vm.hasReadCertificate, isTrue);
      expect(vm.canSignWithCertificate, isFalse);
    });
  });
}
