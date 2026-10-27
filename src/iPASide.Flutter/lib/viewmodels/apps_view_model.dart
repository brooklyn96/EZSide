// Ported from iPASide.App/ViewModels/AppsViewModel.cs.

import 'dart:typed_data';

import '../engine/engine.dart';
import '../services/icon_cache.dart';
import '../ui/shell/app_dialogs.dart';
import 'base_view_model.dart';
import 'device_selection.dart';

/// One user app installed on the device, with the state its Uninstall action
/// drives.
///
/// A row is a snapshot of one `apps` entry; every load rebuilds the whole list.
/// [isRemoving] is library-private to set so only [AppsViewModel] can move a row
/// between states.
class AppRow {
  AppRow._(this.bundleId, InstalledApp app)
      : name = _textOr(app.name, bundleId),
        subtitle = _subtitleFor(bundleId, app.version);

  /// Bundle identifier the uninstall is issued against.
  final String bundleId;

  /// Display name as installed, falling back to [bundleId].
  final String name;

  /// The bundle id, or `<bundleId> · <version>` when a version is reported.
  final String subtitle;

  bool _isRemoving = false;
  Uint8List? _iconBytes;

  /// Whether the uninstall is running ("Removing…" button state).
  bool get isRemoving => _isRemoving;

  /// The home-screen icon, once the second pass has fetched it; null until then
  /// (and for apps whose icon SpringBoard would not give up).
  Uint8List? get iconBytes => _iconBytes;

  static String _textOr(String? value, String fallback) =>
      value == null || value.isEmpty ? fallback : value;

  static String _subtitleFor(String bundleId, String? version) =>
      version == null || version.isEmpty ? bundleId : '$bundleId \u00B7 $version';
}

/// Apps: the selected device's user apps from `apps` (a dict keyed by bundle id),
/// sorted by display name, each with a confirmed Uninstall.
///
/// Every call it makes is device-targeted, so all three carry the selected UDID,
/// and the list reloads when that selection moves. Retargeting from the sidebar
/// while this screen is open would otherwise leave one phone's apps on screen
/// labelled as another's — and offer to uninstall them from it.
class AppsViewModel extends BaseViewModel {
  AppsViewModel({
    required this._engine,
    required this._dialogs,
    required this._icons,
    required this._devices,
  }) {
    _devices.addListener(_onSelectionChanged);
    _load();
  }

  final EngineApi _engine;
  final DialogService _dialogs;
  final IconCache _icons;
  final DeviceSelection _devices;

  @override
  void dispose() {
    _devices.removeListener(_onSelectionChanged);
    super.dispose();
  }

  List<AppRow> _rows = const <AppRow>[];
  bool _isLoading = true;
  String? _error;
  bool _isEmpty = false;

  /// The (device, transport) pair the rows on screen belong to, so the many
  /// notifications that change neither do not each reload the list.
  String? _shownUdid;
  String? _shownConnection;

  /// Increments per load, so an answer for a phone the user has already moved on
  /// from is dropped rather than shown under the new phone's name.
  int _loadToken = 0;

  /// The installed apps, sorted by display name. Read-only.
  List<AppRow> get rows => _rows;

  /// Whether the first (or a subsequent) load is still running.
  bool get isLoading => _isLoading;

  /// Cleaned failure text from the last load, or null.
  String? get error => _error;

  /// Whether the last load failed.
  bool get hasError => _error != null;

  /// Whether the load succeeded and the device reported no user apps.
  bool get isEmpty => _isEmpty;

  /// Uninstalls an app after confirmation, reloading the list on success.
  ///
  /// A failure only restores the button: the device going away mid-uninstall is
  /// common enough that the web UI never raised a dialog for it, and neither
  /// does this.
  Future<void> uninstallRow(AppRow row) async {
    if (row.isRemoving) return;

    final bool confirmed = await _dialogs.confirm(
      title: 'Uninstall app',
      message: 'Uninstall ${row.name} from your iPhone?',
      confirmLabel: 'Uninstall',
      cancelLabel: 'Cancel',
      danger: true,
    );
    if (!confirmed) return;

    row._isRemoving = true;
    notify();

    try {
      await _engine.uninstall(
        row.bundleId,
        udid: await _devices.targetUdid(),
        connection: _devices.connectionArg,
      );
    } catch (error) {
      if (BaseViewModel.isShutdown(error)) return; // the app is closing
      row._isRemoving = false;
      notify();
      return;
    }

    await _load();
  }

  Future<void> _load() async {
    final int token = ++_loadToken;
    // Resolved once and carried into the icon pass: both calls must land on the
    // same phone, and re-reading it between them could straddle a retarget.
    final String? udid = await _devices.targetUdid();
    if (isDisposed || token != _loadToken) return;
    _shownUdid = udid;
    _shownConnection = _devices.connectionArg;

    try {
      final Map<String, InstalledApp> apps = await _engine.apps(
        udid: udid,
        connection: _shownConnection,
      );
      if (token != _loadToken) return; // retargeted while this was in flight
      _error = null;
      final List<AppRow> rows = <AppRow>[
        for (final MapEntry<String, InstalledApp> entry in apps.entries)
          AppRow._(entry.key, entry.value),
      ];
      rows.sort(_byDisplayName);
      _rows = rows;
      _isEmpty = _rows.isEmpty;
    } catch (error) {
      if (token != _loadToken) return;
      // A shutdown leaves the view exactly as it was; the app is closing.
      if (!BaseViewModel.isShutdown(error)) {
        _error = BaseViewModel.errorText(error);
        _rows = const <AppRow>[];
        _isEmpty = false;
      }
    } finally {
      if (token == _loadToken) {
        _isLoading = false;
        notify();
      }
    }

    if (token == _loadToken && _rows.isNotEmpty) await _loadIcons(udid);
  }

  /// Reloads the list when the selection moves to a different phone or transport.
  void _onSelectionChanged() {
    if (isDisposed) return;
    if (_devices.selectedUdid == _shownUdid &&
        _devices.connectionArg == _shownConnection) {
      return; // a refresh starting, or names arriving: nothing this list reads
    }

    _rows = const <AppRow>[];
    _isEmpty = false;
    _error = null;
    _isLoading = true;
    notify();
    _load();
  }

  /// Second pass: fill in home-screen icons once the list is already on screen.
  ///
  /// Failure is silent by design — rows simply keep their placeholder glyph
  /// rather than the whole screen reporting an error over missing artwork.
  Future<void> _loadIcons(String? udid) async {
    final Map<String, String> icons;
    try {
      icons = await _engine.appIcons(
          udid: udid,
          connection: _devices.connectionArg,
        );
    } catch (_) {
      return;
    }
    if (isDisposed) return;

    var changed = false;
    for (final AppRow row in _rows) {
      final Uint8List? bytes = _icons.bytesFor(icons[row.bundleId]);
      if (bytes != null) {
        row._iconBytes = bytes;
        changed = true;
      }
    }
    if (changed) notify();
  }

  /// Orders rows the way the web UI's `localeCompare` did: case differences do
  /// not reorder apps, they only break ties.
  ///
  /// Dart ships no collator, so folded case stands in for the culture-aware
  /// comparison. The bundle id is the final tiebreak because [List.sort] is not
  /// stable and two apps may share a name.
  static int _byDisplayName(AppRow a, AppRow b) {
    final int folded = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (folded != 0) return folded;
    final int exact = a.name.compareTo(b.name);
    return exact != 0 ? exact : a.bundleId.compareTo(b.bundleId);
  }
}
