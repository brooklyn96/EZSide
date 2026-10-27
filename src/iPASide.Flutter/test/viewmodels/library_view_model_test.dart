import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine.dart';
import 'package:ipaside/services/icon_cache.dart';
import 'package:ipaside/services/settings_store.dart';
import 'package:ipaside/ui/shell/app_dialogs.dart';
import 'package:ipaside/ui/widgets/surfaces.dart';
import 'package:ipaside/viewmodels/device_selection.dart';
import 'package:ipaside/viewmodels/library_view_model.dart';
import 'package:ipaside/viewmodels/sideload_progress_state.dart';

/// A transport stand-in scripted per engine command: it records every argv,
/// replays canned result frames (or throws a canned error), and can emit
/// progress lines before answering.
class _FakeRunner with EngineCommandRunner {
  final Map<String, Queue<Object>> _scripted = <String, Queue<Object>>{};
  final Map<String, Object> _defaults = <String, Object>{};
  final Map<String, List<String>> _progress = <String, List<String>>{};

  /// Every argv the facade issued, in order.
  final List<List<String>> calls = <List<String>>[];

  /// Parks each answer until completed, so a mid-flight state can be asserted.
  Completer<void>? hold;

  /// Answers every unscripted call of [command] with [outcome].
  void always(String command, Object outcome) => _defaults[command] = outcome;

  /// Answers the next call of [command] with [outcome], before any [always].
  void next(String command, Object outcome) =>
      (_scripted[command] ??= Queue<Object>()).add(outcome);

  /// Emits [lines] to the progress callback of every [command] call.
  void progressOn(String command, List<String> lines) =>
      _progress[command] = lines;

  List<List<String>> callsTo(String command) =>
      <List<String>>[for (final List<String> argv in calls) if (argv.first == command) argv];

  @override
  Future<EngineResult> run(
    List<String> args, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  }) async {
    calls.add(args);
    final String command = args.first;
    for (final String line in _progress[command] ?? const <String>[]) {
      onProgress?.call(line);
    }

    await hold?.future;

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

Map<String, dynamic> _record({
  required String bundleId,
  String? name,
  String? icon,
  double? daysLeft,
  bool expired = false,
  List<String>? dylibs,
  String? udid,
}) =>
    <String, dynamic>{
      'bundle_id': bundleId,
      'name': ?name,
      'icon': ?icon,
      'days_left': ?daysLeft,
      'expired': expired,
      'udid': ?udid,
      if (dylibs != null) 'options': <String, dynamic>{'dylibs': dylibs},
    };

Map<String, dynamic> _entry(String bundleId, String status, {String? error}) =>
    <String, dynamic>{
      'bundle_id': bundleId,
      'status': status,
      'error': ?error,
    };

Map<String, dynamic> _summary(List<Map<String, dynamic>> entries) =>
    <String, dynamic>{'refreshed': entries};

/// A 1x1 PNG, enough for the icon cache to accept the payload.
const String _pngIcon = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAA'
    'ABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// An in-memory settings store: nothing here touches the real settings file, and
/// a test can change a value between two calls to prove the model rereads it.
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

/// A selection already resolved to [udid].
///
/// Built over its OWN transport so the device enumeration never lands in the call
/// list the test is asserting on.
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

Future<LibraryViewModel> _loaded(
  _FakeRunner runner,
  _FakeDialogs dialogs, {
  SettingsStore? settings,
  DeviceSelection? devices,
}) async {
  final LibraryViewModel vm = LibraryViewModel(
    engine: EngineApi(runner),
    dialogs: dialogs,
    icons: IconCache(),
    settings: settings ?? _FakeSettings(),
    devices: devices ?? _noDevice(),
  );
  addTearDown(vm.dispose);
  await pumpEventQueue();
  return vm;
}

void main() {
  group('LibraryViewModel load', () {
    test('reads installs on creation', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'installs',
          _ok(<dynamic>[_record(bundleId: 'com.example.app', name: 'Example')]),
        );

      final LibraryViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(runner.calls.single, <String>['installs']);
      expect(vm.isLoading, isFalse);
      expect(vm.hasError, isFalse);
      expect(vm.hasItems, isTrue);
      expect(vm.isEmpty, isFalse);
      expect(vm.rows.single.name, 'Example');
      expect(vm.rows.single.bundleId, 'com.example.app');
    });

    test('a record without tweaks shows only its bundle id', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.example.app')]));

      final LibraryViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(vm.rows.single.subtitle, 'com.example.app');
    });

    test('a record with tweaks appends the count, pluralised', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'installs',
          _ok(<dynamic>[
            _record(bundleId: 'com.one', dylibs: <String>['/a.dylib']),
            _record(bundleId: 'com.two', dylibs: <String>['/a.dylib', '/b.dylib']),
            _record(bundleId: 'com.none', dylibs: <String>[]),
          ]),
        );

      final LibraryViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(
        vm.rows.map((LibraryRow row) => row.subtitle).toList(),
        <String>[
          'com.one \u00B7 1 tweak',
          'com.two \u00B7 2 tweaks',
          'com.none',
        ],
      );
    });

    test('a nameless record falls back to its bundle id', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'installs',
          _ok(<dynamic>[
            _record(bundleId: 'com.blank', name: ''),
            _record(bundleId: 'com.missing'),
          ]),
        );

      final LibraryViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(
        vm.rows.map((LibraryRow row) => row.name).toList(),
        <String>['com.blank', 'com.missing'],
      );
    });

    test('maps every expiry level onto a pill', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'installs',
          _ok(<dynamic>[
            _record(bundleId: 'com.expired', expired: true, daysLeft: 4),
            _record(bundleId: 'com.unknown'),
            _record(bundleId: 'com.hours', daysLeft: 0.5),
            _record(bundleId: 'com.one', daysLeft: 1.4),
            _record(bundleId: 'com.two', daysLeft: 2),
            _record(bundleId: 'com.plenty', daysLeft: 6.9),
          ]),
        );

      final LibraryViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(
        vm.rows.map((LibraryRow row) => (row.pillText, row.pillKind)).toList(),
        <(String, PillKind)>[
          ('Expired', PillKind.danger),
          ('unknown', PillKind.neutral),
          ('under a day', PillKind.warn),
          ('1 day left', PillKind.warn),
          ('2 days left', PillKind.warn),
          ('6 days left', PillKind.ok),
        ],
      );
    });

    test('decodes the recorded icon, leaving rows without one null', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'installs',
          _ok(<dynamic>[
            _record(bundleId: 'com.icon', icon: _pngIcon),
            _record(bundleId: 'com.plain'),
          ]),
        );

      final LibraryViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(vm.rows.first.iconBytes, isNotNull);
      expect(vm.rows.last.iconBytes, isNull);
    });

    test('an empty library hides the toolbar and shows the empty state', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[]));

      final LibraryViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(vm.rows, isEmpty);
      expect(vm.isEmpty, isTrue);
      expect(vm.hasItems, isFalse);
      expect(vm.hasError, isFalse);
      expect(vm.isLoading, isFalse);
    });

    test('a failed load surfaces the cleaned error and clears the rows', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _failed('Engine exited with code 1. device is locked'));

      final LibraryViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(vm.error, 'device is locked');
      expect(vm.hasError, isTrue);
      expect(vm.rows, isEmpty);
      expect(vm.hasItems, isFalse);
      expect(vm.isEmpty, isFalse, reason: 'a failure is not an empty library');
      expect(vm.isLoading, isFalse);
    });

    test('a shutdown during the load leaves the view untouched', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', EngineShutdownException());

      final LibraryViewModel vm = await _loaded(runner, _FakeDialogs());

      expect(vm.hasError, isFalse);
      expect(vm.rows, isEmpty);
      expect(vm.isEmpty, isFalse);
      expect(vm.isLoading, isFalse);
    });
  });

  group('LibraryViewModel refresh all', () {
    test('names every app the engine could not refresh', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.a')]))
        ..always(
          'refresh',
          _ok(_summary(<Map<String, dynamic>>[
            _entry('com.a', 'refreshed'),
            _entry('com.b', 'error', error: 'no device'),
            _entry('com.c', 'error', error: 'profile expired'),
          ])),
        );
      final _FakeDialogs dialogs = _FakeDialogs();
      final LibraryViewModel vm = await _loaded(runner, dialogs);

      await vm.refreshAll();

      expect(runner.callsTo('refresh').single, <String>['refresh', '--all']);
      expect(
        dialogs.alerts.single,
        (title: "2 app(s) couldn't be refreshed", message: 'com.b, com.c'),
      );
      expect(vm.isRefreshingAll, isFalse);
      expect(
        runner.callsTo('installs'),
        hasLength(2),
        reason: 'the library is reloaded after the run',
      );
    });

    test('stays silent when every app succeeded', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.a')]))
        ..always(
          'refresh',
          _ok(_summary(<Map<String, dynamic>>[
            _entry('com.a', 'refreshed'),
            _entry('com.b', 'skipped'),
          ])),
        );
      final _FakeDialogs dialogs = _FakeDialogs();
      final LibraryViewModel vm = await _loaded(runner, dialogs);

      await vm.refreshAll();

      expect(dialogs.alerts, isEmpty);
      expect(runner.callsTo('installs'), hasLength(2));
    });

    test('reports a failed run and still reloads', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.a')]))
        ..always('refresh', _failed('Engine exited with code 1. device is locked'));
      final _FakeDialogs dialogs = _FakeDialogs();
      final LibraryViewModel vm = await _loaded(runner, dialogs);

      await vm.refreshAll();

      expect(
        dialogs.alerts.single,
        (title: 'Refresh failed', message: 'device is locked'),
      );
      expect(vm.isRefreshingAll, isFalse);
      expect(runner.callsTo('installs'), hasLength(2));
    });

    test('skips the reload while the app is closing', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.a')]))
        ..always('refresh', EngineShutdownException());
      final _FakeDialogs dialogs = _FakeDialogs();
      final LibraryViewModel vm = await _loaded(runner, dialogs);

      await vm.refreshAll();

      expect(dialogs.alerts, isEmpty);
      expect(vm.isRefreshingAll, isFalse);
      expect(runner.callsTo('installs'), hasLength(1));
    });

    test('ignores a second press while the run is in flight', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.a')]))
        ..always('refresh', _ok(_summary(<Map<String, dynamic>>[])));
      final LibraryViewModel vm = await _loaded(runner, _FakeDialogs());

      final Completer<void> gate = Completer<void>();
      runner.hold = gate;

      final Future<void> running = vm.refreshAll();
      await pumpEventQueue();
      expect(vm.isRefreshingAll, isTrue);

      await vm.refreshAll();
      gate.complete();
      await running;

      expect(runner.callsTo('refresh'), hasLength(1));
    });
  });

  group('LibraryViewModel row refresh', () {
    test('targets one bundle id and reloads', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.example.app')]))
        ..always('refresh', _ok(_summary(<Map<String, dynamic>>[])));
      final _FakeDialogs dialogs = _FakeDialogs();
      final LibraryViewModel vm = await _loaded(runner, dialogs);

      await vm.refreshRow(vm.rows.single);

      expect(
        runner.callsTo('refresh').single,
        <String>['refresh', '--bundle-id', 'com.example.app'],
      );
      expect(dialogs.alerts, isEmpty);
      expect(runner.callsTo('installs'), hasLength(2));
      expect(vm.rows.single.isRefreshing, isFalse);
    });

    test('publishes the live step text into the row', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.a')]))
        ..always(
          'refresh',
          _ok(_summary(<Map<String, dynamic>>[_entry('com.a', 'refreshed')])),
        )
        ..progressOn('refresh', <String>[
          '{"event":"progress","phase":"provision","step":"Contacting Apple\u2026"}',
          'plain stderr chatter',
          '{"event":"progress","phase":"sign","step":"Signing\u2026"}',
          '{"event":"progress","phase":"install","percent":100}',
        ]);
      final LibraryViewModel vm = await _loaded(runner, _FakeDialogs());

      // The reload swaps the row out, but the instance that ran keeps the last
      // state it was told about.
      final LibraryRow row = vm.rows.single;
      await vm.refreshRow(row);

      // The last frame is install at 100% with no step of its own, so the row
      // reads the phase rather than the stale "Signing…" it used to be left on.
      expect(row.progress.activeIndex, 2);
      expect(row.refreshStepText, 'Installing\u2026');
      expect(row.progress.percent, 100);
      expect(row.progress.isIndeterminate, isFalse);
    });

    test('treats an error entry inside an ok result as a failure', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.a')]))
        ..always(
          'refresh',
          _ok(_summary(<Map<String, dynamic>>[
            _entry('com.a', 'error', error: 'Sideload failed: no device'),
          ])),
        );
      final _FakeDialogs dialogs = _FakeDialogs();
      final LibraryViewModel vm = await _loaded(runner, dialogs);

      final LibraryRow row = vm.rows.single;
      await vm.refreshRow(row);

      expect(
        dialogs.alerts.single,
        (title: 'Refresh failed', message: 'no device'),
      );
      expect(row.isRefreshing, isFalse, reason: 'the button is restored');
      expect(
        runner.callsTo('installs'),
        hasLength(1),
        reason: 'a failed refresh does not reload',
      );
      expect(vm.rows.single, same(row));
    });

    test('falls back to a generic message when the entry carries none', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.a')]))
        ..always(
          'refresh',
          _ok(_summary(<Map<String, dynamic>>[_entry('com.a', 'error')])),
        );
      final _FakeDialogs dialogs = _FakeDialogs();
      final LibraryViewModel vm = await _loaded(runner, dialogs);

      await vm.refreshRow(vm.rows.single);

      expect(
        dialogs.alerts.single,
        (title: 'Refresh failed', message: 'refresh failed'),
      );
    });

    test('a busy row leaves its siblings interactive', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'installs',
          _ok(<dynamic>[_record(bundleId: 'com.a'), _record(bundleId: 'com.b')]),
        )
        ..always(
          'refresh',
          _ok(_summary(<Map<String, dynamic>>[_entry('com.a', 'refreshed')])),
        );
      final LibraryViewModel vm = await _loaded(runner, _FakeDialogs());

      final Completer<void> gate = Completer<void>();
      runner.hold = gate;

      final LibraryRow first = vm.rows.first;
      final LibraryRow second = vm.rows.last;
      final Future<void> running = vm.refreshRow(first);
      await pumpEventQueue();

      expect(first.isRefreshing, isTrue);
      expect(first.isBusy, isTrue);
      expect(second.isBusy, isFalse, reason: 'the other row stays usable');

      gate.complete();
      await running;

      expect(runner.callsTo('refresh'), hasLength(1));
      expect(runner.callsTo('installs'), hasLength(2));
    });
  });

  group('LibraryViewModel row removal', () {
    test('confirms, uninstalls, forgets and reloads', () async {
      final _FakeRunner runner = _FakeRunner()
        ..next('installs', _ok(<dynamic>[_record(bundleId: 'com.example.app')]))
        ..always('installs', _ok(<dynamic>[]));
      final _FakeDialogs dialogs = _FakeDialogs();
      final LibraryViewModel vm = await _loaded(runner, dialogs);

      await vm.removeRow(vm.rows.single);

      expect(dialogs.confirms.single, (
        title: 'Remove from library',
        message: 'This removes the app from your library and uninstalls it '
            "from your iPhone if it's connected.",
        confirmLabel: 'Remove',
        cancelLabel: 'Cancel',
        danger: true,
      ));
      expect(
        runner.callsTo('uninstall').single,
        <String>['uninstall', 'com.example.app'],
      );
      expect(
        runner.callsTo('forget').single,
        <String>['forget', 'com.example.app'],
      );
      expect(runner.callsTo('installs'), hasLength(2));
      expect(dialogs.alerts, isEmpty);
      expect(vm.rows, isEmpty, reason: 'the reload picked up the removal');
      expect(vm.isEmpty, isTrue);
      expect(vm.hasItems, isFalse);
    });

    test('a declined confirm touches nothing', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.a')]));
      final _FakeDialogs dialogs = _FakeDialogs()..answer = false;
      final LibraryViewModel vm = await _loaded(runner, dialogs);

      await vm.removeRow(vm.rows.single);

      expect(runner.callsTo('uninstall'), isEmpty);
      expect(runner.callsTo('forget'), isEmpty);
      expect(runner.callsTo('installs'), hasLength(1));
      expect(vm.rows.single.isRemoving, isFalse);
    });

    test('forgets the app even when the device uninstall fails', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.a')]))
        ..always('uninstall', _failed('device is not connected'));
      final _FakeDialogs dialogs = _FakeDialogs();
      final LibraryViewModel vm = await _loaded(runner, dialogs);

      await vm.removeRow(vm.rows.single);

      expect(runner.callsTo('forget').single, <String>['forget', 'com.a']);
      expect(runner.callsTo('installs'), hasLength(2));
      expect(
        dialogs.alerts,
        isEmpty,
        reason: 'removal is best-effort and never reports',
      );
    });

    test('reloads even when forgetting fails', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.a')]))
        ..always('forget', _failed('registry is read-only'));
      final _FakeDialogs dialogs = _FakeDialogs();
      final LibraryViewModel vm = await _loaded(runner, dialogs);

      await vm.removeRow(vm.rows.single);

      expect(runner.callsTo('installs'), hasLength(2));
      expect(dialogs.alerts, isEmpty);
    });

    test('a shutdown mid-removal skips the reload', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.a')]))
        ..always('uninstall', EngineShutdownException());
      final _FakeDialogs dialogs = _FakeDialogs();
      final LibraryViewModel vm = await _loaded(runner, dialogs);

      await vm.removeRow(vm.rows.single);

      expect(runner.callsTo('forget'), isEmpty);
      expect(runner.callsTo('installs'), hasLength(1));
      expect(dialogs.alerts, isEmpty);
    });

    test('uninstalls from the device the app was installed onto', () async {
      // Not the selected one. Retargeting to a second phone and then removing a
      // row must not uninstall the app from that phone.
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'installs',
          _ok(<dynamic>[_record(bundleId: 'com.a', udid: 'RECORDED0000')]),
        );
      final LibraryViewModel vm = await _loaded(
        runner,
        _FakeDialogs(),
        devices: await _device('SELECTED1111'),
      );

      await vm.removeRow(vm.rows.single);

      expect(
        runner.callsTo('uninstall').single,
        <String>['uninstall', 'com.a', '--udid', 'RECORDED0000'],
      );
    });

    test('a refresh-all drives the row it names, not the whole list', () async {
      // A refresh re-signs, so it reports the same provision/sign/install phases
      // a sideload does, tagged with the app they belong to. Before this the
      // frames were dropped entirely and the list sat under one anonymous
      // spinner for however long every app took.
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'installs',
          _ok(<dynamic>[
            _record(bundleId: 'com.a'),
            _record(bundleId: 'com.b'),
          ]),
        )
        ..always(
          'refresh',
          _ok(
            _summary(<Map<String, dynamic>>[
              _entry('com.a', 'installed'),
              _entry('com.b', 'installed'),
            ]),
          ),
        )
        ..progressOn('refresh', <String>[
          '{"event":"progress","phase":"sign","step":"Signing the app\u2026",'
              '"bundle_id":"com.b"}',
          '{"event":"progress","phase":"install","percent":40,'
              '"step":"Uploading","bundle_id":"com.b"}',
          // An app we do not hold must not disturb anything.
          '{"event":"progress","phase":"install","percent":90,'
              '"bundle_id":"com.gone"}',
        ]);
      final LibraryViewModel vm = await _loaded(runner, _FakeDialogs());

      final LibraryRow a = vm.rows.firstWhere((LibraryRow r) => r.bundleId == 'com.a');
      final LibraryRow b = vm.rows.firstWhere((LibraryRow r) => r.bundleId == 'com.b');

      runner.hold = Completer<void>();
      final Future<void> running = vm.refreshAll();
      await Future<void>.delayed(Duration.zero);

      expect(b.isRefreshing, isTrue, reason: 'its frames arrived');
      expect(b.progress.activeIndex, 2);
      expect(b.progress.percent, 40);
      expect(b.progress.isIndeterminate, isFalse);
      expect(b.refreshStepText, 'Uploading');

      expect(a.isRefreshing, isFalse, reason: 'no frame named it');
      expect(a.progress, const SideloadProgressState());

      runner.hold!.complete();
      await running;
    });

    test('falls back to the selected device when the record names none', () async {
      // Registry entries written before the field existed carry no device.
      final _FakeRunner runner = _FakeRunner()
        ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.a')]));
      final LibraryViewModel vm = await _loaded(
        runner,
        _FakeDialogs(),
        devices: await _device('AAAA1111'),
      );

      await vm.removeRow(vm.rows.single);

      expect(
        runner.callsTo('uninstall').single,
        <String>['uninstall', 'com.a', '--udid', 'AAAA1111'],
      );
    });
  });

  // A refresh re-signs, so it produces the same signed .ipa a sideload does and
  // has to honour the same setting. The setting is read PER RUN, not held: this
  // model is rebuilt per visit but a run can still straddle a change.
  group('LibraryViewModel keep-signed setting', () {
    _FakeRunner refreshableRunner() => _FakeRunner()
      ..always('installs', _ok(<dynamic>[_record(bundleId: 'com.a')]))
      ..always(
        'refresh',
        _ok(_summary(<Map<String, dynamic>>[_entry('com.a', 'installed')])),
      );

    test('refresh-all sends neither flag while the setting is off', () async {
      final _FakeRunner runner = refreshableRunner();
      final LibraryViewModel vm = await _loaded(runner, _FakeDialogs());

      await vm.refreshAll();

      expect(runner.callsTo('refresh').single, <String>['refresh', '--all']);
    });

    test('refresh-all passes --keep-signed once the setting is on', () async {
      final _FakeRunner runner = refreshableRunner();
      final _FakeSettings settings = _FakeSettings()
        ..signedIpa = const SignedIpaSettings(keep: true);
      final LibraryViewModel vm =
          await _loaded(runner, _FakeDialogs(), settings: settings);

      await vm.refreshAll();

      expect(
        runner.callsTo('refresh').single,
        <String>['refresh', '--all', '--keep-signed'],
      );
    });

    test('refresh-all passes the configured folder', () async {
      final _FakeRunner runner = refreshableRunner();
      final _FakeSettings settings = _FakeSettings()
        ..signedIpa = const SignedIpaSettings(
          keep: true,
          directory: r'D:\Signed',
        );
      final LibraryViewModel vm =
          await _loaded(runner, _FakeDialogs(), settings: settings);

      await vm.refreshAll();

      expect(
        runner.callsTo('refresh').single,
        <String>[
          'refresh',
          '--all',
          '--keep-signed',
          '--signed-dir',
          r'D:\Signed',
        ],
      );
    });

    test('a single-row refresh passes the pair too', () async {
      final _FakeRunner runner = refreshableRunner();
      final _FakeSettings settings = _FakeSettings()
        ..signedIpa = const SignedIpaSettings(
          keep: true,
          directory: r'D:\Signed',
        );
      final LibraryViewModel vm =
          await _loaded(runner, _FakeDialogs(), settings: settings);

      await vm.refreshRow(vm.rows.single);

      expect(
        runner.callsTo('refresh').single,
        <String>[
          'refresh',
          '--bundle-id',
          'com.a',
          '--keep-signed',
          '--signed-dir',
          r'D:\Signed',
        ],
      );
    });

    test('a change to the setting reaches the very next refresh', () async {
      final _FakeRunner runner = refreshableRunner();
      final _FakeSettings settings = _FakeSettings();
      final LibraryViewModel vm =
          await _loaded(runner, _FakeDialogs(), settings: settings);

      await vm.refreshAll();
      // The user visits Settings and turns it on. Nothing rebuilds this model.
      settings.signedIpa = const SignedIpaSettings(keep: true);
      await vm.refreshAll();

      expect(runner.callsTo('refresh'), <List<String>>[
        <String>['refresh', '--all'],
        <String>['refresh', '--all', '--keep-signed'],
      ]);
    });
  });
}
