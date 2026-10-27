import '../engine/engine.dart';
import 'base_view_model.dart';

/// Which Apple ID iPASide is acting as, and the others it has signed in.
///
/// App-scoped and shared, like the device selection, because the account is a
/// property of the session rather than of whichever screen is open: a sideload
/// signs with it, Home describes it, Settings manages it.
///
/// A refresh deliberately does NOT use this. Each recorded sideload remembers the
/// team that signed it, and the engine re-signs under the account which provisions
/// for that team — re-signing an installed app with a different team's identity
/// leaves iOS unable to install it over the existing copy, so the app just stops
/// opening. Switching accounts here is therefore safe for apps already installed.
class AccountSelection extends BaseViewModel {
  /// Creates the selection over the engine. Nothing is loaded until [refresh].
  AccountSelection({required this._engine});

  final EngineApi _engine;

  List<AppleAccount> _accounts = const <AppleAccount>[];
  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _error;
  String? _busyEmail;

  /// Every signed-in Apple ID, most recent first. Read-only.
  List<AppleAccount> get accounts => _accounts;

  /// The account new sideloads will use, or null when none is signed in.
  AppleAccount? get active {
    for (final AppleAccount account in _accounts) {
      if (account.active) return account;
    }
    return null;
  }

  /// The address of [active], for convenience.
  String? get activeEmail => active?.email;

  /// Whether a load or a switch is in flight.
  bool get isLoading => _isLoading;

  /// Whether the first load has finished, either way.
  bool get hasLoaded => _hasLoaded;

  /// Cleaned failure text from the last operation, or null.
  String? get error => _error;

  /// Whether the last operation failed.
  bool get hasError => _error != null;

  /// Whether there is an actual choice to put in front of the user.
  ///
  /// False for a single account: a control that can only confirm what is already
  /// true is a control asking the user to do nothing.
  bool get hasChoice => _accounts.length > 1;

  /// The account currently being switched to or signed out, if any.
  String? get busyEmail => _busyEmail;

  /// Re-reads the signed-in accounts.
  ///
  /// A failure leaves the previous list in place rather than blanking it: a
  /// transient engine hiccup should not make the UI claim nobody is signed in.
  Future<void> refresh() async {
    if (_isLoading) return;
    _isLoading = true;
    notify();

    try {
      _accounts = await _engine.accounts();
      _error = null;
    } catch (error) {
      if (BaseViewModel.isShutdown(error)) return; // the app is closing
      _error = BaseViewModel.errorText(error);
    } finally {
      _isLoading = false;
      _hasLoaded = true;
      notify();
    }
  }

  /// Switches which account new sideloads use. No password: the session is cached.
  Future<void> use(String email) async {
    if (_busyEmail != null || email == activeEmail) return;
    _busyEmail = email;
    notify();
    try {
      await _engine.useAccount(email);
      _error = null;
    } catch (error) {
      if (BaseViewModel.isShutdown(error)) return;
      _error = BaseViewModel.errorText(error);
    } finally {
      _busyEmail = null;
      notify();
    }
    await refresh();
  }

  /// Signs one account out, leaving the others alone.
  Future<void> signOut(String email) async {
    if (_busyEmail != null) return;
    _busyEmail = email;
    notify();
    try {
      await _engine.logout(email: email);
      _error = null;
    } catch (error) {
      if (BaseViewModel.isShutdown(error)) return;
      _error = BaseViewModel.errorText(error);
    } finally {
      _busyEmail = null;
      notify();
    }
    await refresh();
  }

  /// Signs every account out.
  Future<void> signOutAll() async {
    if (_busyEmail != null) return;
    try {
      await _engine.logout();
      _error = null;
    } catch (error) {
      if (BaseViewModel.isShutdown(error)) return;
      _error = BaseViewModel.errorText(error);
      notify();
      return;
    }
    await refresh();
  }
}
