import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine.dart';
import 'package:ipaside/services/settings_store.dart';
import 'package:ipaside/viewmodels/device_selection.dart';

/// A transport stand-in scripted per engine command: it records every argv and
/// replays canned result frames (or throws a canned error).
class _FakeRunner with EngineCommandRunner {
  final Map<String, Queue<Object>> _scripted = <String, Queue<Object>>{};
  final Map<String, Object> _defaults = <String, Object>{};
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Every argv the facade issued, in order.
  final List<List<String>> calls = <List<String>>[];

  /// Parks each answer until completed, so a mid-flight state can be asserted.
  Completer<void>? hold;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  void emitDevices(List<Map<String, dynamic>> entries) {
    _events.add(<String, dynamic>{
      'type': 'event',
      'name': 'devices',
      'data': entries,
    });
  }

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

/// An in-memory settings store: nothing here touches the real settings file.
class _FakeSettings extends SettingsStore {
  _FakeSettings({this.deviceUdid});

  String? deviceUdid;
  int saves = 0;

  @override
  String? loadDeviceUdid() => deviceUdid;

  @override
  void saveDeviceUdid(String? udid) {
    saves++;
    deviceUdid = udid;
  }
}

EngineResult _ok(Object data) => EngineResult(ok: true, data: data);

EngineResult _failed(String error) => EngineResult(ok: false, error: error);

/// One `devices` element, the shape usbmux reports it in.
Map<String, dynamic> _entry(String? serial, String? transport) =>
    <String, dynamic>{'serial': ?serial, 'connection_type': ?transport};

/// A `devices` payload built from `(serial, transport)` pairs, IN ORDER — the
/// per-transport listing the engine hands over.
EngineResult _listing(List<(String?, String?)> entries) => _ok(<dynamic>[
      for (final (String? serial, String? transport) in entries)
        _entry(serial, transport),
    ]);

List<DeviceEntry> _entries(List<(String?, String?)> pairs) => <DeviceEntry>[
      for (final (String? serial, String? transport) in pairs)
        DeviceEntry(serial: serial, connectionType: transport),
    ];

DeviceSelection _selection(_FakeRunner runner, {SettingsStore? settings}) {
  final DeviceSelection selection = DeviceSelection(
    engine: EngineApi(runner),
    settings: settings ?? _FakeSettings(),
  );
  addTearDown(selection.dispose);
  return selection;
}

void _connectionTests() {
  group('DeviceConnection', () {
    test('reads the engine wire words, defaulting to automatic', () {
      expect(DeviceConnection.fromWireName('usb'), DeviceConnection.usb);
      expect(DeviceConnection.fromWireName('wifi'), DeviceConnection.wifi);
      expect(DeviceConnection.fromWireName('auto'), DeviceConnection.auto);
      // Anything else, including a value a newer build wrote, reads as automatic
      // rather than leaving the app unable to reach the phone at all.
      expect(DeviceConnection.fromWireName(null), DeviceConnection.auto);
      expect(DeviceConnection.fromWireName('carrier-pigeon'), DeviceConnection.auto);
    });

    test('automatic sends no flag, because it is the engine default', () {
      // Emitting --connection auto would only be noise in the argv.
      expect(DeviceConnection.auto.wireName, 'auto');
      expect(DeviceConnection.usb.wireName, 'usb');
      expect(DeviceConnection.wifi.wireName, 'wifi');
    });
  });
}

void main() {
  _connectionTests();

  group('DeviceSelection.group', () {
    test('collapses one phone reachable two ways into a single device', () {
      // The exact shape of the bug: usbmux lists a plugged-in phone that is also
      // on Wi-Fi twice, under the same serial.
      final List<DeviceTarget> devices = DeviceSelection.group(
        _entries(<(String?, String?)>[
          ('AAAA1111', 'USB'),
          ('AAAA1111', 'Network'),
        ]),
      );

      expect(devices, hasLength(1));
      expect(devices.single.udid, 'AAAA1111');
      expect(devices.single.transports, <String>['USB', 'Network']);
      expect(devices.single.transportText, 'USB/Network');
    });

    test('keeps two distinct phones apart', () {
      final List<DeviceTarget> devices = DeviceSelection.group(
        _entries(<(String?, String?)>[
          ('AAAA1111', 'USB'),
          ('BBBB2222', 'USB'),
          ('AAAA1111', 'Network'),
        ]),
      );

      expect(
        devices.map((DeviceTarget d) => d.udid),
        <String>['AAAA1111', 'BBBB2222'],
        reason: 'devices keep the order they were first seen in',
      );
      expect(devices.first.transports, <String>['USB', 'Network']);
      expect(devices.last.transports, <String>['USB']);
    });

    test('puts USB first however usbmux ordered the transports', () {
      final List<DeviceTarget> devices = DeviceSelection.group(
        _entries(<(String?, String?)>[
          ('AAAA1111', 'Network'),
          ('AAAA1111', 'USB'),
        ]),
      );

      expect(devices.single.transports, <String>['USB', 'Network']);
    });

    test('de-duplicates a transport listed twice', () {
      final List<DeviceTarget> devices = DeviceSelection.group(
        _entries(<(String?, String?)>[
          ('AAAA1111', 'USB'),
          ('AAAA1111', 'USB'),
        ]),
      );

      expect(devices.single.transports, <String>['USB']);
    });

    test('drops an entry with no serial, which cannot be a target', () {
      final List<DeviceTarget> devices = DeviceSelection.group(
        _entries(<(String?, String?)>[(null, 'USB'), ('AAAA1111', 'USB')]),
      );

      expect(devices.map((DeviceTarget d) => d.udid), <String>['AAAA1111']);
    });

    test('keeps a device whose transport usbmux would not name', () {
      final List<DeviceTarget> devices = DeviceSelection.group(
        _entries(<(String?, String?)>[('AAAA1111', null)]),
      );

      expect(devices.single.udid, 'AAAA1111');
      expect(devices.single.transports, isEmpty);
      expect(devices.single.transportText, isEmpty);
    });

    test('an empty listing yields no devices', () {
      expect(DeviceSelection.group(const <DeviceEntry>[]), isEmpty);
    });
  });

  group('DeviceTarget labels', () {
    test('falls back to a shortened UDID when the name is unknown', () {
      const DeviceTarget device = DeviceTarget(
        udid: '935cbbb9b82d25d15566e5939bcea5677b1c44ae',
      );

      expect(device.shortUdid, '935cbbb9\u202644ae');
      expect(device.label, '935cbbb9\u202644ae');
    });

    test('leaves a short id alone rather than mangling it', () {
      const DeviceTarget device = DeviceTarget(udid: 'AAAA1111');

      expect(device.shortUdid, 'AAAA1111');
    });

    test('prefers the device name once it is known', () {
      const DeviceTarget device = DeviceTarget(
        udid: 'AAAA1111',
        name: "iOS_hAT's iPhone",
      );

      expect(device.label, "iOS_hAT's iPhone");
    });

    test('treats a blank name as no name', () {
      const DeviceTarget device = DeviceTarget(udid: 'AAAA1111', name: '');

      expect(device.label, 'AAAA1111');
    });
  });

  group('DeviceSelection with one device', () {
    test('selects it without asking, and offers no choice', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _listing(<(String?, String?)>[('AAAA1111', 'USB')]));
      final DeviceSelection selection = _selection(runner);

      await selection.refresh();

      expect(selection.selectedUdid, 'AAAA1111');
      expect(selection.hasDevices, isTrue);
      expect(
        selection.hasChoice,
        isFalse,
        reason: 'one option is not a choice worth a picker',
      );
      expect(selection.isEmpty, isFalse);
      expect(selection.hasError, isFalse);
    });

    test('does not persist an auto-selection', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _listing(<(String?, String?)>[('AAAA1111', 'USB')]));
      final _FakeSettings settings = _FakeSettings();

      await _selection(runner, settings: settings).refresh();

      expect(
        settings.saves,
        0,
        reason: 'only a choice the user made is worth remembering',
      );
    });

    test('names the device on a second pass', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _listing(<(String?, String?)>[('AAAA1111', 'USB')]))
        ..always(
          'device-info',
          _ok(<String, dynamic>{'DeviceName': "iOS_hAT's iPhone"}),
        );
      final DeviceSelection selection = _selection(runner);

      await selection.refresh();
      await pumpEventQueue();

      expect(selection.selected?.name, "iOS_hAT's iPhone");
      expect(
        runner.callsTo('device-info').single,
        <String>['device-info', '--udid', 'AAAA1111'],
        reason: 'the name pass asks about one specific device',
      );
    });

    test('keeps the UDID label when the name lookup fails', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _listing(<(String?, String?)>[('AAAA1111', 'USB')]))
        ..always('device-info', _failed('device is locked'));
      final DeviceSelection selection = _selection(runner);

      await selection.refresh();
      await pumpEventQueue();

      expect(selection.selected?.name, isNull);
      expect(selection.selected?.label, 'AAAA1111');
    });

    test('does not re-ask for a name it already has', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _listing(<(String?, String?)>[('AAAA1111', 'USB')]))
        ..always('device-info', _ok(<String, dynamic>{'DeviceName': 'Phone'}));
      final DeviceSelection selection = _selection(runner);

      await selection.refresh();
      await pumpEventQueue();
      await selection.refresh();
      await pumpEventQueue();

      expect(runner.callsTo('device-info'), hasLength(1));
      expect(selection.selected?.name, 'Phone');
    });
  });

  group('DeviceSelection with several devices', () {
    _FakeRunner twoDevices() => _FakeRunner()
      ..always(
        'devices',
        _listing(<(String?, String?)>[
          ('AAAA1111', 'USB'),
          ('BBBB2222', 'USB'),
        ]),
      );

    test('offers the choice and targets the first until one is made', () async {
      final DeviceSelection selection = _selection(twoDevices());

      await selection.refresh();

      expect(selection.devices, hasLength(2));
      expect(selection.hasChoice, isTrue);
      expect(
        selection.selectedUdid,
        'AAAA1111',
        reason: 'something has to be targeted, and the UI says which',
      );
    });

    test('switches target on select, and remembers it', () async {
      final _FakeSettings settings = _FakeSettings();
      final DeviceSelection selection =
          _selection(twoDevices(), settings: settings);
      await selection.refresh();

      var notifications = 0;
      selection.addListener(() => notifications++);
      selection.select('BBBB2222');

      expect(selection.selectedUdid, 'BBBB2222');
      expect(selection.selected?.udid, 'BBBB2222');
      expect(settings.deviceUdid, 'BBBB2222');
      expect(notifications, 1);
    });

    test('re-selecting the current target changes nothing', () async {
      final _FakeSettings settings = _FakeSettings();
      final DeviceSelection selection =
          _selection(twoDevices(), settings: settings);
      await selection.refresh();

      var notifications = 0;
      selection.addListener(() => notifications++);
      selection.select('AAAA1111');

      expect(notifications, 0);
      expect(settings.saves, 0);
    });

    test('ignores a device that is not connected', () async {
      final DeviceSelection selection = _selection(twoDevices());
      await selection.refresh();

      selection.select('CCCC3333');

      expect(
        selection.selectedUdid,
        'AAAA1111',
        reason: 'targeting an absent phone can only produce an engine error',
      );
    });

    test('a remembered device is targeted ahead of the first', () async {
      final DeviceSelection selection = _selection(
        twoDevices(),
        settings: _FakeSettings(deviceUdid: 'BBBB2222'),
      );

      await selection.refresh();

      expect(selection.selectedUdid, 'BBBB2222');
    });

    test('a remembered device that is not here does not apply', () async {
      final DeviceSelection selection = _selection(
        twoDevices(),
        settings: _FakeSettings(deviceUdid: 'ZZZZ9999'),
      );

      await selection.refresh();

      expect(selection.selectedUdid, 'AAAA1111');
    });

    test('names every device it did not already know', () async {
      final _FakeRunner runner = twoDevices()
        ..next('device-info', _ok(<String, dynamic>{'DeviceName': 'Mine'}))
        ..next('device-info', _ok(<String, dynamic>{'DeviceName': 'Spare'}));
      final DeviceSelection selection = _selection(runner);

      await selection.refresh();
      await pumpEventQueue();

      expect(
        selection.devices.map((DeviceTarget d) => d.label),
        <String>['Mine', 'Spare'],
      );
      expect(runner.callsTo('device-info'), <List<String>>[
        <String>['device-info', '--udid', 'AAAA1111'],
        <String>['device-info', '--udid', 'BBBB2222'],
      ]);
    });
  });

  group('DeviceSelection when a device disappears', () {
    test('retargets when the selected phone is unplugged', () async {
      final _FakeRunner runner = _FakeRunner()
        ..next(
          'devices',
          _listing(<(String?, String?)>[
            ('AAAA1111', 'USB'),
            ('BBBB2222', 'USB'),
          ]),
        )
        ..always('devices', _listing(<(String?, String?)>[('AAAA1111', 'USB')]));
      final _FakeSettings settings = _FakeSettings();
      final DeviceSelection selection =
          _selection(runner, settings: settings);

      await selection.refresh();
      selection.select('BBBB2222');
      await selection.refresh();

      expect(selection.selectedUdid, 'AAAA1111');
      expect(selection.selected?.udid, 'AAAA1111');
      expect(selection.hasChoice, isFalse);
      expect(
        settings.deviceUdid,
        'BBBB2222',
        reason: 'the preference survives the phone being unplugged',
      );
    });

    test('restores the remembered phone when it comes back', () async {
      final _FakeRunner runner = _FakeRunner()
        ..next(
          'devices',
          _listing(<(String?, String?)>[
            ('AAAA1111', 'USB'),
            ('BBBB2222', 'USB'),
          ]),
        )
        ..next('devices', _listing(<(String?, String?)>[('AAAA1111', 'USB')]))
        ..always(
          'devices',
          _listing(<(String?, String?)>[
            ('AAAA1111', 'USB'),
            ('BBBB2222', 'USB'),
          ]),
        );
      final DeviceSelection selection = _selection(runner);

      await selection.refresh();
      selection.select('BBBB2222');
      await selection.refresh(); // unplugged
      await selection.refresh(); // plugged back in

      expect(selection.selectedUdid, 'BBBB2222');
    });

    test('the last device going leaves no target and no crash', () async {
      final _FakeRunner runner = _FakeRunner()
        ..next('devices', _listing(<(String?, String?)>[('AAAA1111', 'USB')]))
        ..always('devices', _ok(<dynamic>[]));
      final DeviceSelection selection = _selection(runner);

      await selection.refresh();
      await selection.refresh();

      expect(selection.selectedUdid, isNull);
      expect(selection.selected, isNull);
      expect(selection.devices, isEmpty);
      expect(selection.hasDevices, isFalse);
      expect(selection.hasChoice, isFalse);
      expect(selection.isEmpty, isTrue);
    });

    test('a select against an empty list is ignored', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _ok(<dynamic>[]));
      final DeviceSelection selection = _selection(runner);
      await selection.refresh();

      selection.select('AAAA1111');

      expect(selection.selectedUdid, isNull);
    });
  });

  group('DeviceSelection failures', () {
    test('reports a cleaned failure and finishes loading', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _failed('usbmuxd is not running'));
      final DeviceSelection selection = _selection(runner);

      await selection.refresh();

      expect(selection.error, 'usbmuxd is not running');
      expect(selection.hasError, isTrue);
      expect(selection.isLoading, isFalse);
      expect(selection.hasLoaded, isTrue);
      expect(
        selection.isEmpty,
        isFalse,
        reason: 'a failure is not the same as no device',
      );
    });

    test('a later failure keeps the device it already found', () async {
      final _FakeRunner runner = _FakeRunner()
        ..next('devices', _listing(<(String?, String?)>[('AAAA1111', 'USB')]))
        ..always('devices', _failed('usbmuxd went away'));
      final DeviceSelection selection = _selection(runner);

      await selection.refresh();
      await selection.refresh();

      expect(
        selection.selectedUdid,
        'AAAA1111',
        reason: 'a transient hiccup must not retarget an install',
      );
      expect(selection.hasError, isTrue);
    });

    test('a shutdown leaves no error behind', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', EngineShutdownException());
      final DeviceSelection selection = _selection(runner);

      await selection.refresh();

      expect(selection.hasError, isFalse);
      expect(selection.selectedUdid, isNull);
    });

    test('a second refresh mid-flight is ignored', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _listing(<(String?, String?)>[('AAAA1111', 'USB')]));
      final DeviceSelection selection = _selection(runner);

      final Completer<void> gate = Completer<void>();
      runner.hold = gate;
      final Future<void> first = selection.refresh();
      await pumpEventQueue();
      expect(selection.isLoading, isTrue);

      await selection.refresh();
      gate.complete();
      await first;

      expect(runner.callsTo('devices'), hasLength(1));
    });

    test('nothing is claimed before the first refresh', () {
      final DeviceSelection selection = _selection(_FakeRunner());

      expect(selection.hasLoaded, isFalse);
      expect(selection.isLoading, isFalse);
      expect(selection.selectedUdid, isNull);
      expect(
        selection.isEmpty,
        isFalse,
        reason: 'not having looked yet is not the same as having found nothing',
      );
    });
  });

  // Screens are built and start loading before the enumeration comes back — Home
  // is, on every launch. A device-targeted call that goes out in that window
  // carries no UDID, which is exactly the call the engine refuses to answer once a
  // second phone is plugged in.
  group('DeviceSelection.targetUdid', () {
    test('enumerates on its own when nobody has yet', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _listing(<(String?, String?)>[('AAAA1111', 'USB')]));
      final DeviceSelection selection = _selection(runner);

      expect(await selection.targetUdid(), 'AAAA1111');
      expect(runner.callsTo('devices'), hasLength(1));
    });

    test('waits for an enumeration already in flight', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _listing(<(String?, String?)>[('AAAA1111', 'USB')]));
      final DeviceSelection selection = _selection(runner);

      final Completer<void> gate = Completer<void>();
      runner.hold = gate;
      final Future<void> refreshing = selection.refresh();
      final Future<String?> target = selection.targetUdid();
      await pumpEventQueue();

      gate.complete();
      await refreshing;

      expect(await target, 'AAAA1111');
      expect(
        runner.callsTo('devices'),
        hasLength(1),
        reason: 'the waiting caller must not start a second enumeration',
      );
    });

    test('answers immediately once it has settled', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _listing(<(String?, String?)>[('AAAA1111', 'USB')]));
      final DeviceSelection selection = _selection(runner);
      await selection.refresh();

      expect(await selection.targetUdid(), 'AAAA1111');
      expect(runner.callsTo('devices'), hasLength(1));
    });

    test('answers null rather than hanging when the listing fails', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _failed('usbmuxd is not running'));
      final DeviceSelection selection = _selection(runner);

      expect(await selection.targetUdid(), isNull);
    });

    test('answers null rather than hanging on a shutdown', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', EngineShutdownException());
      final DeviceSelection selection = _selection(runner);

      expect(await selection.targetUdid(), isNull);
    });

    test('follows a retarget', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'devices',
          _listing(<(String?, String?)>[
            ('AAAA1111', 'USB'),
            ('BBBB2222', 'USB'),
          ]),
        );
      final DeviceSelection selection = _selection(runner);
      await selection.refresh();

      expect(await selection.targetUdid(), 'AAAA1111');
      selection.select('BBBB2222');
      expect(await selection.targetUdid(), 'BBBB2222');
    });
  });

  group('DeviceSelection while the app stays open', () {
    test('picks up a phone plugged in after the first listing', () async {
      final _FakeRunner runner = _FakeRunner()
        ..next('devices', _listing(<(String?, String?)>[]))
        ..always(
          'devices',
          _listing(<(String?, String?)>[('AAAA1111', 'USB')]),
        );
      final DeviceSelection selection = _selection(runner);

      await selection.refresh();
      expect(selection.isEmpty, isTrue);

      await selection.refresh();

      expect(selection.selectedUdid, 'AAAA1111');
      expect(selection.isEmpty, isFalse);
    });

    test('an unchanged listing does not look like a retarget', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'devices',
          _listing(<(String?, String?)>[('AAAA1111', 'USB')]),
        );
      final DeviceSelection selection = _selection(runner);
      var notifications = 0;
      selection.addListener(() => notifications++);

      await selection.refresh();
      final int afterFirst = notifications;
      await selection.refresh();

      expect(
        notifications,
        afterFirst,
        reason: 'watching usbmux must not rebuild the UI every tick',
      );
    });

    test('an Attached event shows a phone plugged in after launch', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _listing(<(String?, String?)>[]));
      final DeviceSelection selection = _selection(runner);
      selection.startListening();
      await selection.refresh();
      expect(selection.isEmpty, isTrue);

      runner.emitDevices(<Map<String, dynamic>>[
        <String, dynamic>{'serial': 'AAAA1111', 'connection_type': 'USB'},
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(selection.selectedUdid, 'AAAA1111');
      expect(selection.isEmpty, isFalse);
      expect(
        runner.callsTo('devices'),
        hasLength(1),
        reason: 'hotplug must not poll devices()',
      );
    });

    test('a Detached event clears the phone', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'devices',
          _listing(<(String?, String?)>[('AAAA1111', 'USB')]),
        );
      final DeviceSelection selection = _selection(runner);
      selection.startListening();
      await selection.refresh();
      expect(selection.selectedUdid, 'AAAA1111');

      runner.emitDevices(const <Map<String, dynamic>>[]);
      await Future<void>.delayed(Duration.zero);

      expect(selection.selectedUdid, isNull);
      expect(selection.isEmpty, isTrue);
    });

    test('a racing devices RPC does not unplug a phone Listen already reported',
        () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _listing(<(String?, String?)>[]));
      final DeviceSelection selection = _selection(runner);
      selection.startListening();
      runner.emitDevices(<Map<String, dynamic>>[
        <String, dynamic>{'serial': 'AAAA1111', 'connection_type': 'USB'},
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(selection.selectedUdid, 'AAAA1111');

      await selection.refresh();

      expect(
        selection.selectedUdid,
        'AAAA1111',
        reason: 'the empty snapshot left before Attached must not win',
      );
    });

    test('dispose stops applying mux events', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('devices', _listing(<(String?, String?)>[]));
      final DeviceSelection selection = DeviceSelection(
        engine: EngineApi(runner),
        settings: _FakeSettings(),
      );
      selection.startListening();
      await selection.refresh();
      selection.dispose();

      runner.emitDevices(<Map<String, dynamic>>[
        <String, dynamic>{'serial': 'AAAA1111', 'connection_type': 'USB'},
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(selection.selectedUdid, isNull);
    });
  });
}
