import '../engine/engine.dart';
import '../services/installer_launcher.dart';
import 'base_view_model.dart';

/// Whether this machine has the Apple stack iPASide needs, and the way to get it.
///
/// App-scoped, and the only place that asks: Home, Sideload and Diagnostics all
/// read this one model, so they cannot contradict each other, and a download
/// started on one screen is still running when the user walks to another.
///
/// The two remedies are deliberately different commands, because the two problems
/// are: a stopped service is started (which needs administrator rights, and being
/// refused them is a normal answer), while a missing one needs ~200 MB of iTunes
/// downloaded, verified, and then run by the user. Nothing is launched until the
/// engine has confirmed Apple signed it.
class AppleSupportViewModel extends BaseViewModel {
  AppleSupportViewModel({required this._engine, required this._launcher});

  final EngineApi _engine;
  final InstallerLauncher _launcher;

  AppleSupportStatus? _status;
  bool _isChecking = false;
  bool _hasChecked = false;
  bool _isDownloading = false;
  bool _isStarting = false;
  bool _installerRunning = false;
  double _percent = 0;
  String? _step;
  String? _problem;

  /// The engine's last answer, or null before the first one lands.
  AppleSupportStatus? get status => _status;

  /// A status probe is in flight.
  bool get isChecking => _isChecking;

  /// Whether anything is in flight, so the buttons can hold still.
  bool get isBusy => _isChecking || _isDownloading || _isStarting;

  bool get isDownloading => _isDownloading;

  bool get isStartingService => _isStarting;

  /// 0–100 for the download, matching `AppProgressBar`'s scale.
  double get percent => _percent;

  /// The live sub-step, e.g. `Downloading iTunes · 42.0 MB of 198.4 MB`.
  String? get step => _step;

  /// A failed download or service start, already cleaned for display.
  String? get problem => _problem;

  /// The installer has been handed to the user and is running outside the app.
  bool get installerRunning => _installerRunning;

  /// Apple's service is up; nothing here needs saying.
  bool get isReady => _status?.isRunning ?? false;

  /// This machine cannot reach an iPhone until something is done about it.
  ///
  /// False until the first answer arrives, and false for a state this build does
  /// not recognise: blocking a working machine over a word we cannot read would be
  /// worse than saying nothing.
  bool get blocksDevices => _status?.blocksDevices ?? false;

  bool get isMissing => _status?.isMissing ?? false;

  bool get isStopped => _status?.isStopped ?? false;

  /// Whether the banner has anything to show.
  bool get hasNotice => blocksDevices && _hasChecked;

  bool get canDownload => isMissing && !isBusy && !_installerRunning;

  bool get canStartService => isStopped && !isBusy;

  /// Whether a re-check is worth offering, i.e. something outside the app may
  /// have changed the answer.
  bool get canRecheck => !isBusy;

  /// The banner's headline.
  String get title {
    if (isMissing) {
      // Two very different situations: a machine that never had the Apple stack,
      // and one whose iTunes has lost its service and needs repairing.
      return _status?.itunesInstalled == true
          ? "Apple's device service is missing"
          : "Windows can't reach an iPhone yet";
    }
    if (isStopped) return "Apple's device service isn't running";
    return 'Apple device support';
  }

  /// The banner's explanation: the engine's own sentence, plus what pressing the
  /// button will do about it.
  ///
  /// The engine writes the diagnosis because it is the thing that looked; the
  /// consequence is added here because only the app knows what it is offering.
  String get message {
    if (_installerRunning) {
      return 'The iTunes installer is running. When it finishes, check again \u2014 '
          'iPASide will see your iPhone without a restart.';
    }
    final String detail = _status?.detail ?? '';
    if (isMissing) {
      return '$detail iPASide can download it from Apple '
          '(about 200 MB) and verify Apple signed it before running it.';
    }
    return detail;
  }

  /// Why USB is unavailable, for a screen that has to explain a blank field;
  /// null when Apple's service is not the reason.
  String? get usbBlockedReason {
    if (isMissing) return "Apple's device service isn't installed.";
    if (isStopped) return "Apple's device service isn't running.";
    return null;
  }

  /// Why no device is visible, for a screen that would otherwise tell the user to
  /// plug in a cable they have already plugged in; null when that advice is right.
  String? get deviceBlockedMessage {
    if (isMissing) {
      return "Apple's device service isn't installed, so Windows "
          'cannot reach an iPhone at all \u2014 over USB or Wi-Fi.';
    }
    if (isStopped) {
      return "Apple's device service isn't running, so Windows "
          'cannot reach an iPhone right now.';
    }
    return null;
  }

  /// Re-reads the status, dropping any stale failure.
  ///
  /// Also what runs after the installer is launched, so the app reflects reality
  /// without being restarted.
  Future<void> refresh() async {
    if (_isChecking) return;
    _isChecking = true;
    _problem = null;
    notify();

    try {
      final AppleSupportStatus status = await _engine.appleSupport();
      _status = status;
      _hasChecked = true;
      // A service that came up while the installer was running has nothing left
      // to wait for, so the "check again" state retires itself.
      if (status.isRunning) _installerRunning = false;
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _problem = BaseViewModel.errorText(error);
      }
    } finally {
      _isChecking = false;
      notify();
    }
  }

  /// Downloads and verifies Apple's iTunes installer, then launches it.
  ///
  /// The launch is strictly downstream of the verification: the engine raises
  /// rather than returning a path for anything it could not prove Apple signed, so
  /// there is no branch here that can run an unverified file.
  Future<void> installItunes() async {
    if (_isDownloading || _isStarting) return;
    _isDownloading = true;
    _problem = null;
    _percent = 0;
    _step = 'Contacting Apple\u2026';
    notify();

    try {
      final ItunesDownload download = await _engine.downloadItunes(
        onProgress: _onProgress,
      );
      final String? path = download.path;
      if (path == null || path.isEmpty) {
        _problem = 'The engine did not say where it saved the installer.';
        return;
      }

      _step = 'Starting the installer\u2026';
      notify();

      if (await _launcher.launch(path)) {
        _installerRunning = true;
      } else {
        _problem = 'The installer was downloaded and verified, but Windows would '
            'not start it. You can run it yourself: $path';
      }
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        // Already a sentence: no internet, a download that stopped, or a
        // signature that did not belong to Apple.
        _problem = BaseViewModel.errorText(error);
      }
    } finally {
      _isDownloading = false;
      _step = null;
      notify();
    }

    // Whatever happened, ask again rather than assuming: the user may have
    // completed the install before this line runs.
    if (_installerRunning) await refresh();
  }

  /// Asks Windows to start Apple's service, which raises a UAC prompt.
  ///
  /// Declining it is not a failure — it leaves the banner exactly as it was, with
  /// its reason attached, rather than posting an error about something the user
  /// chose.
  Future<void> startService() async {
    if (_isStarting || _isDownloading) return;
    _isStarting = true;
    _problem = null;
    notify();

    try {
      final AppleServiceStart result = await _engine.startAppleService();
      final AppleSupportStatus? after = result.status;
      if (after != null) {
        _status = after;
        _hasChecked = true;
      }
      if (!result.started) {
        _problem = result.detail ??
            'Apple Mobile Device Service could not be started.';
      }
      if (after == null) {
        // A payload without its status is not something to guess at.
        await refresh();
      }
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _problem = BaseViewModel.errorText(error);
      }
    } finally {
      _isStarting = false;
      notify();
    }
  }

  void _onProgress(SideloadProgress progress) {
    final double? percent = progress.percent;
    final String? step = progress.step;
    if (percent == null && step == null) return;
    if (percent != null) _percent = percent.clamp(0, 100);
    if (step != null && step.isNotEmpty) _step = step;
    notify();
  }
}
