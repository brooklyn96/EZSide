import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine.dart';
import 'package:ipaside/services/settings_store.dart';
import 'package:ipaside/viewmodels/device_selection.dart';
import 'package:ipaside/viewmodels/home_view_model.dart';
import 'package:ipaside/viewmodels/navigation_state.dart';

/// A transport stand-in scripted per engine command, recording every argv.
class _FakeRunner with EngineCommandRunner {
  final Map<String, Queue<Object>> _scripted = <String, Queue<Object>>{};
  final Map<String, Object> _defaults = <String, Object>{};

  /// Every argv the facade issued, in order.
  final List<List<String>> calls = <List<String>>[];

  /// Parks each answer until completed, so a mid-flight state can be asserted.
  Completer<void>? hold;

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
    await hold?.future;

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

/// An in-memory settings store, so no test touches the real settings file.
class _FakeSettings extends SettingsStore {
  String? deviceUdid;
  String connection = 'auto';

  @override
  String? loadDeviceUdid() => deviceUdid;

  @override
  void saveDeviceUdid(String? udid) => deviceUdid = udid;

  @override
  String loadConnection() => connection;

  @override
  void saveConnection(String value) => connection = value;
}

EngineResult _ok(Object data) => EngineResult(ok: true, data: data);

const String _plus = '935cbbb9b82d25d15566e5939bcea5677b1c44ae';
const String _other = '00008150-001479110E20401C';

Map<String, dynamic> _identity({
  required String name,
  required String model,
  required String udid,
}) =>
    <String, dynamic>{
      'DeviceName': name,
      'ProductType': model,
      'ProductVersion': '16.7.15',
      'BuildVersion': '20H380',
      'UniqueDeviceID': udid,
    };

/// A selection over two phones: one reachable both ways, one on the cable only.
///
/// Its own runner, so the enumeration and the name lookups never land in the call
/// list a test is asserting the view model made.
Future<DeviceSelection> _twoDevices({String connection = 'auto'}) async {
  final _FakeRunner runner = _FakeRunner()
    ..always(
      'devices',
      _ok(<dynamic>[
        <String, dynamic>{'serial': _plus, 'connection_type': 'USB'},
        <String, dynamic>{'serial': _plus, 'connection_type': 'Network'},
        <String, dynamic>{'serial': _other, 'connection_type': 'USB'},
      ]),
    )
    ..always('device-info', _ok(<String, dynamic>{'DeviceName': 'A phone'}));

  final DeviceSelection selection = DeviceSelection(
    engine: EngineApi(runner),
    settings: _FakeSettings()..connection = connection,
  );
  addTearDown(selection.dispose);
  await selection.refresh();
  await pumpEventQueue();
  return selection;
}

Future<HomeViewModel> _home(
  _FakeRunner runner,
  DeviceSelection devices,
) async {
  final HomeViewModel vm = HomeViewModel(
    engine: EngineApi(runner),
    navigation: NavigationState(),
    devices: devices,
  );
  addTearDown(vm.dispose);
  await pumpEventQueue();
  return vm;
}

void main() {
  group('HomeViewModel device card', () {
    test('describes the selected device, and says which one it asked about',
        () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'device-info',
          _ok(_identity(
            name: "iOS_hAT's iPhone",
            model: 'iPhone10,2',
            udid: _plus,
          )),
        );

      final HomeViewModel vm = await _home(runner, await _twoDevices());

      expect(vm.isDeviceLoading, isFalse);
      expect(vm.hasDevice, isTrue);
      expect(vm.deviceName, "iOS_hAT's iPhone");
      expect(vm.deviceModel, 'iPhone10,2');
      expect(vm.deviceIos, '16.7.15 (20H380)');
      expect(runner.callsTo('device-info').single, <String>[
        'device-info',
        '--udid',
        _plus,
      ]);
    });

    test('retargeting reloads it, rather than leaving the old phone on screen',
        () async {
      // The bug this pins: the card loaded once at construction and then kept
      // describing whichever phone had been selected at the time, under the name
      // of the one the user had since picked in the sidebar.
      final _FakeRunner runner = _FakeRunner()
        ..next(
          'device-info',
          _ok(_identity(
            name: "iOS_hAT's iPhone",
            model: 'iPhone10,2',
            udid: _plus,
          )),
        )
        ..next(
          'device-info',
          _ok(_identity(
            name: "Sahil's iPhone",
            model: 'iPhone18,3',
            udid: _other,
          )),
        );

      final DeviceSelection devices = await _twoDevices();
      final HomeViewModel vm = await _home(runner, devices);
      expect(vm.deviceName, "iOS_hAT's iPhone");

      devices.select(_other);
      await pumpEventQueue();

      expect(vm.deviceName, "Sahil's iPhone");
      expect(vm.deviceModel, 'iPhone18,3');
      expect(
        runner.callsTo('device-info').last,
        <String>['device-info', '--udid', _other],
        reason: 'the reload has to name the newly selected phone',
      );
    });

    test('shows its spinner again while the new device is being read', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('device-info', _ok(_identity(
          name: 'Either phone',
          model: 'iPhone10,2',
          udid: _plus,
        )));

      final DeviceSelection devices = await _twoDevices();
      final HomeViewModel vm = await _home(runner, devices);

      runner.hold = Completer<void>();
      devices.select(_other);
      await pumpEventQueue();

      expect(vm.isDeviceLoading, isTrue, reason: 'it is reading the new phone');
      expect(vm.hasDevice, isFalse, reason: 'and must not still assert the old one');

      runner.hold!.complete();
      runner.hold = null;
      await pumpEventQueue();
      expect(vm.isDeviceLoading, isFalse);
    });

    test('a notification that retargets nothing costs no round trip', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('device-info', _ok(_identity(
          name: 'A phone',
          model: 'iPhone10,2',
          udid: _plus,
        )));

      final DeviceSelection devices = await _twoDevices();
      await _home(runner, devices);
      final int after = runner.callsTo('device-info').length;

      // Selection notifies for plenty of reasons that change neither the device
      // nor the transport: an enumeration starting, resolved names arriving.
      await devices.refresh();
      await pumpEventQueue();
      devices.select(_plus); // already selected, so a no-op
      await pumpEventQueue();

      expect(runner.callsTo('device-info'), hasLength(after));
    });

    test('changing the transport re-reads over the new one', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('device-info', _ok(_identity(
          name: 'A phone',
          model: 'iPhone10,2',
          udid: _plus,
        )));

      final DeviceSelection devices = await _twoDevices();
      await _home(runner, devices);

      devices.setConnection(DeviceConnection.wifi);
      await pumpEventQueue();

      expect(runner.callsTo('device-info').last, <String>[
        'device-info',
        '--udid',
        _plus,
        '--connection',
        'wifi',
      ]);
    });

    test('a slow answer for a phone left behind never lands', () async {
      // Two retargets in quick succession: whichever request the engine answers
      // last, the card must describe the phone that is actually selected.
      final _FakeRunner runner = _FakeRunner()
        ..next(
          'device-info',
          _ok(_identity(name: 'First', model: 'iPhone10,2', udid: _plus)),
        )
        ..next(
          'device-info',
          _ok(_identity(name: 'Stale', model: 'iPhone10,2', udid: _plus)),
        )
        ..next(
          'device-info',
          _ok(_identity(name: 'Current', model: 'iPhone18,3', udid: _other)),
        );

      final DeviceSelection devices = await _twoDevices();
      final HomeViewModel vm = await _home(runner, devices);

      runner.hold = Completer<void>();
      devices.select(_other); // starts the "Stale" read
      await pumpEventQueue();
      devices.select(_plus); // and abandons it for the "Current" one
      devices.select(_other);
      await pumpEventQueue();
      runner.hold!.complete();
      runner.hold = null;
      await pumpEventQueue();

      expect(vm.deviceName, 'Current');
      expect(vm.deviceModel, 'iPhone18,3');
    });

    test('an unreachable device is reported without a spinner left running',
        () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'device-info',
          const EngineResult(ok: false, error: 'Device X is not connected.'),
        );

      final HomeViewModel vm = await _home(runner, await _twoDevices());

      expect(vm.isDeviceLoading, isFalse);
      expect(vm.hasDeviceError, isTrue);
      expect(vm.deviceError, 'Device X is not connected.');
    });

    test('nothing paired reads as empty, not as a failure', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('device-info', _ok(<String, dynamic>{}));

      final HomeViewModel vm = await _home(runner, await _twoDevices());

      expect(vm.isDeviceEmpty, isTrue);
      expect(vm.hasDeviceError, isFalse);
    });
  });

  group('HomeViewModel connection card', () {
    test('reports the transports of the SELECTED phone', () async {
      // The other half of the same bug: this card described a phone reachable
      // over Wi-Fi while the sidebar had a USB-only one selected, because it ran
      // its own enumeration instead of reading the one the picker had already done.
      final DeviceSelection devices = await _twoDevices();
      final HomeViewModel vm = await _home(_FakeRunner(), devices);

      expect(vm.usbText, 'connected');
      expect(vm.wifiText, 'available', reason: 'the 8 Plus is on both');

      devices.select(_other);
      await pumpEventQueue();

      expect(vm.usbText, 'connected');
      expect(vm.wifiText, '\u2014', reason: 'the other phone is on the cable only');
    });

    test('never enumerates for itself', () async {
      // One enumeration cannot disagree with itself, and this is a round trip
      // fewer per visit to Home.
      final _FakeRunner runner = _FakeRunner();
      await _home(runner, await _twoDevices());

      expect(runner.callsTo('devices'), isEmpty);
    });

    test('with no phone connected, reads as empty rather than reachable', () async {
      // Deliberately not enumerated up front: Home is built on launch before the
      // shared enumeration answers, so this is the state the card opens in.
      final DeviceSelection none = DeviceSelection(
        engine: EngineApi(_FakeRunner()..always('devices', _ok(<dynamic>[]))),
        settings: _FakeSettings(),
      );
      addTearDown(none.dispose);

      final HomeViewModel vm = await _home(_FakeRunner(), none);

      expect(vm.usbText, '\u2014');
      expect(vm.wifiText, '\u2014');
      expect(vm.hasVisibleDevice, isFalse);
      expect(vm.isConnectionEmpty, isTrue, reason: 'it looked, and found none');
      expect(vm.hasConnectionError, isFalse, reason: 'nothing failed');
    });

    test('a failed enumeration is reported, not silently empty', () async {
      final _FakeRunner failing = _FakeRunner()
        ..always('devices', const EngineResult(ok: false, error: 'usbmux is down.'));
      final DeviceSelection devices = DeviceSelection(
        engine: EngineApi(failing),
        settings: _FakeSettings(),
      );
      addTearDown(devices.dispose);
      await devices.refresh();

      final HomeViewModel vm = await _home(_FakeRunner(), devices);

      expect(vm.hasConnectionError, isTrue);
      expect(vm.connectionError, 'usbmux is down.');
    });
  });

  group('HomeViewModel Apple ID card', () {
    test('loads the session without waiting on a device', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'login',
          _ok(<String, dynamic>{
            'authenticated': true,
            'email': 'someone@example.com',
          }),
        )
        ..always('device-info', const EngineResult(ok: false, error: 'no phone'));

      final HomeViewModel vm = await _home(runner, await _twoDevices());

      expect(vm.isAuthenticated, isTrue);
      expect(vm.accountEmail, 'someone@example.com');
      expect(vm.hasDeviceError, isTrue, reason: 'the two are independent');
    });

    test('is not reloaded by retargeting, because it is not about a device',
        () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _ok(<String, dynamic>{'authenticated': false}));

      final DeviceSelection devices = await _twoDevices();
      await _home(runner, devices);
      expect(runner.callsTo('login'), hasLength(1));

      devices.select(_other);
      await pumpEventQueue();

      expect(runner.callsTo('login'), hasLength(1));
    });
  });

  group('HomeViewModel teardown', () {
    test('stops following the selection once disposed', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('device-info', _ok(_identity(
          name: 'A phone',
          model: 'iPhone10,2',
          udid: _plus,
        )));

      final DeviceSelection devices = await _twoDevices();
      final HomeViewModel vm = HomeViewModel(
        engine: EngineApi(runner),
        navigation: NavigationState(),
        devices: devices,
      );
      await pumpEventQueue();
      final int before = runner.calls.length;

      vm.dispose();
      devices.select(_other);
      await pumpEventQueue();

      expect(runner.calls, hasLength(before));
    });
  });

  group('HomeViewModel.shortId', () {
    test('keeps the ends of a long UDID and drops the middle', () {
      expect(HomeViewModel.shortId(_plus), '935cbbb9\u202644ae');
    });

    test('leaves a short id and an absent one alone', () {
      expect(HomeViewModel.shortId('ABCD'), 'ABCD');
      expect(HomeViewModel.shortId(null), '');
      expect(HomeViewModel.shortId(''), '');
    });
  });
}
