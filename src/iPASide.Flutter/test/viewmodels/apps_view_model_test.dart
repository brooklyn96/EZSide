import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine.dart';
import 'package:ipaside/services/icon_cache.dart';
import 'package:ipaside/services/settings_store.dart';
import 'package:ipaside/ui/shell/app_dialogs.dart';
import 'package:ipaside/viewmodels/apps_view_model.dart';
import 'package:ipaside/viewmodels/device_selection.dart';

/// A transport stand-in scripted per engine command: it records every argv and
/// replays canned result frames (or throws a canned error).
class _FakeRunner with EngineCommandRunner {
  final Map<String, Queue<Object>> _scripted = <String, Queue<Object>>{};
  final Map<String, Object> _defaults = <String, Object>{};

  /// Every argv the facade issued, in order.
  final List<List<String>> calls = <List<String>>[];

  /// Parks each answer until completed, so a mid-flight state can be asserted.
  Completer<void>? hold;

  /// Answers every unscripted call of [command] with [outcome].
  void always(String command, Object outcome) => _defaults[command] = outcome;

  /// Answers the next call of [command] with [outcome], before any [always].
  void next(String command, Object outcome) =>
      (_scripted[command] ??= Queue<Object>()).add(outcome);

  List<List<String>> callsTo(String command) =>
      <List<String>>[for (final List<String> argv in calls) if (argv.first == command) argv];

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
    if (outcome is EngineResult) {
      return outcome;
    }
    throw outcome;
  }
}

typedef _ConfirmCall = ({
  String title,
  String message,
  String confirmLabel,
  String cancelLabel,
  bool danger,
});

typedef _AlertCall = ({String title, String message});

/// Records what the view model asked the user and answers without a navigator.
class _FakeDialogs extends DialogService {
  _FakeDialogs() : super(GlobalKey<NavigatorState>());

  /// What [confirm] returns.
  bool answer = true;

  final List<_ConfirmCall> confirms = <_ConfirmCall>[];
  final List<_AlertCall> alerts = <_AlertCall>[];

  @override
  Future<bool> confirm({
    required String title,
    required String message,
    String confirmLabel = 'OK',
    String cancelLabel = 'Cancel',
    bool danger = false,
  }) async {
    confirms.add((
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      danger: danger,
    ));
    return answer;
  }

  @override
  Future<void> alert({required String title, required String message}) async {
    alerts.add((title: title, message: message));
  }
}

EngineResult _ok(Object data) => EngineResult(ok: true, data: data);

EngineResult _failed(String error) => EngineResult(ok: false, error: error);

Map<String, dynamic> _app({String? name, String? version}) => <String, dynamic>{
      'name': ?name,
      'version': ?version,
    };

/// An in-memory settings store, so no test touches the real settings file.
class _FakeSettings extends SettingsStore {
  String? deviceUdid;

  @override
  String? loadDeviceUdid() => deviceUdid;

  @override
  void saveDeviceUdid(String? udid) => deviceUdid = udid;
}

/// A selection that has enumerated nothing, so it names no target — which is what
/// a single-device machine looks like to the engine.
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

const String _first = 'AAAA1111';
const String _second = 'CCCC3333';

/// A selection over two phones, already resolved to [_first].
///
/// Its own runner, so the enumeration and name lookups never land in the call
/// list a test is asserting the view model made.
Future<DeviceSelection> _twoDevices() async {
  final _FakeRunner runner = _FakeRunner()
    ..always(
      'devices',
      _ok(<dynamic>[
        <String, dynamic>{'serial': _first, 'connection_type': 'USB'},
        <String, dynamic>{'serial': _second, 'connection_type': 'USB'},
      ]),
    )
    ..always('device-info', _ok(<String, dynamic>{'DeviceName': 'A phone'}));

  final DeviceSelection selection = DeviceSelection(
    engine: EngineApi(runner),
    settings: _FakeSettings(),
  );
  addTearDown(selection.dispose);
  await selection.refresh();
  await pumpEventQueue();
  return selection;
}

Future<AppsViewModel> _loaded(
  _FakeRunner runner,
  _FakeDialogs dialogs, {
  DeviceSelection? devices,
}) async {
  final AppsViewModel vm = AppsViewModel(
    engine: EngineApi(runner),
    dialogs: dialogs,
    icons: IconCache(),
    devices: devices ?? _noDevice(),
  );
  addTearDown(vm.dispose);
  await pumpEventQueue();
  return vm;
}

void main() {
  group('AppsViewModel load', () {
    test('reads apps on creation', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'apps',
          _ok(<String, dynamic>{
            'com.example.app': _app(name: 'Example', version: '1.2'),
          }),
        );

      final AppsViewModel vm = await _loaded(runner, _FakeDialogs());

      // The inventory comes first; icons follow as a separate pass so the list
      // is not held up by SpringBoard's one-round-trip-per-icon fetch.
      expect(runner.calls.first, <String>['apps']);
      expect(runner.calls.last, <String>['app-icons']);
      expect(vm.isLoading, isFalse);
      expect(vm.hasError, isFalse);
      expect(vm.isEmpty, isFalse);
      expect(vm.rows.single.bundleId, 'com.example.app');
      expect(vm.rows.single.name, 'Example');
    });

    test('sorts by display name, folding case and falling back to the bundle id',
        () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'apps',
          _ok(<String, dynamic>{
            'com.zed.app': _app(name: 'apple'),
            'com.a.app': _app(name: 'Banana'),
            'com.m.app': _app(),
            'com.b.app': _app(name: 'cherry'),
            'com.z.notes': _app(name: 'Notes'),
            'com.a.notes': _app(name: 'Notes'),
          }),
        );

      final AppsViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(
        vm.rows.map((AppRow row) => row.bundleId).toList(),
        <String>[
          'com.zed.app', // apple
          'com.a.app', // Banana - case never reorders
          'com.b.app', // cherry
          'com.m.app', // nameless, sorted under its bundle id
          'com.a.notes', // same name; the bundle id breaks the tie
          'com.z.notes',
        ],
      );
    });

    test('a nameless app falls back to its bundle id', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'apps',
          _ok(<String, dynamic>{
            'com.blank': _app(name: ''),
            'com.missing': _app(),
          }),
        );

      final AppsViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(
        vm.rows.map((AppRow row) => row.name).toList(),
        <String>['com.blank', 'com.missing'],
      );
    });

    test('the subtitle carries the version only when there is one', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'apps',
          _ok(<String, dynamic>{
            'com.a': _app(name: 'A', version: '439.0.0'),
            'com.b': _app(name: 'B'),
            'com.c': _app(name: 'C', version: ''),
          }),
        );

      final AppsViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(
        vm.rows.map((AppRow row) => row.subtitle).toList(),
        <String>['com.a \u00B7 439.0.0', 'com.b', 'com.c'],
      );
    });

    test('an empty device shows the empty state', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('apps', _ok(<String, dynamic>{}));

      final AppsViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(vm.rows, isEmpty);
      expect(vm.isEmpty, isTrue);
      expect(vm.hasError, isFalse);
      expect(vm.isLoading, isFalse);
    });

    test('a failed load surfaces the cleaned error and clears the rows', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('apps', _failed('Engine exited with code 1. no device found'));

      final AppsViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(vm.error, 'no device found');
      expect(vm.hasError, isTrue);
      expect(vm.rows, isEmpty);
      expect(vm.isEmpty, isFalse, reason: 'a failure is not an empty device');
      expect(vm.isLoading, isFalse);
    });

    test('a shutdown during the load leaves the view untouched', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('apps', EngineShutdownException());

      final AppsViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(vm.hasError, isFalse);
      expect(vm.rows, isEmpty);
      expect(vm.isEmpty, isFalse);
      expect(vm.isLoading, isFalse);
    });
  });

  group('AppsViewModel uninstall', () {
    test('confirms with the app name, then uninstalls and reloads', () async {
      final _FakeRunner runner = _FakeRunner()
        ..next(
          'apps',
          _ok(<String, dynamic>{'com.example.app': _app(name: 'Example')}),
        )
        ..always('apps', _ok(<String, dynamic>{}));
      final _FakeDialogs dialogs = _FakeDialogs();
      final AppsViewModel vm = await _loaded(runner, dialogs);

      await vm.uninstallRow(vm.rows.single);

      expect(dialogs.confirms.single, (
        title: 'Uninstall app',
        message: 'Uninstall Example from your iPhone?',
        confirmLabel: 'Uninstall',
        cancelLabel: 'Cancel',
        danger: true,
      ));
      expect(
        runner.callsTo('uninstall').single,
        <String>['uninstall', 'com.example.app'],
      );
      expect(runner.callsTo('apps'), hasLength(2));
      expect(dialogs.alerts, isEmpty);
      expect(vm.rows, isEmpty, reason: 'the reload picked up the uninstall');
      expect(vm.isEmpty, isTrue);
    });

    test('a declined confirm touches nothing', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('apps', _ok(<String, dynamic>{'com.a': _app(name: 'A')}));
      final _FakeDialogs dialogs = _FakeDialogs()..answer = false;
      final AppsViewModel vm = await _loaded(runner, dialogs);

      await vm.uninstallRow(vm.rows.single);

      expect(runner.callsTo('uninstall'), isEmpty);
      expect(runner.callsTo('apps'), hasLength(1));
      expect(vm.rows.single.isRemoving, isFalse);
    });

    test('a failed uninstall restores the button and raises no dialog', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('apps', _ok(<String, dynamic>{'com.a': _app(name: 'A')}))
        ..always('uninstall', _failed('device is locked'));
      final _FakeDialogs dialogs = _FakeDialogs();
      final AppsViewModel vm = await _loaded(runner, dialogs);

      final AppRow row = vm.rows.single;
      await vm.uninstallRow(row);

      expect(row.isRemoving, isFalse);
      expect(dialogs.alerts, isEmpty);
      expect(
        runner.callsTo('apps'),
        hasLength(1),
        reason: 'a failed uninstall does not reload',
      );
      expect(vm.rows.single, same(row));
    });

    test('a shutdown mid-uninstall skips the reload', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('apps', _ok(<String, dynamic>{'com.a': _app(name: 'A')}))
        ..always('uninstall', EngineShutdownException());
      final _FakeDialogs dialogs = _FakeDialogs();
      final AppsViewModel vm = await _loaded(runner, dialogs);

      await vm.uninstallRow(vm.rows.single);

      expect(runner.callsTo('apps'), hasLength(1));
      expect(dialogs.alerts, isEmpty);
    });

    test('a busy row leaves its siblings interactive', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'apps',
          _ok(<String, dynamic>{
            'com.a': _app(name: 'A'),
            'com.b': _app(name: 'B'),
          }),
        );
      final AppsViewModel vm = await _loaded(runner, _FakeDialogs());

      final Completer<void> gate = Completer<void>();
      runner.hold = gate;

      final AppRow first = vm.rows.first;
      final AppRow second = vm.rows.last;
      final Future<void> running = vm.uninstallRow(first);
      await pumpEventQueue();

      expect(first.isRemoving, isTrue);
      expect(second.isRemoving, isFalse, reason: 'the other row stays usable');

      gate.complete();
      await running;

      expect(runner.callsTo('uninstall'), hasLength(1));
      expect(runner.callsTo('apps'), hasLength(2));
    });

    test('ignores a second press while the uninstall is in flight', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('apps', _ok(<String, dynamic>{'com.a': _app(name: 'A')}));
      final _FakeDialogs dialogs = _FakeDialogs();
      final AppsViewModel vm = await _loaded(runner, dialogs);

      final Completer<void> gate = Completer<void>();
      runner.hold = gate;

      final AppRow row = vm.rows.single;
      final Future<void> running = vm.uninstallRow(row);
      await pumpEventQueue();
      expect(row.isRemoving, isTrue);

      await vm.uninstallRow(row);
      gate.complete();
      await running;

      expect(runner.callsTo('uninstall'), hasLength(1));
      expect(dialogs.confirms, hasLength(1));
    });
  });

  // Every call this screen makes is device-targeted, so all three carry the
  // selected UDID; without it the engine picks for itself, and refuses to pick at
  // all once a second phone is plugged in.
  group('AppsViewModel device target', () {
    test('sends no --udid when nothing is selected', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('apps', _ok(<String, dynamic>{'com.a': _app(name: 'A')}))
        ..always('app-icons', _ok(<String, dynamic>{}));

      await _loaded(runner, _FakeDialogs());

      expect(runner.callsTo('apps').single, <String>['apps']);
      expect(runner.callsTo('app-icons').single, <String>['app-icons']);
    });

    test('targets the selected device on both load passes', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('apps', _ok(<String, dynamic>{'com.a': _app(name: 'A')}))
        ..always('app-icons', _ok(<String, dynamic>{}));

      await _loaded(runner, _FakeDialogs(), devices: await _device('BBBB2222'));

      expect(
        runner.callsTo('apps').single,
        <String>['apps', '--udid', 'BBBB2222'],
      );
      expect(
        runner.callsTo('app-icons').single,
        <String>['app-icons', '--udid', 'BBBB2222'],
      );
    });

    test('uninstalls from the selected device', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('apps', _ok(<String, dynamic>{'com.a': _app(name: 'A')}));
      final AppsViewModel vm = await _loaded(
        runner,
        _FakeDialogs(),
        devices: await _device('BBBB2222'),
      );

      await vm.uninstallRow(vm.rows.single);

      expect(
        runner.callsTo('uninstall').single,
        <String>['uninstall', 'com.a', '--udid', 'BBBB2222'],
      );
    });

    test('reloads when the selection moves to another phone', () async {
      // Otherwise one phone's apps sit on screen under another phone's name, and
      // the Uninstall beside each of them would be aimed at the new one.
      final _FakeRunner runner = _FakeRunner()
        ..next('apps', _ok(<String, dynamic>{'com.a': _app(name: 'On the first')}))
        ..always('app-icons', _ok(<String, dynamic>{}))
        ..next('apps', _ok(<String, dynamic>{'com.b': _app(name: 'On the second')}));

      final DeviceSelection devices = await _twoDevices();
      final AppsViewModel vm = await _loaded(runner, _FakeDialogs(), devices: devices);
      expect(vm.rows.single.name, 'On the first');

      devices.select(_second);
      await pumpEventQueue();

      expect(vm.rows.single.name, 'On the second');
      expect(
        runner.callsTo('apps').last,
        <String>['apps', '--udid', _second],
        reason: 'the reload has to name the newly selected phone',
      );
    });

    test('empties the list while the new phone is being read', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('apps', _ok(<String, dynamic>{'com.a': _app(name: 'A')}))
        ..always('app-icons', _ok(<String, dynamic>{}));

      final DeviceSelection devices = await _twoDevices();
      final AppsViewModel vm = await _loaded(runner, _FakeDialogs(), devices: devices);

      runner.hold = Completer<void>();
      devices.select(_second);
      await pumpEventQueue();

      expect(vm.isLoading, isTrue);
      expect(vm.rows, isEmpty, reason: 'the old phone\'s apps must not linger');

      runner.hold!.complete();
      runner.hold = null;
      await pumpEventQueue();
      expect(vm.rows, hasLength(1));
    });

    test('a notification that retargets nothing does not reload', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('apps', _ok(<String, dynamic>{'com.a': _app(name: 'A')}))
        ..always('app-icons', _ok(<String, dynamic>{}));

      final DeviceSelection devices = await _twoDevices();
      await _loaded(runner, _FakeDialogs(), devices: devices);
      final int after = runner.callsTo('apps').length;

      await devices.refresh();
      await pumpEventQueue();
      devices.select(_first); // already selected
      await pumpEventQueue();

      expect(runner.callsTo('apps'), hasLength(after));
    });

    test('stops following the selection once disposed', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('apps', _ok(<String, dynamic>{'com.a': _app(name: 'A')}))
        ..always('app-icons', _ok(<String, dynamic>{}));

      final DeviceSelection devices = await _twoDevices();
      final AppsViewModel vm = AppsViewModel(
        engine: EngineApi(runner),
        dialogs: _FakeDialogs(),
        icons: IconCache(),
        devices: devices,
      );
      await pumpEventQueue();
      final int before = runner.calls.length;

      vm.dispose();
      devices.select(_second);
      await pumpEventQueue();

      expect(runner.calls, hasLength(before));
    });
  });
}
