import 'package:flutter/widgets.dart';

import '../engine/engine.dart';
import '../services/file_picker.dart';
import '../ui/shell/app_dialogs.dart';
import 'account_selection.dart';
import 'base_view_model.dart';
import 'device_selection.dart';

/// The Account screen: what an Apple ID's developer account holds, and tidying it.
///
/// Screen-scoped, and deliberately read-then-act rather than cached: certificates and
/// identifiers are changed by other tools on the same account - Xcode on a Mac, SideStore
/// on the phone - so a stale list here would offer to revoke something that has already
/// gone, or hide something that appeared.
///
/// Which Apple ID it describes follows [AccountSelection], because iPASide can hold
/// several signed in and each has its own team.
///
/// It also holds the certificate imported from a seller, which needs no Apple ID at
/// all - so it is read on its own and shown even when the account cannot be.
class AccountViewModel extends BaseViewModel {
  AccountViewModel({
    required this._engine,
    required this._dialogs,
    required this._accounts,
    required this._picker,
    required this._devices,
  }) {
    _accounts.addListener(_onAccountChanged);
    _devices.addListener(_onDeviceChanged);
    load();
    loadCertificate();
  }

  final EngineApi _engine;
  final DialogService _dialogs;
  final AccountSelection _accounts;
  final FilePickerService _picker;
  final DeviceSelection _devices;

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
    _devices.removeListener(_onDeviceChanged);
    certificatePassword.dispose();
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
          ? 'Revoked. The apps EZSide installed here will stop opening until you '
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

  // ---- Imported certificate ---------------------------------------------- //

  ImportedCertificate? _certificate;

  /// Bumped when an import or removal writes [_certificate], so a status read that
  /// was already out cannot land afterwards with the older answer.
  int _certificateVersion = 0;
  bool _isCertificateLoading = false;
  bool _hasReadCertificate = false;
  String? _askedUdid;

  /// From an import, removal or re-sign: kept until the next action on the card.
  String? _certificateError;

  /// From a status read: the only error a later read may clear, so a phone plugged
  /// in or a Refresh cannot wipe what an action reported.
  String? _certificateReadError;
  String? _certificateNotice;
  bool _isImportOpen = false;
  String? _certificatePath;
  String? _profilePath;
  bool _isImporting = false;
  bool _isRemovingCertificate = false;
  bool _isResigning = false;
  String? _resignStep;
  List<CertificateResignResult>? _resignResults;
  Map<String, String> _resignNames = const <String, String>{};

  /// The `.p12` password while it is being typed. Read only at import time, and
  /// cleared straight after, so it never outlives the one call that needs it.
  final TextEditingController certificatePassword = TextEditingController();

  /// The imported certificate, or null when there is none (or before the first read).
  ImportedCertificate? get certificate => _certificate;

  /// Whether a certificate read is in flight.
  bool get isCertificateLoading => _isCertificateLoading;

  /// Whether the first certificate read has finished, either way.
  bool get hasReadCertificate => _hasReadCertificate;

  /// What went wrong reading, importing, removing or re-signing, cleaned for display.
  String? get certificateError => _certificateError ?? _certificateReadError;

  /// The outcome of the last certificate action, worth keeping on screen.
  String? get certificateNotice => _certificateNotice;

  /// Whether the import form is showing.
  bool get isImportOpen => _isImportOpen;

  /// The chosen `.p12`, if any.
  String? get certificatePath => _certificatePath;

  /// The chosen `.mobileprovision`, if any.
  String? get profilePath => _profilePath;

  bool get isImporting => _isImporting;
  bool get isRemovingCertificate => _isRemovingCertificate;
  bool get isResigning => _isResigning;

  /// What the re-sign is doing now, e.g. `My App: Installing`.
  String? get resignStep => _resignStep;

  /// One outcome per app from the last re-sign, or null when none ran. Read-only.
  List<CertificateResignResult>? get resignResults => _resignResults;

  bool get resignHasFailures =>
      _resignResults?.any((CertificateResignResult r) => !r.ok) ?? false;

  /// Whether a certificate action is in flight, so its buttons should be frozen.
  bool get isCertificateBusy =>
      _isImporting || _isRemovingCertificate || _isResigning;

  /// Re-reads both the account and the imported certificate.
  Future<void> refresh() => Future.wait<void>(<Future<void>>[load(), loadCertificate()]);

  void _onDeviceChanged() {
    // Whether the iPhone is in the profile is a question about the selected one.
    if (_devices.selectedUdid != _askedUdid) {
      loadCertificate();
    }
  }

  /// Reads the imported certificate, asking about the selected iPhone.
  Future<void> loadCertificate() async {
    if (_isCertificateLoading) return;
    _isCertificateLoading = true;
    final int version = _certificateVersion;
    _certificateReadError = null;
    notify();

    String? udid;
    try {
      udid = _askedUdid = await _devices.targetUdid();
      final ImportedCertificate? read = await _engine.certificateStatus(udid: udid);
      if (version == _certificateVersion) {
        _certificate = read;
        // The import answers without a phone, so its notice follows the read: an
        // iPhone outside the profile keeps signing with the Apple ID.
        if (_certificateNotice == _importedNotice ||
            _certificateNotice == _importedOutsideNotice) {
          _certificateNotice =
              read?.deviceOk == false ? _importedOutsideNotice : _importedNotice;
        }
      }
    } catch (error) {
      if (version == _certificateVersion && !BaseViewModel.isShutdown(error)) {
        _certificateReadError = BaseViewModel.errorText(error);
      }
    } finally {
      _isCertificateLoading = false;
      _hasReadCertificate = true;
      notify();
    }
    // The phone changed, or an import or removal landed, while that read was out:
    // answer for what is true now. The caller that asked meanwhile was turned away.
    if (!isDisposed &&
        (version != _certificateVersion || _devices.selectedUdid != udid)) {
      await loadCertificate();
    }
  }

  void openImport() {
    if (isCertificateBusy) return;
    _isImportOpen = true;
    _certificateError = _certificateReadError = null;
    _certificateNotice = null;
    notify();
  }

  void cancelImport() {
    if (_isImporting) return;
    _isImportOpen = false;
    _certificatePath = null;
    _profilePath = null;
    _certificateError = _certificateReadError = null;
    certificatePassword.clear();
    notify();
  }

  /// Asks for the `.p12`. A cancelled prompt keeps the earlier choice.
  Future<void> chooseCertificateFile() async {
    final String? path = await _picker.pickCertificate();
    if (path == null) return;
    _certificatePath = path;
    notify();
  }

  /// Asks for the `.mobileprovision`. A cancelled prompt keeps the earlier choice.
  Future<void> chooseProfileFile() async {
    final String? path = await _picker.pickProvisioningProfile();
    if (path == null) return;
    _profilePath = path;
    notify();
  }

  /// Imports the chosen pair, replacing any certificate imported before.
  ///
  /// The password is cleared whatever the outcome: a wrong one has to be typed
  /// again anyway, and a right one has no further use here. An empty one goes
  /// through as is: some `.p12` files have none, and the engine is what checks it.
  Future<void> importCertificate() async {
    if (isCertificateBusy) return;
    final String? p12 = _certificatePath;
    final String? profile = _profilePath;
    if (p12 == null || profile == null) {
      _certificateError = 'Choose the .p12 file and the .mobileprovision file.';
      notify();
      return;
    }

    _isImporting = true;
    _certificateError = _certificateReadError = null;
    _certificateNotice = null;
    _resignResults = null;
    notify();

    bool imported = false;
    try {
      _certificate =
          await _engine.importCertificate(p12, certificatePassword.text, profile);
      _certificateVersion++;
      imported = true;
      _isImportOpen = false;
      _certificatePath = null;
      _profilePath = null;
      _certificateNotice = _importedNotice;
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _certificateError = BaseViewModel.errorText(error);
      }
    } finally {
      // The page may have closed mid-import, taking the controller with it.
      if (!isDisposed) certificatePassword.clear();
      _isImporting = false;
      notify();
    }
    // The import answers without a phone; read it again to say whether this one fits.
    if (imported && !isDisposed) await loadCertificate();
  }

  /// Forgets the imported certificate, having said what that changes.
  Future<void> removeCertificate() async {
    if (_certificate == null || isCertificateBusy) return;

    final bool confirmed = await _dialogs.confirm(
      title: 'Remove this certificate?',
      message: 'New sideloads go back to signing with your Apple ID. Apps already '
          'installed with this certificate keep opening until it expires, but '
          'EZSide can no longer re-sign them.',
      confirmLabel: 'Remove',
      cancelLabel: 'Keep it',
      danger: true,
    );
    if (!confirmed) return;

    _isRemovingCertificate = true;
    _certificateError = _certificateReadError = null;
    _certificateNotice = null;
    _resignResults = null;
    notify();

    try {
      await _engine.removeCertificate();
      _certificate = null;
      _certificateVersion++;
      _certificateNotice = 'Removed. New sideloads use your Apple ID again.';
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _certificateError = BaseViewModel.errorText(error);
      }
    } finally {
      _isRemovingCertificate = false;
      notify();
    }
  }

  /// Re-signs every app installed with an imported certificate on the selected
  /// iPhone, with the one imported now - what a replacement certificate is for.
  Future<void> resignAll() async {
    if (_certificate == null || isCertificateBusy) return;

    _isResigning = true;
    _resignStep = null;
    _resignResults = null;
    _certificateError = _certificateReadError = null;
    _certificateNotice = null;
    notify();

    try {
      _resignNames = await _recordedNames();
      final List<CertificateResignResult> results =
          await _engine.resignWithCertificate(
        udid: await _devices.targetUdid(),
        onProgress: _onResignProgress,
      );
      _resignResults = results;
      _certificateNotice = resignSummary(results);
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _certificateError = BaseViewModel.errorText(error);
      }
    } finally {
      _isResigning = false;
      _resignStep = null;
      _resignNames = const <String, String>{};
      notify();
    }
  }

  /// Bundle id to recorded app name, for the progress line. The engine's progress
  /// names only the bundle id; without the records the id stands in for the name.
  Future<Map<String, String>> _recordedNames() async {
    try {
      return <String, String>{
        for (final InstallRecord record in await _engine.installs())
          if (record.bundleId != null && (record.name ?? '').isNotEmpty)
            record.bundleId!: record.name!,
      };
    } catch (_) {
      return const <String, String>{};
    }
  }

  void _onResignProgress(SideloadProgress progress) {
    final String? message = progress.step;
    final String? step = message != null && message.isNotEmpty
        ? message
        : _phaseWords[progress.phase];
    if (step == null) return;
    final String? id = progress.bundleId;
    final String? app = id == null ? null : _resignNames[id] ?? id;
    _resignStep = app == null ? step : '$app: $step';
    notify();
  }

  static const String _importedNotice =
      'Imported. New sideloads are signed with this certificate instead of your '
      'Apple ID.';
  static const String _importedOutsideNotice =
      'Imported. This iPhone is not in its profile, so its sideloads still use '
      'your Apple ID.';

  /// What a progress line says when the engine sends a phase but no message.
  static const Map<String, String> _phaseWords = <String, String>{
    'provision': 'Preparing',
    'sign': 'Signing',
    'install': 'Installing',
    'finalize': 'Finishing',
  };

  void dismissCertificateNotice() {
    if (_certificateNotice == null && _resignResults == null) return;
    _certificateNotice = null;
    _resignResults = null;
    notify();
  }

  /// One line for a re-sign: how many of how many, so a partial failure reads as one.
  static String resignSummary(List<CertificateResignResult> results) {
    if (results.isEmpty) {
      return 'Nothing to re-sign: no app on this iPhone was installed with an '
          'imported certificate.';
    }
    final int done = results.where((CertificateResignResult r) => r.ok).length;
    if (done == results.length) {
      return 'Re-signed $done app${done == 1 ? '' : 's'} with this certificate.';
    }
    return 'Re-signed $done of ${results.length} apps. The ones that failed are '
        'listed below.';
  }

  static String _revokeWarning(AccountCertificate certificate) {
    if (certificate.inUseHere) {
      return 'This is the certificate EZSide signs with on this PC. Revoking it stops '
          'every app it installed from opening, including LiveContainer, until you '
          'sideload or refresh something. Do it if Apple says you have too many '
          'certificates and you want to start fresh.';
    }
    if (certificate.ours) {
      return 'EZSide registered this on another machine. Revoking it stops apps that '
          'machine installed from opening, but nothing installed from this one.';
    }
    return 'This belongs to ${certificate.machine ?? 'another tool'} \u2014 not to '
        'EZSide. Revoking it stops the apps that tool installed from opening until it '
        'issues itself a new one.';
  }
}
