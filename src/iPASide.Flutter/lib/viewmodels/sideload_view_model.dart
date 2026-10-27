import 'dart:typed_data';

import '../engine/engine.dart';
import '../services/file_picker.dart';
import '../services/icon_cache.dart';
import '../services/settings_store.dart';
import '../ui/shell/app_dialogs.dart';
import '../ui/shell/nav_destination.dart';
import 'base_view_model.dart';
import 'device_selection.dart';
import 'navigation_state.dart';
import 'sideload_progress_state.dart';

/// One row in the injected-tweaks list: a resolved dylib.
class TweakRow {
  const TweakRow({
    required this.path,
    required this.name,
    required this.archText,
    this.fromDebText,
  });

  final String path;
  final String name;

  /// Architectures joined with `/`, or `?` when the engine reported none.
  final String archText;

  /// `from <package>.deb`, or null for a bare `.dylib`.
  final String? fromDebText;

  bool get hasSource => fromDebText != null;
}

/// The Sideload session.
///
/// Long-lived: the selected IPA and its inspection, the tweak list, the
/// advanced options and the Advanced disclosure state all survive navigating
/// away and back. It is also the target for window-wide file drops and the
/// `IPASIDE_STARTUP_QUERY` harness.
///
/// A run drives the Provision → Sign → Install stepper from the engine's
/// progress frames; a shutdown fault during app close is swallowed, because
/// teardown owns the outcome at that point.
class SideloadViewModel extends BaseViewModel {
  SideloadViewModel({
    required this._engine,
    required this._navigation,
    required this._dialogs,
    required this._picker,
    required this._icons,
    required this._settings,
    required this._devices,
  });

  final EngineApi _engine;
  final NavigationState _navigation;
  final DialogService _dialogs;
  final FilePickerService _picker;
  final IconCache _icons;

  /// Read at sideload time, never cached. This model is app-scoped and outlives
  /// any visit to Settings, so a value read in the constructor would go stale the
  /// moment the user changed it.
  final SettingsStore _settings;

  /// The phone to install to. Also read per run, for the same reason: the target
  /// can change — or be unplugged — between two sideloads of one session.
  final DeviceSelection _devices;

  /// Resolved dylibs backing [tweaks], de-duplicated by path.
  List<TweakDylib> _resolvedTweaks = [];

  // ---- Selection + inspection ----

  String? _ipaPath;
  IpaInspection? _inspection;
  Uint8List? _iconBytes;
  bool _isInspecting = false;
  String _inspectingText = '';
  String? _inspectError;

  String? get ipaPath => _ipaPath;
  IpaInspection? get inspection => _inspection;
  Uint8List? get iconBytes => _iconBytes;
  bool get isInspecting => _isInspecting;
  String get inspectingText => _inspectingText;
  String? get inspectError => _inspectError;

  bool get hasIpa => _inspection != null;
  bool get showDropzone => _inspection == null;
  bool get hasInspectError => _inspectError != null;

  /// FairPlay-encrypted IPAs cannot be re-signed.
  bool get isBlocked => _inspection?.hasScInfo == true;

  bool get showSideloadArea => _inspection != null && !isBlocked;

  String get displayName =>
      _inspection?.displayName ?? _inspection?.bundleId ?? '';

  String get bundleId => _inspection?.bundleId ?? '';

  String get fileName => _ipaPath == null ? '' : _baseName(_ipaPath!);

  String get versionChip => 'v${_inspection?.version ?? '?'}';

  String get minOsChip => 'iOS ${_inspection?.minimumOs ?? '?'}+';

  String get frameworksChip => '${_inspection?.frameworks.length ?? 0} frameworks';

  String get extensionsChip {
    final count = _inspection?.extensions.length ?? 0;
    return count > 0 ? '$count extensions \u2192 removed' : 'no extensions';
  }

  /// Watermark for the display-name override: the app's own name.
  String get namePlaceholder => displayName;

  // ---- Advanced options ----

  bool _advancedOpen = false;
  String _bundleIdOverride = '';
  String _nameOverride = '';
  bool _removeExtensions = true;
  bool _removeDeviceRestrictions = true;
  bool _enableFileSharing = false;
  bool _weakDylibs = false;
  List<TweakRow> _tweaks = const [];

  /// Disclosure state for the Advanced section. Survives navigation; never
  /// written to disk.
  bool get advancedOpen => _advancedOpen;
  set advancedOpen(bool value) {
    if (_advancedOpen == value) return;
    _advancedOpen = value;
    notify();
  }

  String get bundleIdOverride => _bundleIdOverride;
  set bundleIdOverride(String value) {
    if (_bundleIdOverride == value) return;
    _bundleIdOverride = value;
    notify();
  }

  String get nameOverride => _nameOverride;
  set nameOverride(String value) {
    if (_nameOverride == value) return;
    _nameOverride = value;
    notify();
  }

  bool get removeExtensions => _removeExtensions;
  set removeExtensions(bool value) {
    if (_removeExtensions == value) return;
    _removeExtensions = value;
    notify();
  }

  bool get removeDeviceRestrictions => _removeDeviceRestrictions;
  set removeDeviceRestrictions(bool value) {
    if (_removeDeviceRestrictions == value) return;
    _removeDeviceRestrictions = value;
    notify();
  }

  bool get enableFileSharing => _enableFileSharing;
  set enableFileSharing(bool value) {
    if (_enableFileSharing == value) return;
    _enableFileSharing = value;
    notify();
  }

  bool get weakDylibs => _weakDylibs;
  set weakDylibs(bool value) {
    if (_weakDylibs == value) return;
    _weakDylibs = value;
    notify();
  }

  List<TweakRow> get tweaks => _tweaks;
  bool get hasTweaks => _tweaks.isNotEmpty;

  // ---- Run state ----

  bool _isRunning = false;
  bool _isSucceeded = false;
  bool _isUnexpected = false;
  bool _isFailed = false;
  SideloadProgressState _progress = const SideloadProgressState();
  bool _isInstallComplete = false;
  String _successTitle = '';
  String? _failureMessage;

  bool get isRunning => _isRunning;
  bool get isSucceeded => _isSucceeded;
  bool get isUnexpected => _isUnexpected;
  bool get isFailed => _isFailed;
  int get activeStepIndex => _progress.activeIndex;
  String? get stepText => _progress.stepText;
  double get percent => _progress.percent;
  bool get isProgressIndeterminate => _progress.isIndeterminate;
  bool get isInstallComplete => _isInstallComplete;
  String get successTitle => _successTitle;
  String? get failureMessage => _failureMessage;

  bool get showStepper => _isRunning || _isSucceeded || _isFailed;

  // ---- Drop-target surface ----

  void openAdvanced() => advancedOpen = true;

  /// Inspects an `.ipa` into the session, replacing any current selection.
  ///
  /// Refused while a run is in flight: the engine call cannot be cancelled, so
  /// swapping the selection under it would leave the run writing its outcome
  /// onto a session that no longer describes what is being installed.
  Future<void> loadIpa(String path) async {
    if (path.isEmpty || _isRunning) return;

    _resetRun();
    _inspectError = null;
    _isInspecting = true;
    _inspectingText = 'Reading ${_baseName(path)}\u2026';
    notify();

    try {
      final inspection = await _engine.inspect(path);
      _ipaPath = path;
      _inspection = inspection;
      _iconBytes = _icons.bytesFor(inspection.icon);

      // A fresh selection clears tweaks and options; the Advanced disclosure
      // state deliberately persists.
      _resolvedTweaks = [];
      _rebuildTweakRows();
      _resetOptions();
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _ipaPath = null;
        _inspection = null;
        _iconBytes = null;
        _inspectError = BaseViewModel.errorText(error);
      }
    } finally {
      _isInspecting = false;
      notify();
    }
  }

  /// Resolves and appends `.deb` / `.dylib` tweaks, de-duplicated by path.
  ///
  /// A file that fails to resolve raises its own dialog and the rest continue,
  /// so one bad package cannot lose the whole drop.
  Future<void> addTweaks(List<String> paths) async {
    if (_isRunning) return; // the options are already locked into the running job
    for (final tweakPath in paths) {
      List<TweakDylib> dylibs;
      try {
        dylibs = await _engine.resolveTweak(tweakPath);
      } catch (error) {
        if (BaseViewModel.isShutdown(error)) return;
        await _dialogs.alert(
          title: "Couldn't add tweak",
          message: '${_baseName(tweakPath)} \u2014 ${BaseViewModel.errorText(error)}',
        );
        continue;
      }
      _resolvedTweaks = TweakSet.mergeDistinctByPath(_resolvedTweaks, dylibs).toList();
    }

    _rebuildTweakRows();
    notify();
  }

  // ---- Commands ----

  Future<void> choose() async {
    final path = await _picker.pickIpa();
    if (path != null) await loadIpa(path);
  }

  /// Resets the whole session back to the dropzone.
  ///
  /// Ignored while a run is in flight; the button is disabled then too.
  void change() {
    if (_isRunning) return;
    _ipaPath = null;
    _inspection = null;
    _iconBytes = null;
    _inspectError = null;
    _resolvedTweaks = [];
    _rebuildTweakRows();
    _resetOptions();
    _resetRun();
    notify();
  }

  Future<void> addTweaksFromPicker() async {
    final paths = await _picker.pickTweaks();
    if (paths.isNotEmpty) await addTweaks(paths);
  }

  void removeTweak(TweakRow row) {
    _resolvedTweaks.removeWhere((t) => t.path == row.path);
    _rebuildTweakRows();
    notify();
  }

  Future<void> sideload() async {
    final path = _ipaPath;
    if (path == null || _inspection == null || isBlocked || _isRunning) return;

    // Claimed before the first await, not after the sign-in probe below: the
    // button is disabled while a run is on, but the guard has to hold on its own,
    // or two calls landing in the same frame would both get past it and install
    // the app twice over.
    _resetRun();
    _isRunning = true;
    _progress = SideloadProgressState.starting;
    notify();

    try {
      // Pre-flight: an unauthenticated — or unknown — session goes to sign-in.
      LoginStatus? status;
      try {
        status = await _engine.loginStatus();
      } catch (error) {
        if (BaseViewModel.isShutdown(error)) return;
        // A failed probe counts as signed out.
      }

      if (status == null || !status.authenticated) {
        _navigation.navigateTo(NavKey.signIn);
        return;
      }

      // Both of these are read here rather than held as fields: this model is
      // app-scoped, so anything cached at construction would still be the value
      // the app started with.
      final signed = _settings.loadSignedIpa();
      final udid = await _devices.targetUdid();

      final options = SideloadOptions(
        udid: udid,
        connection: _devices.connectionArg,
        bundleId: _bundleIdOverride,
        name: _nameOverride,
        removeExtensions: _removeExtensions,
        removeDeviceRestrictions: _removeDeviceRestrictions,
        enableFileSharing: _enableFileSharing,
        weakDylibs: _weakDylibs,
        keepSigned: signed.keep,
        signedDirectory: signed.directory,
        dylibs: [for (final t in _resolvedTweaks) if (t.path != null) t.path!],
      );

      final result = await _engine.sideload(path, options, onProgress: _onProgress);
      if (result.status == 'installed') {
        _progress = _progress.completed();
        _isInstallComplete = true;
        _successTitle = 'Installed ${result.name}';
        _isSucceeded = true;
      } else {
        _isUnexpected = true;
      }
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _failureMessage = BaseViewModel.errorText(error);
        _isFailed = true;
      }
    } finally {
      _isRunning = false;
      notify();
    }
  }

  // ---- Internals ----

  void _onProgress(SideloadProgress progress) {
    final SideloadProgressState next = _progress.apply(progress);
    if (next == _progress) return; // a phase we do not draw
    _progress = next;
    notify();
  }

  void _rebuildTweakRows() {
    _tweaks = [
      for (final dylib in _resolvedTweaks)
        if (dylib.path case final String path)
          TweakRow(
            path: path,
            name: dylib.name ?? _baseName(path),
            archText: dylib.arches.isNotEmpty ? dylib.arches.join('/') : '?',
            fromDebText: dylib.fromDeb == null ? null : 'from ${dylib.fromDeb}',
          ),
    ];
  }

  void _resetOptions() {
    _bundleIdOverride = '';
    _nameOverride = '';
    _removeExtensions = true;
    _removeDeviceRestrictions = true;
    _enableFileSharing = false;
    _weakDylibs = false;
  }

  void _resetRun() {
    _isRunning = false;
    _isSucceeded = false;
    _isUnexpected = false;
    _isFailed = false;
    _progress = const SideloadProgressState();
    _isInstallComplete = false;
    _successTitle = '';
    _failureMessage = null;
  }

  /// Last path segment, handling both separators without pulling in a package.
  static String _baseName(String path) {
    final index = path.lastIndexOf(RegExp(r'[\\/]'));
    return index < 0 ? path : path.substring(index + 1);
  }
}
