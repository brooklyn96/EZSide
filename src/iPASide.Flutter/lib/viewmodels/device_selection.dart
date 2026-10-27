import 'dart:async';

import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import '../services/settings_store.dart';
import 'base_view_model.dart';

/// How to reach the selected device.
///
/// A device can be attached by cable and reachable over the network at the same
/// time, and the two behave differently: reading a device's value bag measured
/// 132ms over USB against 575ms over the network on the test machine, and USB is
/// the more reliable for pushing an install. So [auto] prefers the cable, and the
/// other two are for when the user knows better than that heuristic.
enum DeviceConnection {
  /// Prefer USB, fall back to the network. What the engine does unasked.
  auto('auto', 'Automatic', 'Use the cable when it is there, otherwise Wi-Fi.'),

  /// Cable only. Fails rather than quietly going over the air.
  usb('usb', 'USB only', 'Never go over Wi-Fi, even if the cable is out.'),

  /// Network only. Fails rather than quietly using the cable.
  wifi('wifi', 'Wi-Fi only', 'Never use the cable, even when plugged in.');

  const DeviceConnection(this.wireName, this.label, this.description);

  /// The word the engine's `--connection` takes.
  final String wireName;

  /// Short name for a control.
  final String label;

  /// One line explaining the trade-off.
  final String description;

  /// The choice [wireName] names, defaulting to [auto] for anything else.
  static DeviceConnection fromWireName(String? name) {
    for (final DeviceConnection choice in values) {
      if (choice.wireName == name) return choice;
    }
    return DeviceConnection.auto;
  }
}

/// One physical iPhone, with every transport it can be reached over.
///
/// `devices` reports one entry PER TRANSPORT, so this is what a group of those
/// entries collapses to: a UDID — the only thing that identifies a device across
/// transports — plus the ways in.
@immutable
class DeviceTarget {
  /// Creates a target. [transports] is stored as given; use
  /// [DeviceSelection.group] to build one from a `devices` listing.
  const DeviceTarget({
    required this.udid,
    this.transports = const <String>[],
    this.name,
  });

  /// The device's UDID, and the value passed to the engine as `--udid`.
  final String udid;

  /// `USB` / `Network`, USB first. Read-only.
  final List<String> transports;

  /// The user-chosen device name from `device-info`, once the name pass has
  /// resolved it. Null until then, and for a device that would not answer.
  final String? name;

  /// What to call this device on screen: its name if we know it, otherwise a
  /// shortened UDID.
  ///
  /// Never blank — a device with no name still has to be nameable in a picker,
  /// and a shortened UDID is at least unambiguous.
  String get label {
    final String? name = this.name;
    return name == null || name.isEmpty ? shortUdid : name;
  }

  /// The UDID as `8 chars … last 4`, matching how Home has always shown it.
  String get shortUdid => udid.length > 14
      ? '${udid.substring(0, 8)}\u2026${udid.substring(udid.length - 4)}'
      : udid;

  /// The transports joined the way the engine's `doctor` prints them, e.g.
  /// `USB/Network`. Empty when usbmux named no transport at all.
  String get transportText => transports.join('/');

  /// Whether this device is plugged in, which is the transport the engine
  /// prefers for everything it can.
  bool get isUsb => transports.contains('USB');

  /// Returns a copy carrying [name]; used by the name pass.
  DeviceTarget withName(String? name) =>
      DeviceTarget(udid: udid, transports: transports, name: name);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceTarget &&
          other.udid == udid &&
          other.name == name &&
          listEquals(other.transports, transports);

  @override
  int get hashCode => Object.hash(udid, name, Object.hashAll(transports));

  @override
  String toString() =>
      'DeviceTarget(udid: $udid, transports: $transports, name: $name)';
}

/// Which iPhone the app is acting on.
///
/// App-scoped and shared by every screen, because the target is a property of
/// the session rather than of whichever screen happens to be open: Sideload
/// installs to it, Apps lists its apps, Home describes it. Every device-targeted
/// [EngineApi] call carries its [selectedUdid].
///
/// Passing a UDID is not a nicety. The engine takes the single connected device
/// when told nothing, but REFUSES to choose between several rather than install
/// to an arbitrary phone — so on a multi-device machine an unset selection is an
/// error, not a default.
///
/// The selection is RESOLVED rather than stored: the user's persisted preference
/// wins whenever that device is present, otherwise the first connected device
/// stands in. That is what makes unplugging survivable — the preference is left
/// alone, so replugging the phone the user actually chose silently restores it,
/// and a preference naming a device they will never own again simply never
/// applies.
class DeviceSelection extends BaseViewModel {
  /// Creates the selection over [engine], remembering the choice in [settings].
  ///
  /// Nothing is loaded until [refresh] is called, so construction stays cheap and
  /// the first engine round trip is the caller's to schedule.
  DeviceSelection({
    required this._engine,
    required SettingsStore settings,
  })  : _settings = settings,
        _preferredUdid = settings.loadDeviceUdid(),
        _connection = DeviceConnection.fromWireName(settings.loadConnection());

  final EngineApi _engine;
  final SettingsStore _settings;
  StreamSubscription<List<DeviceEntry>>? _mux;
  var _muxEventSeen = false;

  /// The persisted preference. Only ever changed by an explicit [select].
  String? _preferredUdid;

  DeviceConnection _connection;

  /// The transport every device command is issued over.
  DeviceConnection get connection => _connection;

  /// The value for the engine's `--connection`, or null to let it decide.
  ///
  /// Automatic sends nothing, because it is what the engine does anyway and a
  /// flag saying so would only be noise in the argv.
  String? get connectionArg =>
      _connection == DeviceConnection.auto ? null : _connection.wireName;

  /// Chooses the transport, remembering it for next launch.
  void setConnection(DeviceConnection choice) {
    if (_connection == choice) return;
    _connection = choice;
    _settings.saveConnection(choice.wireName);
    notify();
  }

  List<DeviceTarget> _devices = const <DeviceTarget>[];
  String? _selectedUdid;
  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _error;

  /// Completed when the first enumeration settles, either way.
  final Completer<void> _ready = Completer<void>();

  /// Names already resolved, kept across refreshes so a replug does not pay for
  /// another lockdown round trip.
  final Map<String, String> _names = <String, String>{};

  /// The connected devices, one per physical phone. Read-only.
  List<DeviceTarget> get devices => _devices;

  /// The UDID every device-targeted engine call should carry, or null when there
  /// is nothing to target.
  String? get selectedUdid => _selectedUdid;

  /// The selected device, or null when none is.
  DeviceTarget? get selected {
    final String? udid = _selectedUdid;
    if (udid == null) return null;
    for (final DeviceTarget device in _devices) {
      if (device.udid == udid) return device;
    }
    return null;
  }

  /// Whether a [refresh] is in flight.
  bool get isLoading => _isLoading;

  /// Whether the first [refresh] has finished, either way.
  bool get hasLoaded => _hasLoaded;

  /// Cleaned failure text from the last refresh, or null.
  String? get error => _error;

  /// Whether the last refresh failed.
  bool get hasError => _error != null;

  /// Whether any device is connected.
  bool get hasDevices => _devices.isNotEmpty;

  /// Whether there is an actual choice to put in front of the user.
  ///
  /// False for one device: a control that can only confirm what is already true
  /// is a control asking the user to do nothing.
  bool get hasChoice => _devices.length > 1;

  /// Whether the load finished, did not fail, and found nothing.
  bool get isEmpty => _hasLoaded && _error == null && _devices.isEmpty;

  /// Completes once the first enumeration has settled — successfully or not.
  ///
  /// Only useful to wait on via [targetUdid]; the UI reads [isLoading] instead,
  /// because it has a spinner to show and a future to await is not one.
  Future<void> get ready => _ready.future;

  /// Applies live usbmux Attached/Detached listings until [dispose].
  ///
  /// Tests leave this off unless they are asserting hotplug: they drive
  /// [refresh] and inject events on the fake runner themselves.
  void startListening() {
    _mux?.cancel();
    _mux = _engine.deviceEvents.listen(
      _onMuxListing,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  void _onMuxListing(List<DeviceEntry> entries) {
    if (isDisposed) return;
    _muxEventSeen = true;
    _commitListing(group(entries), notifyForFirstLoad: !_hasLoaded);
  }

  @override
  void dispose() {
    _mux?.cancel();
    _mux = null;
    super.dispose();
  }

  /// The UDID a device-targeted engine call should carry, waiting for the first
  /// enumeration if it has not settled yet.
  ///
  /// EVERY such call should use this rather than [selectedUdid]. A screen can be
  /// built and start loading before the enumeration comes back — Home is, on
  /// every launch — and a call that goes out in that window carries no UDID,
  /// which is precisely the call the engine refuses to answer once a second phone
  /// is plugged in.
  ///
  /// Self-starting: if nobody has enumerated yet it does it, so a caller can rely
  /// on this without depending on who ran first.
  Future<String?> targetUdid() async {
    if (!_hasLoaded && !_isLoading) {
      await refresh();
    }
    await ready;
    return _selectedUdid;
  }

  /// Re-enumerates the connected devices and re-resolves the selection.
  ///
  /// A failure leaves the previous list in place rather than blanking the target:
  /// a transient usbmux hiccup should not retarget an install.
  ///
  /// Once [startListening] has delivered a usbmux event, that listing is the live
  /// state: this snapshot is ignored so a racing `devices` RPC cannot unplug a
  /// phone that Attached after the request left.
  ///
  /// An unchanged listing after the first load does not notify.
  Future<void> refresh() async {
    // Listen already owns the list. A `devices` RPC here is both wasted and
    // able to flip isLoading after the phone is already on screen.
    if (_muxEventSeen) {
      _hasLoaded = true;
      if (!_ready.isCompleted) _ready.complete();
      return;
    }
    if (_isLoading) return; // one enumeration at a time; the answer is the same
    final bool showSpinner = !_hasLoaded;
    _isLoading = true;
    if (showSpinner) notify();

    var changed = true;
    try {
      final List<DeviceTarget> grouped = group(await _engine.devices());
      if (_muxEventSeen) {
        changed = false;
        return;
      }
      changed = _commitListing(
        grouped,
        notifyForFirstLoad: false,
        notify: false,
        loadNames: false,
      );
    } catch (error) {
      if (BaseViewModel.isShutdown(error)) {
        changed = false;
        return; // the app is closing
      }
      _error = BaseViewModel.errorText(error);
    } finally {
      _isLoading = false;
      _hasLoaded = true;
      // Before the notify, so a listener woken by it already sees a settled
      // selection. Names are deliberately NOT waited for: a caller needs the
      // target, and a lockdown round trip per device to learn what to call them
      // is not part of that.
      if (!_ready.isCompleted) _ready.complete();
      if (changed || showSpinner) notify();
    }

    if (changed) await _loadNames();
  }

  /// Returns whether the grouped listing actually changed.
  bool _commitListing(
    List<DeviceTarget> grouped, {
    required bool notifyForFirstLoad,
    bool notify = true,
    bool loadNames = true,
  }) {
    var changed = true;
    if (_hasLoaded &&
        _error == null &&
        _signature(grouped) == _signature(_devices)) {
      changed = false;
    } else {
      _error = null;
      _devices = <DeviceTarget>[
        for (final DeviceTarget device in grouped)
          device.withName(_names[device.udid]),
      ];
      _resolveSelection();
    }
    _hasLoaded = true;
    if (!_ready.isCompleted) _ready.complete();
    if (notify && (changed || notifyForFirstLoad)) {
      this.notify();
    }
    if (changed && loadNames) unawaited(_loadNames());
    return changed;
  }

  /// UDID plus transports, ignoring display names — enough to know whether the
  /// watch saw a plug-in, an unplug, or a USB/Wi-Fi change.
  static String _signature(List<DeviceTarget> devices) => <String>[
        for (final DeviceTarget device in devices)
          '${device.udid}:${device.transports.join(',')}',
      ].join('|');

  /// Targets [udid] from now on, and remembers it for the next launch.
  ///
  /// Ignored for a device that is not connected: the picker only ever offers what
  /// is in [devices], and honouring anything else would put the app in a state
  /// whose only outcome is an engine error.
  void select(String udid) {
    if (_selectedUdid == udid) return;
    if (!_devices.any((DeviceTarget device) => device.udid == udid)) return;

    _selectedUdid = udid;
    _preferredUdid = udid;
    _settings.saveDeviceUdid(udid);
    notify();
  }

  /// Collapses a per-transport `devices` listing into one entry per physical
  /// device, in the order the devices were first seen.
  ///
  /// Mirrors the engine's own grouping (`device._targetable_udids` and the
  /// `doctor` device check): entries with no serial are dropped, because whatever
  /// they are they cannot be named as a target; duplicate transports collapse;
  /// and USB sorts first, matching the connection policy that prefers it.
  static List<DeviceTarget> group(List<DeviceEntry> entries) {
    final Map<String, List<String>> transportsByUdid = <String, List<String>>{};

    for (final DeviceEntry entry in entries) {
      final String? serial = entry.serial;
      if (serial == null || serial.isEmpty) continue;

      final List<String> transports =
          transportsByUdid.putIfAbsent(serial, () => <String>[]);
      final String? transport = entry.connectionType;
      if (transport != null &&
          transport.isNotEmpty &&
          !transports.contains(transport)) {
        transports.add(transport);
      }
    }

    return <DeviceTarget>[
      for (final MapEntry<String, List<String>> entry
          in transportsByUdid.entries)
        DeviceTarget(
          udid: entry.key,
          transports: List<String>.unmodifiable(_usbFirst(entry.value)),
        ),
    ];
  }

  /// [transports] with USB in front, every other transport keeping its order.
  ///
  /// A stable partition rather than a sort: there are only ever two or three
  /// transports, and this cannot reorder the ones it is not moving.
  static List<String> _usbFirst(List<String> transports) => <String>[
        for (final String transport in transports)
          if (_isUsb(transport)) transport,
        for (final String transport in transports)
          if (!_isUsb(transport)) transport,
      ];

  static bool _isUsb(String transport) => transport.toUpperCase() == 'USB';

  /// Points [_selectedUdid] at the device the user meant, or at nothing.
  void _resolveSelection() {
    if (_devices.isEmpty) {
      _selectedUdid = null;
      return;
    }

    final String? preferred = _preferredUdid;
    if (preferred != null && _isConnected(preferred)) {
      _selectedUdid = preferred;
      return;
    }

    // Nothing is remembered, or the remembered phone is not here. A selection
    // that has been unplugged is kept only if it came back; otherwise it is
    // replaced, because targeting a device that cannot receive an install is
    // worse than targeting the one that can.
    final String? current = _selectedUdid;
    if (current != null && _isConnected(current)) return;
    _selectedUdid = _devices.first.udid;
  }

  bool _isConnected(String udid) =>
      _devices.any((DeviceTarget device) => device.udid == udid);

  /// Second pass: fill in device names once the list is already on screen.
  ///
  /// A name costs a lockdown connection per device, far too slow to block a
  /// picker on, so the list arrives labelled by UDID and relabels itself when the
  /// names land — the same trade the Apps screen makes for icons. Failure is
  /// silent: a device that will not answer keeps its UDID, which is still a usable
  /// label.
  Future<void> _loadNames() async {
    final List<DeviceTarget> pending = <DeviceTarget>[
      for (final DeviceTarget device in _devices)
        if (!_names.containsKey(device.udid)) device,
    ];
    if (pending.isEmpty) return;

    var changed = false;
    for (final DeviceTarget device in pending) {
      final String? name = await _nameOf(device.udid);
      if (isDisposed) return;
      if (name == null) continue;
      _names[device.udid] = name;
      changed = true;
    }
    if (!changed) return;

    _devices = <DeviceTarget>[
      for (final DeviceTarget device in _devices)
        device.name == null ? device.withName(_names[device.udid]) : device,
    ];
    notify();
  }

  Future<String?> _nameOf(String udid) async {
    try {
      final DeviceInfo info = await _engine.deviceInfo(
        udid: udid,
        connection: connectionArg,
      );
      final String? name = info.deviceName;
      return name == null || name.isEmpty ? null : name;
    } catch (_) {
      // Including a shutdown: the isDisposed check above owns that outcome.
      return null;
    }
  }
}
