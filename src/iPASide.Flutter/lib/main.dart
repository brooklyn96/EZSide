import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app_version.dart';
import 'engine/auto_refresh_status.dart';
import 'engine/engine.dart';
import 'platform/app_paths.dart';
import 'platform/background_refresh_scheduler.dart';
import 'platform/native_dialog.dart';
import 'platform/reduced_motion.dart';
import 'platform/single_instance.dart';
import 'platform/startup_registration.dart';
import 'platform/tray_service.dart';
import 'platform/windows_child_process_reaper.dart';
import 'services/auto_refresh_runner.dart';
import 'services/file_picker.dart';
import 'services/icon_cache.dart';
import 'services/installer_launcher.dart';
import 'services/settings_store.dart';
import 'services/startup_query.dart';
import 'services/update_service.dart';
import 'ui/shell/app_dialogs.dart';
import 'ui/shell/app_shell.dart';
import 'ui/theme/app_theme.dart';
import 'ui/widgets/motion.dart';
import 'viewmodels/account_selection.dart';
import 'viewmodels/apple_support_view_model.dart';
import 'viewmodels/device_selection.dart';
import 'viewmodels/drop_router.dart';
import 'viewmodels/navigation_state.dart';
import 'viewmodels/live_container_view_model.dart';
import 'viewmodels/sideload_view_model.dart';
import 'viewmodels/theme_controller.dart';
import 'viewmodels/update_view_model.dart';

Future<void> main(List<String> args) async {
  // The scheduled hourly refresh runs headless and must never build a window.
  if (AutoRefreshRunner.isRequested(args)) {
    exit(await AutoRefreshRunner.run());
  }

  WidgetsFlutterBinding.ensureInitialized();

  // The Run-key launch at sign-in: tray icon only, no window. The runner reads
  // the same argument so the first frame does not show the window either.
  final bool startHidden = args.any(
    (String argument) =>
        argument.toLowerCase() == StartupRegistration.trayArg,
  );

  // Held for the whole process so the installer's AppMutex check sees a
  // running app and refuses to overwrite it.
  final marker = RunningAppMarker.hold();

  // From the moment the mutex is held, a scheduled run leaves its failure
  // notice to this process, so the baseline is taken before the mutex is: a
  // run that finishes in between is then newer than the baseline and ours to
  // report. One that checked the mutex before it was held showed its own box
  // and claimed the stamp, so it is not reported twice.
  final AutoRefreshWatch refreshWatch = AutoRefreshWatch(
    logPath: AppPaths.instance.autoRefreshLogPath,
    claimNotice: () => AutoRefreshRunner.claimNotice(),
  );

  final guard = createSingleInstanceGuard();
  if (!guard.tryAcquire()) {
    // A second launch raises the running window, then exits. One from the Run
    // key has nothing to show: the app is already in the tray.
    if (!startHidden) showRunningInstance();
    marker.dispose();
    exit(0);
  }

  AppPaths.instance.ensureRootExists();

  // One store for the whole process: every setting lives in the same file, so
  // two of them would race each other's read-modify-write.
  final settings = SettingsStore();
  final themeController = ThemeController(store: settings);
  final startup = StartupQuery.fromEnvironment();
  final themeOverride = startup.themeOverride;
  if (themeOverride != null) {
    // Harness runs apply a theme for the session without rewriting the choice.
    themeController.setMode(themeOverride, persist: false);
  }

  // Resolving the launch spec now surfaces bad configuration early; the engine
  // process itself starts in the background.
  final engineClient = EngineClient(
    locator: EngineLocator(),
    reaper: createChildProcessReaper(),
  );
  engineClient.prewarm();

  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(Sizes.windowWidth, Sizes.windowHeight),
    minimumSize: Size(Sizes.windowMinWidth, Sizes.windowMinHeight),
    center: true,
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.hidden,
    title: 'EZSide',
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    if (startHidden) return;
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(
    IpaSideApp(
      engineClient: engineClient,
      themeController: themeController,
      settings: settings,
      startup: startup,
      reducedMotion: createReducedMotionProvider().isReducedMotion(),
      startHidden: startHidden,
      refreshWatch: refreshWatch,
    ),
  );
}

/// Tells the user that [run] failed: as a balloon from the tray icon when
/// [balloon] can show one, else as the box the headless run shows when no GUI
/// is open. Same words either way.
Future<void> announceRefreshFailure(
  AutoRefreshRun run, {
  required Future<bool> Function(String title, String body) balloon,
  required Future<void> Function(String title, String body) box,
}) async {
  final String body = AutoRefreshRunner.failureText(run.failedApps);
  if (await balloon('EZSide', body)) return;
  await box('EZSide', body);
}

/// The warning box, on its own isolate: it blocks until closed, and the window
/// must keep drawing meanwhile.
Future<void> _showBoxOffThread(String title, String body) =>
    Isolate.run(() => showWarningNotice(title, body));

/// Brings the window back from the tray, a minimize, or behind other windows.
Future<void> showMainWindow() async {
  await windowManager.show();
  if (await windowManager.isMinimized()) await windowManager.restore();
  await windowManager.focus();
}

/// Tears the app down in the order the user feels it: the window disappears
/// first, the engine is ended after.
///
/// Hiding first is what makes a close look instant. Ending the engine politely
/// is fast (it acknowledges the shutdown frame in well under a tenth of a
/// second) but it is not free, and nobody should watch the window sit there
/// while it happens. [destroyWindow] runs even if the engine misbehaves, so a
/// hidden process can never outlive its window; the job object in
/// [WindowsChildProcessReaper] then reaps the engine with us regardless.
///
/// Kept out of the widget so the ordering - the part that decides how fast a
/// close *looks* - is testable without a window.
Future<void> runShutdownSequence({
  required Future<void> Function() hideWindow,
  required Future<void> Function() disposeEngine,
  required Future<void> Function() destroyWindow,
}) async {
  try {
    await hideWindow();
    await disposeEngine();
  } finally {
    await destroyWindow();
  }
}

/// Root widget: owns the shared services and the app-scoped view models.
class IpaSideApp extends StatefulWidget {
  const IpaSideApp({
    super.key,
    required this.engineClient,
    required this.themeController,
    required this.settings,
    required this.startup,
    required this.reducedMotion,
    this.startHidden = false,
    required this.refreshWatch,
  });

  final EngineClient engineClient;
  final ThemeController themeController;

  /// The one settings store; the theme controller already holds it, and Settings
  /// reads and writes the rest of the file through it.
  final SettingsStore settings;
  final StartupOptions startup;
  final bool reducedMotion;

  /// Launched with `--tray`: the window stays hidden until the tray opens it.
  final bool startHidden;

  /// Reads what the scheduled task's runs wrote; the app never runs a refresh
  /// timer of its own. Built in [main] as soon as the mutex is held.
  final AutoRefreshWatch refreshWatch;

  @override
  State<IpaSideApp> createState() => _IpaSideAppState();
}

class _IpaSideAppState extends State<IpaSideApp> with WindowListener {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final NavigationState _navigation = NavigationState();
  final IconCache _icons = IconCache();
  final FilePickerService _picker = const NativeFilePickerService();

  late final EngineApi _engine = EngineApi(widget.engineClient);
  late final DialogService _dialogs = DialogService(_navigatorKey);
  late final BackgroundRefreshScheduler _scheduler = createBackgroundRefreshScheduler();

  /// App-scoped because the device being acted on belongs to the session, not to
  /// one screen: Sideload installs to it, Apps lists it, Home describes it, and
  /// all three have to agree.
  late final DeviceSelection _devices = DeviceSelection(
    engine: _engine,
    settings: widget.settings,
  );

  /// App-scoped for the same reason as the device: more than one Apple ID can be
  /// signed in, and Home, Sideload and Settings must agree on which one is in use.
  late final AccountSelection _accounts = AccountSelection(engine: _engine);

  /// App-scoped for the same reason, plus one of its own: Home, Sideload and
  /// Diagnostics all report whether Apple's device service is there, and a ~200 MB
  /// download started from one of them has to survive walking to another.
  late final AppleSupportViewModel _appleSupport = AppleSupportViewModel(
    engine: _engine,
    launcher: const ProcessInstallerLauncher(),
  );

  /// App-scoped so the sideload session survives navigation.
  late final SideloadViewModel _sideload = SideloadViewModel(
    engine: _engine,
    navigation: _navigation,
    dialogs: _dialogs,
    picker: _picker,
    icons: _icons,
    settings: widget.settings,
    devices: _devices,
  );

  /// App-scoped for the same reason as the sideload session: setting LiveContainer
  /// up is a download, a sign and an install, and navigating away mid-run must not
  /// throw the progress or the outcome away.
  late final LiveContainerViewModel _liveContainer = LiveContainerViewModel(
    engine: _engine,
    navigation: _navigation,
    settings: widget.settings,
    devices: _devices,
    picker: _picker,
    dialogs: _dialogs,
  );

  late final DropRouter _dropRouter = DropRouter(
    navigation: _navigation,
    target: _sideload,
  );

  late final UpdateViewModel _updates = UpdateViewModel(
    service: UpdateService(currentVersion: resolvedAppVersion),
    // Same tear-down as tray Quit, minus the last notice. The silent installer
    // is already running and waits on AppMutex until this process exits.
    exitForUpdate: () => _quit(lastNotice: false),
  );

  final TrayService _tray = TrayService();
  final StartupRegistration _startupRegistration = StartupRegistration();
  final StartupStateSignal _startupSignal = StartupStateSignal();
  late final AutoRefreshWatch _refreshWatch = widget.refreshWatch;
  Timer? _refreshPoll;
  Future<void>? _quitting;

  /// How long a `--tray` launch waits for the shell to take the icon (it may
  /// still be starting at sign-in) before it shows the window instead.
  static const Duration _trayWait = Duration(minutes: 2);

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // Intercept the close: it hides into the tray, or, with no tray, shuts the
    // engine down before the window dies.
    windowManager.setPreventClose(true);
    // Whatever the tray does: with the GUI up, a failed run's notice is ours.
    _refreshPoll = Timer.periodic(
      AutoRefreshWatch.pollInterval,
      (_) => _pollRefreshLog(),
    );
    unawaited(_startTray());
    // A version comparison only — nothing is downloaded without being asked.
    _updates.check();
    // Live usbmux Attached/Detached first, then a one-shot listing so the first
    // paint is not waiting on Listen if the phone is already plugged in.
    _devices.startListening();
    _devices.refresh();
    // Which Apple IDs are signed in, so Home can name the one in use and offer the
    // others without a round trip when the user opens the menu.
    _accounts.refresh();
    // And ask whether Apple's device service is even there, because if it is not,
    // "no device connected" is the wrong thing for any screen to be saying.
    _appleSupport.refresh();
    // A task an older build registered as daily-noon becomes the hourly one.
    unawaited(refreshAutoRefreshTask(_scheduler));
  }

  @override
  void dispose() {
    _refreshPoll?.cancel();
    windowManager.removeListener(this);
    _updates.dispose();
    _dropRouter.dispose();
    _sideload.dispose();
    _liveContainer.dispose();
    _appleSupport.dispose();
    _devices.dispose();
    _navigation.dispose();
    super.dispose();
  }

  /// Close hides into the tray, and the engine keeps running so Listen, the
  /// remembered phones and Wi-Fi sync carry on. Only while no tray icon is
  /// there to come back through does Close quit.
  @override
  void onWindowClose() =>
      unawaited(_tray.isReady ? windowManager.hide() : _quit());

  /// The full tear-down, for tray Quit (menu or WM_CLOSE) and the updater
  /// only: the window and the icon disappear first, the engine is ended after.
  /// Runs once, however many of them ask.
  ///
  /// With [lastNotice], a run that failed since the last poll is still
  /// reported, as the box: a balloon would die with the icon. The updater
  /// passes false, because Setup is waiting on this process; the unread
  /// failure keeps its stamp unclaimed, so the next failing run reports it.
  Future<void> _quit({bool lastNotice = true}) =>
      _quitting ??= _shutDown(lastNotice: lastNotice);

  Future<void> _shutDown({required bool lastNotice}) async {
    try {
      await runShutdownSequence(
        hideWindow: () async {
          _refreshPoll?.cancel();
          final AutoRefreshRun? failed =
              lastNotice ? _refreshWatch.poll() : null;
          await _tray.dispose();
          await windowManager.hide();
          if (failed != null) {
            await announceRefreshFailure(
              failed,
              balloon: (_, _) async => false,
              box: _showBoxOffThread,
            );
          }
        },
        disposeEngine: widget.engineClient.dispose,
        destroyWindow: windowManager.destroy,
      );
    } catch (error) {
      // A step failed with the window hidden and the icon gone, so nothing is
      // left to reach this process through: end it. The job object takes the
      // engine with it.
      developer.log('quit: $error', name: 'ipaside.tray');
      exit(0);
    }
  }

  Future<void> _startTray() async {
    final bool ready = await _tray.init(
      onItem: _onTrayItem,
      onMenuOpening: _showStartupState,
    );
    await _tray.setStatus(_refreshWatch.statusLine);
    if (ready || !widget.startHidden) return;
    // Nothing to open a hidden window from yet: give the shell time to come
    // up, but never leave the window hidden with no way back to it.
    if (!_tray.isAvailable || !await _tray.waitUntilReady(_trayWait)) {
      await showMainWindow();
    }
  }

  void _onTrayItem(TrayMenuItem item) {
    switch (item) {
      case TrayMenuItem.open:
        unawaited(showMainWindow());
        _startupSignal.changed();
      case TrayMenuItem.refreshNow:
        unawaited(_refreshNow());
      case TrayMenuItem.startWithWindows:
        unawaited(_toggleStartup());
      case TrayMenuItem.quit:
        unawaited(_quit());
    }
  }

  void _pollRefreshLog() {
    final AutoRefreshRun? failed = _refreshWatch.poll();
    unawaited(_tray.setStatus(_refreshWatch.statusLine));
    if (failed != null) {
      unawaited(
        announceRefreshFailure(
          failed,
          balloon: _tray.showNotice,
          box: _showBoxOffThread,
        ),
      );
    }
  }

  /// The same unattended, due-only run as the scheduled task, as its own
  /// process; its result arrives through the log like any other run's.
  Future<void> _refreshNow() async {
    if (_refreshWatch.refreshing) return;
    try {
      await Process.start(
        Platform.resolvedExecutable,
        const <String>[AutoRefreshRunner.cliArgument],
        mode: ProcessStartMode.detached,
      );
    } on ProcessException catch (error) {
      developer.log('refresh now: $error', name: 'ipaside.tray');
      return;
    }
    _refreshWatch.manualStarted();
    await _tray.setStatus(_refreshWatch.statusLine);
  }

  Future<void> _toggleStartup() async {
    try {
      await _startupRegistration.setEnabled(
        !await _startupRegistration.isEnabled(),
      );
    } on StartupRegistrationException catch (error) {
      developer.log('start with Windows: $error', name: 'ipaside.tray');
    }
    _startupSignal.changed();
  }

  /// The real registry state, read each time the menu opens.
  Future<void> _showStartupState() async {
    bool on = false;
    try {
      on = await _startupRegistration.isEnabled();
    } on StartupRegistrationException {
      // Shown unchecked; the toggle reports nothing more than that.
    }
    await _tray.setStartupChecked(on);
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<EngineApi>.value(value: _engine),
        Provider<DialogService>.value(value: _dialogs),
        Provider<IconCache>.value(value: _icons),
        Provider<FilePickerService>.value(value: _picker),
        Provider<SettingsStore>.value(value: widget.settings),
        Provider<BackgroundRefreshScheduler>.value(value: _scheduler),
        Provider<StartupStateSignal>.value(value: _startupSignal),
        ChangeNotifierProvider<NavigationState>.value(value: _navigation),
        ChangeNotifierProvider<ThemeController>.value(value: widget.themeController),
        ChangeNotifierProvider<DeviceSelection>.value(value: _devices),
        ChangeNotifierProvider<AccountSelection>.value(value: _accounts),
        ChangeNotifierProvider<AppleSupportViewModel>.value(value: _appleSupport),
        ChangeNotifierProvider<SideloadViewModel>.value(value: _sideload),
        ChangeNotifierProvider<LiveContainerViewModel>.value(
          value: _liveContainer,
        ),
        ChangeNotifierProvider<DropRouter>.value(value: _dropRouter),
        ChangeNotifierProvider<UpdateViewModel>.value(value: _updates),
      ],
      child: Consumer<ThemeController>(
        builder: (context, theme, _) => MaterialApp(
          title: 'EZSide',
          debugShowCheckedModeBanner: false,
          navigatorKey: _navigatorKey,
          theme: buildAppTheme(Brightness.light),
          darkTheme: buildAppTheme(Brightness.dark),
          themeMode: theme.mode,
          home: UiOptions(
            reducedMotion: widget.reducedMotion,
            child: AppShell(startup: widget.startup),
          ),
        ),
      ),
    );
  }
}
