// Ported from iPASide.App/ViewModels/LibraryViewModel.cs.

import 'dart:typed_data';

import '../engine/engine.dart';
import '../services/icon_cache.dart';
import '../services/settings_store.dart';
import '../ui/shell/app_dialogs.dart';
import '../ui/widgets/surfaces.dart';
import 'base_view_model.dart';
import 'device_selection.dart';
import 'sideload_progress_state.dart';

/// One sideloaded app in the Library: icon, name, bundle id + tweak count, the
/// expiry pill, and the transient state its Refresh / Remove actions drive.
///
/// A row is a snapshot of one `installs` entry; every load rebuilds the whole
/// list. The busy flags are library-private so only [LibraryViewModel] can move
/// a row between states.
class LibraryRow {
  LibraryRow._(InstallRecord record, IconCache icons)
      : bundleId = record.bundleId ?? '',
        name = _nameFor(record),
        subtitle = _subtitleFor(record),
        iconBytes = icons.bytesFor(record.icon),
        udid = record.udid,
        _pill = ExpiryPills.classifyRecord(record);

  /// Installed bundle identifier; the key every row action is issued against.
  final String bundleId;

  /// The device this app was installed onto, when the record names one.
  final String? udid;

  /// Display name recorded at sideload time, falling back to [bundleId].
  final String name;

  /// The bundle id, or `<bundleId> · <n> tweak(s)` when dylibs were injected.
  final String subtitle;

  /// Decoded PNG bytes for the recorded icon, or null when there is none.
  final Uint8List? iconBytes;

  final ExpiryPill _pill;

  bool _isRefreshing = false;
  bool _isRemoving = false;
  SideloadProgressState _progress = const SideloadProgressState();

  /// Expiry countdown label, e.g. `3 days left`.
  String get pillText => _pill.text;

  /// Severity treatment for [pillText]; an undeterminable expiry reads neutral.
  PillKind get pillKind => switch (_pill.level) {
        ExpiryLevel.ok => PillKind.ok,
        ExpiryLevel.warn => PillKind.warn,
        ExpiryLevel.expired => PillKind.danger,
        ExpiryLevel.unknown => PillKind.neutral,
      };

  /// Whether this row's refresh is running.
  bool get isRefreshing => _isRefreshing;

  /// Whether this row's removal is running.
  bool get isRemoving => _isRemoving;

  /// Whether either row action is running.
  ///
  /// Both buttons are gated on this rather than on their own flag: uninstalling
  /// an app while its re-signed build is being pushed back onto the device
  /// would leave the library and the phone disagreeing.
  bool get isBusy => _isRefreshing || _isRemoving;

  /// The live progress of this row's refresh, for the stepper.
  ///
  /// A refresh re-signs, so it runs the same provision → sign → install phases a
  /// sideload does and is shown the same way, rather than as a lone spinner.
  SideloadProgressState get progress => _progress;

  /// The live refresh step, also used as the Refresh button's tooltip.
  String? get refreshStepText => _progress.stepText;

  static String _nameFor(InstallRecord record) {
    final String? name = record.name;
    return name == null || name.isEmpty ? record.bundleId ?? '' : name;
  }

  static String _subtitleFor(InstallRecord record) {
    final String bundleId = record.bundleId ?? '';
    final int tweaks = record.options?.dylibs.length ?? 0;
    return tweaks > 0
        ? '$bundleId \u00B7 $tweaks tweak${tweaks == 1 ? '' : 's'}'
        : bundleId;
  }
}

/// Library: the sideloaded apps from `installs` with their expiry pills,
/// per-row Refresh and Remove, a Refresh-all toolbar that names the apps it
/// could not renew, and an empty state.
///
/// Both refresh paths inspect the per-app `refreshed` entries instead of
/// trusting the overall result: the engine reports `ok` even when individual
/// apps failed.
///
/// A refresh re-signs, so it produces the same signed `.ipa` a sideload does and
/// honours the same keep-signed setting — read per run, because the setting can
/// change while the Library is open.
class LibraryViewModel extends BaseViewModel {
  LibraryViewModel({
    required this._engine,
    required this._dialogs,
    required this._icons,
    required this._settings,
    required this._devices,
  }) {
    _load();
  }

  final EngineApi _engine;
  final DialogService _dialogs;
  final IconCache _icons;

  /// Read at refresh time, never cached — the user can change the setting and
  /// come back without this model being rebuilt.
  final SettingsStore _settings;

  /// Fallback target for a record that does not name the device it went to.
  final DeviceSelection _devices;

  List<LibraryRow> _rows = const <LibraryRow>[];
  bool _isLoading = true;
  String? _error;
  bool _isEmpty = false;
  bool _hasItems = false;
  bool _isRefreshingAll = false;

  /// The library, in the order the engine reported it. Read-only.
  List<LibraryRow> get rows => _rows;

  /// Whether the first (or a subsequent) load is still running.
  bool get isLoading => _isLoading;

  /// Cleaned failure text from the last load, or null.
  String? get error => _error;

  /// Whether the last load failed.
  bool get hasError => _error != null;

  /// Whether the load succeeded and returned nothing.
  bool get isEmpty => _isEmpty;

  /// Whether the Refresh-all toolbar shows; hidden while empty or failed.
  bool get hasItems => _hasItems;

  /// Whether the Refresh-all run is in flight.
  bool get isRefreshingAll => _isRefreshingAll;

  /// Re-signs every recorded app, reports the ones that failed, then reloads.
  Future<void> refreshAll() async {
    if (_isRefreshingAll) return;
    _isRefreshingAll = true;
    notify();

    final SignedIpaSettings signed = _settings.loadSignedIpa();

    try {
      final RefreshSummary summary = await _engine.refresh(
        all: true,
        keepSigned: signed.keep,
        signedDirectory: signed.directory,
        connection: _devices.connectionArg,
        // The engine tags every frame with the app it belongs to, so a
        // refresh-all shows its progress on the row being worked on rather than
        // leaving the whole list sitting under one anonymous spinner.
        onProgress: (SideloadProgress progress) {
          final LibraryRow? row = _rowFor(progress.bundleId);
          if (row == null) return;
          if (!row._isRefreshing) {
            row._isRefreshing = true; // its turn has come round
          }
          _applyProgress(row, progress);
        },
      );
      final List<RefreshEntry> failed = summary.refreshed
          .where((RefreshEntry entry) => entry.status == 'error')
          .toList();
      if (failed.isNotEmpty) {
        await _dialogs.alert(
          title: "${failed.length} app(s) couldn't be refreshed",
          message: failed
              .map((RefreshEntry entry) => entry.bundleId ?? '')
              .join(', '),
        );
      }
    } catch (error) {
      // A `return` here still runs the finally below, then skips the reload.
      if (BaseViewModel.isShutdown(error)) return; // the app is closing
      await _dialogs.alert(
        title: 'Refresh failed',
        message: BaseViewModel.errorText(error),
      );
    } finally {
      _isRefreshingAll = false;
      notify();
    }

    await _load();
  }

  /// The row a progress frame belongs to, or null if it names no app we hold.
  LibraryRow? _rowFor(String? bundleId) {
    if (bundleId == null) return null;
    for (final LibraryRow row in _rows) {
      if (row.bundleId == bundleId) return row;
    }
    return null;
  }

  /// Folds a progress frame into [row], notifying only when something changed.
  void _applyProgress(LibraryRow row, SideloadProgress progress) {
    final SideloadProgressState next = row._progress.apply(progress);
    if (next == row._progress) return;
    row._progress = next;
    notify();
  }

  /// Re-signs one app, streaming its live step into the row, then reloads.
  Future<void> refreshRow(LibraryRow row) async {
    if (row.isBusy) return;
    row._isRefreshing = true;
    notify();

    final SignedIpaSettings signed = _settings.loadSignedIpa();

    try {
      final RefreshSummary summary = await _engine.refresh(
        bundleId: row.bundleId,
        keepSigned: signed.keep,
        signedDirectory: signed.directory,
        connection: _devices.connectionArg,
        onProgress: (SideloadProgress progress) => _applyProgress(row, progress),
      );

      // A single-app run is reported as `ok` with the real outcome in
      // refreshed[0], so a failure has to be raised by hand.
      final RefreshEntry? outcome =
          summary.refreshed.isEmpty ? null : summary.refreshed.first;
      if (outcome != null && outcome.status == 'error') {
        throw EngineException(
          EngineException.cleanError(outcome.error ?? 'refresh failed'),
        );
      }

      await _load(); // the row keeps its spinner until the reload replaces it
    } catch (error) {
      if (BaseViewModel.isShutdown(error)) return; // the app is closing
      row._isRefreshing = false;
      notify();
      await _dialogs.alert(
        title: 'Refresh failed',
        message: BaseViewModel.errorText(error),
      );
    }
  }

  /// Drops an app from the library after confirmation, uninstalling it from the
  /// device on the way out, then reloads.
  Future<void> removeRow(LibraryRow row) async {
    if (row.isBusy) return;

    final bool confirmed = await _dialogs.confirm(
      title: 'Remove from library',
      message: 'This removes the app from your library and uninstalls it from '
          "your iPhone if it's connected.",
      confirmLabel: 'Remove',
      cancelLabel: 'Cancel',
      danger: true,
    );
    if (!confirmed) return;

    row._isRemoving = true;
    notify();

    try {
      try {
        // The phone the app actually went to, which the registry records, not
        // whichever one happens to be selected now. Retargeting to a second
        // device and then removing a row must not uninstall from that device.
        // A record predating the field falls back to the current target.
        await _engine.uninstall(
          row.bundleId,
          udid: row.udid ?? await _devices.targetUdid(),
          connection: _devices.connectionArg,
        );
      } catch (error) {
        // The device may be offline; the uninstall is best-effort.
        if (BaseViewModel.isShutdown(error)) return;
      }

      try {
        await _engine.forget(row.bundleId);
      } catch (error) {
        // Best-effort as well.
        if (BaseViewModel.isShutdown(error)) return;
      }

      await _load();
    } finally {
      row._isRemoving = false;
      notify();
    }
  }

  Future<void> _load() async {
    try {
      final List<InstallRecord> records = await _engine.installs();
      _error = null;
      _rows = <LibraryRow>[
        for (final InstallRecord record in records)
          LibraryRow._(record, _icons),
      ];
      _hasItems = _rows.isNotEmpty;
      _isEmpty = _rows.isEmpty;
    } catch (error) {
      // A shutdown leaves the view exactly as it was; the app is closing.
      if (!BaseViewModel.isShutdown(error)) {
        _error = BaseViewModel.errorText(error);
        _rows = const <LibraryRow>[];
        _hasItems = false;
        _isEmpty = false;
      }
    } finally {
      _isLoading = false;
      notify();
    }
  }
}
