import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app_version.dart';
import 'engine/engine.dart';
import 'platform/app_paths.dart';
import 'platform/background_refresh_scheduler.dart';
import 'platform/reduced_motion.dart';
import 'platform/single_instance.dart';
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
import 'viewmodels/jailbreak_view_model.dart';
import 'viewmodels/navigation_state.dart';
import 'viewmodels/live_container_view_model.dart';
import 'viewmodels/sideload_view_model.dart';
import 'viewmodels/theme_controller.dart';
import 'viewmodels/update_view_model.dart';

Future<void> main(List<String> args) async {
  // The scheduled daily refresh runs headless and must never build a window.
  if (AutoRefreshRunner.isRequested(args)) {
    exit(await AutoRefreshRunner.run());
  }

  WidgetsFlutterBinding.ensureInitialized();

  // Held for the whole process so the installer's AppMutex check sees a
  // running app and refuses to overwrite it.
  final marker = RunningAppMarker.hold();

  final guard = createSingleInstanceGuard();
  if (!guard.tryAcquire()) {
    // A second launch exits silently rather than raising the existing window,
    // matching the previous build.
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
    title: 'iPASide',
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
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
    ),
  );
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
  });

  final EngineClient engineClient;
  final ThemeController themeController;

  /// The one settings store; the theme controller already holds it, and Settings
  /// reads and writes the rest of the file through it.
  final SettingsStore settings;
  final StartupOptions startup;
  final bool reducedMotion;

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

  /// App-scoped for the same reason as the LiveContainer session: installing a
  /// jailbreak is a download, a sign and an install, and navigating away mid-run must
  /// not throw the progress or the outcome away.
  late final JailbreakViewModel _jailbreak = JailbreakViewModel(
    engine: _engine,
    navigation: _navigation,
    settings: widget.settings,
    devices: _devices,
  );

  late final DropRouter _dropRouter = DropRouter(
    navigation: _navigation,
    target: _sideload,
  );

  late final UpdateViewModel _updates = UpdateViewModel(
    service: UpdateService(currentVersion: resolvedAppVersion),
    // Same tear-down as the window Close button: hide first, then end the
    // engine, then destroy. The silent installer is already running and waits
    // on AppMutex until this process exits.
    exitForUpdate: () => runShutdownSequence(
      hideWindow: windowManager.hide,
      disposeEngine: widget.engineClient.dispose,
      destroyWindow: windowManager.destroy,
    ),
  );

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // Intercept the close so the engine is shut down before the window dies.
    windowManager.setPreventClose(true);
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
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _updates.dispose();
    _dropRouter.dispose();
    _sideload.dispose();
    _liveContainer.dispose();
    _jailbreak.dispose();
    _appleSupport.dispose();
    _devices.dispose();
    _navigation.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() => unawaited(
        runShutdownSequence(
          hideWindow: windowManager.hide,
          disposeEngine: widget.engineClient.dispose,
          destroyWindow: windowManager.destroy,
        ),
      );

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
        ChangeNotifierProvider<NavigationState>.value(value: _navigation),
        ChangeNotifierProvider<ThemeController>.value(value: widget.themeController),
        ChangeNotifierProvider<DeviceSelection>.value(value: _devices),
        ChangeNotifierProvider<AccountSelection>.value(value: _accounts),
        ChangeNotifierProvider<AppleSupportViewModel>.value(value: _appleSupport),
        ChangeNotifierProvider<SideloadViewModel>.value(value: _sideload),
        ChangeNotifierProvider<LiveContainerViewModel>.value(
          value: _liveContainer,
        ),
        ChangeNotifierProvider<JailbreakViewModel>.value(value: _jailbreak),
        ChangeNotifierProvider<DropRouter>.value(value: _dropRouter),
        ChangeNotifierProvider<UpdateViewModel>.value(value: _updates),
      ],
      child: Consumer<ThemeController>(
        builder: (context, theme, _) => MaterialApp(
          title: 'iPASide',
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
