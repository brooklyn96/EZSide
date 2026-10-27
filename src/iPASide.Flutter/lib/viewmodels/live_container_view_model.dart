import '../engine/engine.dart';
import '../services/file_picker.dart';
import '../services/settings_store.dart';
import '../ui/shell/app_dialogs.dart';
import '../ui/shell/nav_destination.dart';
import 'base_view_model.dart';
import 'device_selection.dart';
import 'navigation_state.dart';
import 'sideload_progress_state.dart';

/// The LiveContainer screen.
///
/// Long-lived, for the same reason the Sideload session is: setting LiveContainer
/// up takes half a minute of downloading, signing and installing, and navigating
/// away mid-run must not throw the progress — or the outcome — away.
///
/// What it is for: LiveContainer runs other apps inside itself, so the phone
/// counts one installed app however many are loaded into it. That is the only way
/// past the three-app limit a free Apple ID imposes. iPASide signs it with the
/// entitlements it needs and hands it the signing certificate, which is what lets
/// it sign guest apps on device.
class LiveContainerViewModel extends BaseViewModel {
  LiveContainerViewModel({
    required this._engine,
    required this._navigation,
    required this._settings,
    required this._devices,
    required this._picker,
    required this._dialogs,
  });

  final EngineApi _engine;
  final NavigationState _navigation;
  final FilePickerService _picker;
  final DialogService _dialogs;

  /// Read per run, never cached: this model is app-scoped and outlives any visit
  /// to Settings, so a value read in the constructor would go stale the moment the
  /// user changed it.
  final SettingsStore _settings;

  /// Also read per run — the target can change, or be unplugged, between runs.
  final DeviceSelection _devices;

  /// The phases this flow reports, for the stepper to label itself from.
  static const ProgressSchedule schedule = ProgressSchedule.liveContainer;

  LiveContainerStatus? _status;
  bool _isLoading = false;
  bool _isRunning = false;
  String? _error;

  SideloadProgressState _progress = const SideloadProgressState();
  LiveContainerSetupResult? _result;
  String? _failureMessage;

  List<GuestApp> _guests = const <GuestApp>[];
  bool _isAdding = false;
  String? _removingBundleId;
  String? _guestProgress;
  String? _guestNotice;

  /// What the device says, or null before the first look.
  LiveContainerStatus? get status => _status;

  /// Whether a status read is in flight.
  bool get isLoading => _isLoading;

  /// Whether a setup is running, so the button should be busy and inputs frozen.
  bool get isRunning => _isRunning;

  /// A status-read failure, which is not the same as a setup failure.
  String? get error => _error;

  /// Live progress of the current or most recent run.
  SideloadProgressState get progress => _progress;

  /// The stepper is worth drawing once a run has started, and stays afterwards so
  /// the finished state remains readable.
  bool get showStepper => _isRunning || _result != null || _failureMessage != null;

  /// The outcome of the last completed run.
  LiveContainerSetupResult? get result => _result;

  /// Why the last run failed, or null.
  String? get failureMessage => _failureMessage;

  /// Whether the run finished and installed.
  bool get isSucceeded => _result?.isInstalled ?? false;

  /// Whether the last run failed.
  bool get isFailed => _failureMessage != null;

  /// Whether LiveContainer is on the device, as far as the last read knows.
  bool get isInstalled => _status?.installed ?? false;

  /// Whether the user still has to open LiveContainer to finish the import.
  ///
  /// True from either direction: a run that just staged an import, or a status
  /// read that found one still waiting from an earlier run.
  bool get needsLaunch =>
      (_result?.launchRequired ?? false) || (_status?.certificatePending ?? false);

  /// What the user has to do by hand, when the certificate could not be imported
  /// automatically. Null when nothing is needed.
  String? get manualInstructions {
    final LiveContainerCertificate? certificate = _result?.certificate;
    if (certificate == null || certificate.automatic) return null;
    return certificate.instructions;
  }

  /// The apps running inside LiveContainer. None of them uses an app slot.
  List<GuestApp> get guests => _guests;

  /// Whether an app is being copied in.
  bool get isAdding => _isAdding;

  /// Whether that app is being removed.
  bool isRemoving(String? bundleId) =>
      bundleId != null && _removingBundleId == bundleId;

  /// Live text while an app is being copied in, e.g. `340 / 844 files · 30 / 105 MB`.
  String? get guestProgress => _guestProgress;

  /// The outcome of the last add or remove.
  String? get guestNotice => _guestNotice;

  /// Whether anything is in flight, so the list should be frozen.
  bool get isGuestBusy => _isAdding || _removingBundleId != null;

  /// Whether this build carries SideStore, and so can refresh on the phone itself.
  bool get hasSideStore => _status?.hasSidestore ?? false;

  /// Whether the pairing file that on-device refresh needs is on the device.
  bool get isPaired => _status?.pairingPresent ?? false;

  void dismissGuestNotice() {
    if (_guestNotice == null) return;
    _guestNotice = null;
    notify();
  }

  /// Reads the device's LiveContainer state.
  Future<void> load() async {
    if (_isLoading) return;
    _isLoading = true;
    _error = null;
    notify();

    try {
      final String? udid = await _devices.targetUdid();
      final String? connection = _devices.connectionArg;
      _status = await _engine.liveContainerStatus(
        udid: udid,
        connection: connection,
      );
      // Only worth asking about the apps inside it once we know it is there; the engine
      // would refuse anyway, and an error about a missing LiveContainer is not news on a
      // screen that has just said it is not installed.
      _guests = (_status?.installed ?? false)
          ? await _engine.liveContainerGuests(udid: udid, connection: connection)
          : const <GuestApp>[];
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _error = BaseViewModel.errorText(error);
      }
    } finally {
      _isLoading = false;
      notify();
    }

  }

  /// Picks an IPA and puts it inside LiveContainer rather than on the phone.
  ///
  /// No provisioning, no signing and no app slot: LiveContainer signs it on device with
  /// the certificate it already holds. That is the whole reason to run an app this way.
  Future<void> addGuest() async {
    if (isGuestBusy || !isInstalled) return;

    final String? path = await _picker.pickIpa();
    if (path == null) return;

    _isAdding = true;
    _guestNotice = null;
    _guestProgress = 'Reading the app\u2026';
    notify();

    try {
      final GuestAppInstall result = await _engine.installGuestApp(
        path,
        udid: await _devices.targetUdid(),
        connection: _devices.connectionArg,
        onProgress: (SideloadProgress progress) {
          final String? step = progress.step;
          if (step == null || step.isEmpty) return;
          _guestProgress = step;
          notify();
        },
      );
      _guestNotice = 'Added ${result.name ?? result.bundleId}. Open LiveContainer and '
          'it will sign it on first launch.';
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _guestNotice = BaseViewModel.errorText(error);
      }
    } finally {
      _isAdding = false;
      _guestProgress = null;
      notify();
    }
    await load();
  }

  /// Removes an app from inside LiveContainer, after asking.
  Future<void> removeGuest(GuestApp guest) async {
    final String? bundleId = guest.bundleId;
    if (bundleId == null || isGuestBusy) return;

    final bool confirmed = await _dialogs.confirm(
      title: 'Remove from LiveContainer?',
      message: '$bundleId will be deleted from inside LiveContainer, along with '
          'anything it stored. Nothing on your phone itself is touched.',
      confirmLabel: 'Remove',
      cancelLabel: 'Keep it',
      danger: true,
    );
    if (!confirmed) return;

    _removingBundleId = bundleId;
    _guestNotice = null;
    notify();

    try {
      await _engine.removeGuestApp(
        bundleId,
        udid: await _devices.targetUdid(),
        connection: _devices.connectionArg,
      );
      _guestNotice = 'Removed $bundleId.';
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _guestNotice = BaseViewModel.errorText(error);
      }
    } finally {
      _removingBundleId = null;
      notify();
    }
    await load();
  }

  /// Downloads, signs, installs LiveContainer and hands it the certificate.
  ///
  /// Sends the user to sign-in first when there is no session, because every step
  /// after the download needs Apple: there is no point downloading 4 MB to fail.
  Future<void> setUp() async {
    if (_isRunning) return;

    // Claimed before the first await, not after the sign-in probe: the button is
    // disabled while a run is on, but the guard has to hold on its own, or two
    // calls in the same frame would both get past it and install twice.
    _result = null;
    _failureMessage = null;
    _isRunning = true;
    _progress = SideloadProgressState.starting;
    notify();

    try {
      LoginStatus? login;
      try {
        login = await _engine.loginStatus();
      } catch (error) {
        if (BaseViewModel.isShutdown(error)) return;
        // A failed probe counts as signed out.
      }
      if (login == null || !login.authenticated) {
        _navigation.navigateTo(NavKey.signIn);
        return;
      }

      final SignedIpaSettings signed = _settings.loadSignedIpa();
      _result = await _engine.liveContainerSetup(
        udid: await _devices.targetUdid(),
        connection: _devices.connectionArg,
        keepSigned: signed.keep,
        signedDirectory: signed.directory,
        onProgress: _onProgress,
      );
      if (_result!.isInstalled) {
        _progress = _progress.completed(
          stepText: 'Installed',
          schedule: schedule,
        );
      }
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _failureMessage = BaseViewModel.errorText(error);
      }
    } finally {
      _isRunning = false;
      notify();
    }

    // Re-read rather than infer: the run reports what it did, the device reports
    // what is true, and only the second knows whether an import is still waiting.
    await load();
  }

  void _onProgress(SideloadProgress progress) {
    final SideloadProgressState next =
        _progress.apply(progress, schedule: schedule);
    if (next == _progress) return; // a phase this flow does not draw
    _progress = next;
    notify();
  }
}
