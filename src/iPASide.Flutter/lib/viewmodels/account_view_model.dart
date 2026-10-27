import '../engine/engine.dart';
import '../ui/shell/app_dialogs.dart';
import 'account_selection.dart';
import 'base_view_model.dart';

/// The Account screen: what an Apple ID's developer account holds, and tidying it.
///
/// Screen-scoped, and deliberately read-then-act rather than cached: certificates and
/// identifiers are changed by other tools on the same account - Xcode on a Mac, SideStore
/// on the phone - so a stale list here would offer to revoke something that has already
/// gone, or hide something that appeared.
///
/// Which Apple ID it describes follows [AccountSelection], because iPASide can hold
/// several signed in and each has its own team.
class AccountViewModel extends BaseViewModel {
  AccountViewModel({
    required this._engine,
    required this._dialogs,
    required this._accounts,
  }) {
    _accounts.addListener(_onAccountChanged);
    load();
  }

  final EngineApi _engine;
  final DialogService _dialogs;
  final AccountSelection _accounts;

  AccountOverview? _overview;
  bool _isLoading = false;
  String? _error;
  String? _busySerial;
  String? _busyAppId;
  String? _notice;

  /// Which Apple ID is being described, once known.
  String? get email => _overview?.account ?? _accounts.activeEmail;

  /// What the account holds, or null before the first read.
  AccountOverview? get overview => _overview;

  /// Whether a read is in flight.
  bool get isLoading => _isLoading;

  /// A read failure, cleaned for display.
  String? get error => _error;

  /// True while that certificate is being revoked.
  bool isRevoking(String? serial) => serial != null && _busySerial == serial;

  /// True while that identifier is being deleted.
  bool isDeleting(String? appIdId) => appIdId != null && _busyAppId == appIdId;

  /// Whether anything is in flight, so the whole list should be frozen.
  bool get isBusy => _busySerial != null || _busyAppId != null;

  /// The consequence of the last action, worth keeping on screen.
  String? get notice => _notice;

  void dismissNotice() {
    if (_notice == null) return;
    _notice = null;
    notify();
  }

  @override
  void dispose() {
    _accounts.removeListener(_onAccountChanged);
    super.dispose();
  }

  void _onAccountChanged() {
    // Switching Apple ID changes the team, so everything on screen is about to be wrong.
    if (_accounts.activeEmail != _overview?.account) {
      load();
    }
  }

  /// Reads the account, for whichever Apple ID is active.
  Future<void> load() async {
    if (_isLoading) return;
    _isLoading = true;
    _error = null;
    notify();

    try {
      _overview = await _engine.accountOverview(email: _accounts.activeEmail);
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _error = BaseViewModel.errorText(error);
      }
    } finally {
      _isLoading = false;
      notify();
    }
  }

  /// Revokes a certificate, having said plainly what it will break.
  ///
  /// The warning is worded from who owns the certificate, because the three cases have
  /// very different consequences and only one of them is routine housekeeping.
  Future<void> revoke(AccountCertificate certificate) async {
    final String? serial = certificate.serial;
    if (serial == null || isBusy) return;

    final bool confirmed = await _dialogs.confirm(
      title: 'Revoke this certificate?',
      message: _revokeWarning(certificate),
      confirmLabel: 'Revoke',
      cancelLabel: 'Keep it',
      danger: true,
    );
    if (!confirmed) return;

    _busySerial = serial;
    _notice = null;
    notify();

    try {
      final RevokedCertificate result = await _engine.revokeCertificate(
        serial,
        email: _accounts.activeEmail,
      );
      _notice = result.invalidatesLocalApps
          ? 'Revoked. The apps iPASide installed here will stop opening until you '
              'sideload or refresh one, which provisions a new certificate.'
          : 'Revoked ${result.machine ?? serial}.';
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _notice = BaseViewModel.errorText(error);
      }
    } finally {
      _busySerial = null;
      notify();
    }
    await load();
  }

  /// Deletes a registered app identifier.
  Future<void> deleteAppId(AccountAppId appId) async {
    final String? id = appId.id;
    if (id == null || isBusy) return;

    final bool confirmed = await _dialogs.confirm(
      title: 'Delete this App ID?',
      message:
          '${appId.identifier ?? id} will be unregistered. That frees the identifier, '
          'but not one of this week\u2019s registrations \u2014 Apple counts those over a '
          'rolling seven days.',
      confirmLabel: 'Delete',
      cancelLabel: 'Cancel',
      danger: true,
    );
    if (!confirmed) return;

    _busyAppId = id;
    _notice = null;
    notify();

    try {
      await _engine.deleteAppId(id, email: _accounts.activeEmail);
      _notice = 'Deleted ${appId.identifier ?? id}.';
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _notice = BaseViewModel.errorText(error);
      }
    } finally {
      _busyAppId = null;
      notify();
    }
    await load();
  }

  static String _revokeWarning(AccountCertificate certificate) {
    if (certificate.inUseHere) {
      return 'This is the certificate iPASide signs with on this PC. Revoking it stops '
          'every app it installed from opening, including LiveContainer, until you '
          'sideload or refresh something. Do it if Apple says you have too many '
          'certificates and you want to start fresh.';
    }
    if (certificate.ours) {
      return 'iPASide registered this on another machine. Revoking it stops apps that '
          'machine installed from opening, but nothing installed from this one.';
    }
    return 'This belongs to ${certificate.machine ?? 'another tool'} \u2014 not to '
        'iPASide. Revoking it stops the apps that tool installed from opening until it '
        'issues itself a new one.';
  }
}
