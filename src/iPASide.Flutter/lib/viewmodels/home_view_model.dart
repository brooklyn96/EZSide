import '../engine/engine.dart';
import '../ui/shell/nav_destination.dart';
import 'base_view_model.dart';
import 'device_selection.dart';
import 'navigation_state.dart';

/// Home: three cards describing the phone an install would go to.
///
/// Device shows the lockdown identity from `device-info` (or the "no device"
/// empty state), Apple ID shows the session from `login --status`, and
/// Connection summarises the USB / Wi-Fi transports of the selected device. Each
/// card owns its own spinner, cleaned error and empty state, so one failing
/// engine call never blanks the screen.
///
/// Pairing lives in Settings: it is a standing file for this PC and the selected
/// phone, not something Home has to summarise on every visit.
///
/// All three status cards follow [DeviceSelection]. Retargeting from the sidebar
/// reloads the device card and re-derives the connection card, because a card
/// that keeps describing the phone that was selected when the screen opened is
/// worse than no card: it reads as the state of the device the user just chose.
class HomeViewModel extends BaseViewModel {
  HomeViewModel({
    required this._engine,
    required this._navigation,
    required this._devices,
  }) {
    _devices.addListener(_onSelectionChanged);
    // Independent loads: the account is not about a device and must not wait on one.
    _loadDevice();
    _loadAccount();
  }

  static const _dash = '\u2014';

  final EngineApi _engine;
  final NavigationState _navigation;
  final DeviceSelection _devices;

  @override
  void dispose() {
    _devices.removeListener(_onSelectionChanged);
    super.dispose();
  }

  // ---- Device card ----

  bool _isDeviceLoading = true;
  String? _deviceError;
  bool _hasDevice = false;
  String deviceName = '';
  String deviceModel = '';
  String deviceIos = '';
  String deviceUdid = '';

  /// The (device, transport) pair the device card currently describes.
  ///
  /// Compared against the selection on every notification so that the many
  /// notifications which change neither — a refresh starting, names arriving —
  /// do not each cost a `device-info` round trip.
  String? _shownUdid;
  String? _shownConnection;

  /// Increments per load so a slow answer for a device the user has already
  /// moved on from is dropped instead of overwriting the newer one.
  int _deviceLoadToken = 0;

  bool get isDeviceLoading => _isDeviceLoading;
  String? get deviceError => _deviceError;
  bool get hasDevice => _hasDevice;
  bool get hasDeviceError => _deviceError != null;
  bool get isDeviceEmpty => !_isDeviceLoading && _deviceError == null && !_hasDevice;

  // ---- Apple ID card ----

  bool _isAccountLoading = true;
  String? _accountError;
  bool _isAuthenticated = false;
  String accountEmail = '';

  bool get isAccountLoading => _isAccountLoading;
  String? get accountError => _accountError;
  bool get isAuthenticated => _isAuthenticated;
  bool get hasAccountError => _accountError != null;
  bool get isAccountSignedOut =>
      !_isAccountLoading && _accountError == null && !_isAuthenticated;

  // ---- Connection card ----
  //
  // Read straight off DeviceSelection instead of a second `devices` call of its
  // own. The picker already enumerates, and two independent enumerations is how
  // this card came to say a phone was reachable over Wi-Fi while the sidebar had
  // a USB-only one selected. One enumeration cannot disagree with itself, and it
  // costs a round trip fewer per visit.

  bool get isConnectionLoading => !_devices.hasLoaded;
  String? get connectionError => _devices.error;
  bool get hasConnectionError => _devices.hasError;
  bool get hasVisibleDevice => _devices.selected != null;
  bool get isConnectionEmpty =>
      _devices.hasLoaded && !_devices.hasError && _devices.selected == null;

  /// `connected` / `available` for a transport the selected device is on, and an
  /// em dash for one it is not.
  String get usbText => _transportText('USB', 'connected');
  String get wifiText => _transportText('Network', 'available');

  String _transportText(String transport, String present) {
    final DeviceTarget? target = _devices.selected;
    if (target == null) return _dash;
    return target.transports.contains(transport) ? present : _dash;
  }

  // ---- Commands ----

  Future<void> signOut() async {
    try {
      await _engine.logout();
    } on EngineShutdownException {
      return; // the app is closing
    } catch (error) {
      _accountError = BaseViewModel.errorText(error);
      notify();
      return;
    }
    // Re-navigating Home remounts the screen, which reloads all three cards.
    _navigation.navigateTo(NavKey.home);
  }

  void signIn() => _navigation.navigateTo(NavKey.signIn);
  void openSideload() => _navigation.navigateTo(NavKey.sideload);
  void openLibrary() => _navigation.navigateTo(NavKey.library);
  void openApps() => _navigation.navigateTo(NavKey.apps);
  void openDiagnostics() => _navigation.navigateTo(NavKey.diagnostics);

  // ---- Loads ----

  Future<void> _loadDevice() async {
    final int token = ++_deviceLoadToken;
    // Home is built on launch, before the shared enumeration has answered, so
    // the target is awaited rather than read: without that this is the one call
    // in the app that reliably goes out with no UDID.
    final String? udid = await _devices.targetUdid();
    final String? connection = _devices.connectionArg;
    if (isDisposed || token != _deviceLoadToken) return;
    _shownUdid = udid;
    _shownConnection = connection;

    try {
      final info = await _engine.deviceInfo(udid: udid, connection: connection);
      if (token != _deviceLoadToken) return; // retargeted while this was in flight

      // The engine returns an empty object when nothing is paired, which
      // parses to a record whose consumed fields are all null.
      final present = info.deviceName != null ||
          info.productType != null ||
          info.productVersion != null ||
          info.buildVersion != null ||
          info.uniqueDeviceId != null;
      if (present) {
        deviceName = info.deviceName ?? '';
        deviceModel = info.productType ?? '';
        deviceIos = '${info.productVersion ?? '?'} (${info.buildVersion ?? '?'})';
        deviceUdid = shortId(info.uniqueDeviceId);
        _hasDevice = true;
      }
    } catch (error) {
      if (token != _deviceLoadToken) return;
      if (!BaseViewModel.isShutdown(error)) {
        _deviceError = BaseViewModel.errorText(error);
      }
    } finally {
      if (token == _deviceLoadToken) {
        _isDeviceLoading = false;
        notify();
      }
    }
  }

  /// Re-reads the device card when the selection moves, and repaints regardless.
  ///
  /// The repaint is not incidental: the connection card is derived from
  /// [DeviceSelection], and this model is the only thing the screen watches, so
  /// without it the transports would go stale even though nothing was loading.
  void _onSelectionChanged() {
    if (isDisposed) return;

    final String? udid = _devices.selectedUdid;
    final String? connection = _devices.connectionArg;
    if (udid == _shownUdid && connection == _shownConnection) {
      notify();
      return;
    }

    _deviceError = null;
    _hasDevice = false;
    deviceName = '';
    deviceModel = '';
    deviceIos = '';
    deviceUdid = '';
    _isDeviceLoading = true;
    notify();
    _loadDevice();
  }

  Future<void> _loadAccount() async {
    try {
      final status = await _engine.loginStatus();
      if (status.authenticated) {
        accountEmail = status.email ?? '';
        _isAuthenticated = true;
      }
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _accountError = BaseViewModel.errorText(error);
      }
    } finally {
      _isAccountLoading = false;
      notify();
    }
  }

  /// Shortens a UDID to `8 chars … last 4`, leaving short ids untouched.
  static String shortId(String? id) {
    if (id == null || id.isEmpty) return '';
    return id.length > 14 ? '${id.substring(0, 8)}\u2026${id.substring(id.length - 4)}' : id;
  }
}
