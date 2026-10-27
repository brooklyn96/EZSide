import 'dart:io';

import '../engine/engine.dart';
import '../services/settings_store.dart';
import '../ui/shell/nav_destination.dart';
import 'base_view_model.dart';
import 'device_selection.dart';
import 'navigation_state.dart';
import 'sideload_progress_state.dart';

/// Opens a web URL. Returns whether the launch was accepted.
typedef UrlLauncher = Future<bool> Function(String url);

/// The project page to fall back to if a tool's own URL is somehow missing.
const String _dopamineProjectUrl = 'https://github.com/opa334/Dopamine';

/// Opens [url] in the user's default browser, http/https only.
///
/// The scheme is checked before handing the string to ``cmd /c start`` so a stray
/// value can never steer it at an arbitrary scheme. Detached, like every other
/// hand-off iPASide makes to the OS.
Future<bool> _defaultLaunchUrl(String url) async {
  final Uri? parsed = Uri.tryParse(url.trim());
  if (parsed == null ||
      !parsed.hasScheme ||
      !(parsed.isScheme('https') || parsed.isScheme('http'))) {
    return false;
  }
  try {
    await Process.start(
      'cmd',
      <String>['/c', 'start', '', parsed.toString()],
      mode: ProcessStartMode.detached,
    );
    return true;
  } on Object {
    return false;
  }
}

/// The Jailbreak screen: advise on Dopamine compatibility, and install it.
///
/// Long-lived like the LiveContainer and Sideload sessions, for the same reason: an
/// install is a download, a sign and an install over USB, and navigating away mid-run
/// must not throw the progress or the outcome away.
///
/// iPASide is a sideloader, not a jailbreak. This screen only tells the user whether
/// Dopamine fits their device and, if it does, signs and installs Dopamine's app the
/// same way any other IPA is sideloaded. The jailbreak exploit runs on the phone when
/// the user opens Dopamine — iPASide never runs it.
class JailbreakViewModel extends BaseViewModel {
  JailbreakViewModel({
    required this._engine,
    required this._navigation,
    required this._settings,
    required this._devices,
    UrlLauncher? launchUrl,
  }) : _launchUrl = launchUrl ?? _defaultLaunchUrl;

  final EngineApi _engine;
  final NavigationState _navigation;

  /// Opens the tool's project page in a browser. Injected so tests can observe it.
  final UrlLauncher _launchUrl;

  /// Read per run, never cached: this model is app-scoped and outlives any visit to
  /// Settings, so a value read in the constructor would go stale when the user changed
  /// it.
  final SettingsStore _settings;

  /// Also read per run — the target device can change, or be unplugged, between runs.
  final DeviceSelection _devices;

  /// The phases an install reports, for the stepper to label itself from.
  static const ProgressSchedule schedule = ProgressSchedule.jailbreak;

  JailbreakAdvice? _advice;
  bool _isLoading = false;
  bool _isRunning = false;
  String? _error;

  SideloadProgressState _progress = const SideloadProgressState();
  JailbreakInstallResult? _result;
  String? _failureMessage;

  /// What the advisor concluded for the connected device, or null before the first read.
  JailbreakAdvice? get advice => _advice;

  /// Whether a compatibility read is in flight.
  bool get isLoading => _isLoading;

  /// Whether an install is running, so the button should be busy and inputs frozen.
  bool get isRunning => _isRunning;

  /// A read failure (could not reach the device), distinct from an install failure.
  String? get error => _error;

  /// Live progress of the current or most recent install.
  SideloadProgressState get progress => _progress;

  /// The stepper is worth drawing once an install has started, and stays afterwards so
  /// the finished state remains readable.
  bool get showStepper => _isRunning || _result != null || _failureMessage != null;

  /// The outcome of the last completed install.
  JailbreakInstallResult? get result => _result;

  /// Why the last install failed, or null.
  String? get failureMessage => _failureMessage;

  /// Whether the last install landed on the device.
  bool get isSucceeded => _result?.isInstalled ?? false;

  /// Whether the last install failed.
  bool get isFailed => _failureMessage != null;

  /// Whether the connected device can be installed to right now.
  bool get canInstall => _advice?.canInstall ?? false;

  /// The tool this screen installs (Dopamine), from the last advice.
  JailbreakTool? get tool => _advice?.tool;

  /// Reads the connected device and works out whether Dopamine fits it.
  Future<void> load() async {
    if (_isLoading) return;
    _isLoading = true;
    _error = null;
    notify();

    try {
      _advice = await _engine.jailbreakAdvice(
        udid: await _devices.targetUdid(),
        connection: _devices.connectionArg,
      );
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _error = BaseViewModel.errorText(error);
      }
    } finally {
      _isLoading = false;
      notify();
    }
  }

  /// Downloads the latest Dopamine, signs it, and installs it over USB.
  ///
  /// Sends the user to sign-in first when there is no session, because every step
  /// after the download needs Apple: there is no point downloading to fail. Refuses
  /// outright when the advisor says the device is not supported.
  Future<void> install() async {
    if (_isRunning || !canInstall) return;

    // Claimed before the first await so two calls in the same frame cannot both get
    // past the guard and install twice.
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
      _result = await _engine.installJailbreak(
        udid: await _devices.targetUdid(),
        connection: _devices.connectionArg,
        keepSigned: signed.keep,
        signedDirectory: signed.directory,
        onProgress: _onProgress,
      );
      if (_result!.isInstalled) {
        _progress = _progress.completed(stepText: 'Installed', schedule: schedule);
      }
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _failureMessage = BaseViewModel.errorText(error);
      }
    } finally {
      _isRunning = false;
      notify();
    }
  }

  /// Opens Dopamine's project page, where its full supported-device list lives.
  ///
  /// The one place a device iPASide cannot install to still has somewhere to go: the
  /// advisor is conservative about older and unknown chips on purpose, and the project
  /// page is the authoritative answer for those.
  Future<void> openProjectPage() async {
    final String url = _advice?.tool.projectUrl ?? _dopamineProjectUrl;
    await _launchUrl(url);
  }

  void _onProgress(SideloadProgress progress) {
    final SideloadProgressState next =
        _progress.apply(progress, schedule: schedule);
    if (next == _progress) return; // a phase this flow does not draw
    _progress = next;
    notify();
  }
}
