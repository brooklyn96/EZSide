import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine.dart';
import 'package:ipaside/services/file_picker.dart';
import 'package:ipaside/services/settings_store.dart';
import 'package:ipaside/ui/shell/app_dialogs.dart';
import 'package:ipaside/viewmodels/account_selection.dart';
import 'package:ipaside/viewmodels/account_view_model.dart';
import 'package:ipaside/viewmodels/device_selection.dart';

/// A transport stand-in scripted per engine command, recording every argv. An
/// outcome may be a pending `Future<EngineResult>`, to hold one call mid-flight.
class _FakeRunner with EngineCommandRunner {
  final Map<String, Queue<Object>> _scripted = <String, Queue<Object>>{};
  final Map<String, Object> _defaults = <String, Object>{};

  final List<List<String>> calls = <List<String>>[];
  final List<Map<String, String>?> envs = <Map<String, String>?>[];

  /// Progress lines replayed to a command before it answers.
  final Map<String, List<String>> progress = <String, List<String>>{};

  List<String> callTo(String command) =>
      calls.lastWhere((List<String> c) => c.first == command);

  int countOf(String command) =>
      calls.where((List<String> c) => c.first == command).length;

  void always(String command, Object outcome) => _defaults[command] = outcome;

  void next(String command, Object outcome) =>
      (_scripted[command] ??= Queue<Object>()).add(outcome);

  @override
  Future<EngineResult> run(
    List<String> args, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  }) async {
    calls.add(args);
    envs.add(env);
    final String command = args.first;
    for (final String line in progress[command] ?? const <String>[]) {
      onProgress?.call(line);
    }
    final Queue<Object>? queued = _scripted[command];
    final Object outcome = queued != null && queued.isNotEmpty
        ? queued.removeFirst()
        : _defaults[command] ??
            const EngineResult(ok: true, data: <String, dynamic>{});
    if (outcome is EngineResult) {
      return outcome;
    }
    if (outcome is Future<EngineResult>) {
      return outcome;
    }
    throw outcome;
  }
}

/// Records what was asked of the user, and answers without a navigator.
class _FakeDialogs extends DialogService {
  _FakeDialogs() : super(GlobalKey<NavigatorState>());

  bool answer = true;
  final List<({String title, String message, bool danger})> confirms =
      <({String title, String message, bool danger})>[];

  @override
  Future<bool> confirm({
    required String title,
    required String message,
    String confirmLabel = 'OK',
    String cancelLabel = 'Cancel',
    bool danger = false,
  }) async {
    confirms.add((title: title, message: message, danger: danger));
    return answer;
  }
}

/// Answers the certificate prompts with whatever a test scripted; null is a cancel.
class _FakePicker implements FilePickerService {
  String? certificate;
  String? profile;

  @override
  Future<String?> pickCertificate() async => certificate;

  @override
  Future<String?> pickProvisioningProfile() async => profile;

  @override
  Future<String?> pickIpa() async => null;

  @override
  Future<List<String>> pickTweaks() async => const <String>[];

  @override
  Future<String?> pickSignedFolder() async => null;

  @override
  Future<String?> pickPairingFile() async => null;

  @override
  Future<String?> savePairingFile({required String suggestedName}) async =>
      null;
}

/// Settings held in memory, so nothing here touches the real settings file.
class _FakeSettings extends SettingsStore {
  String? deviceUdid;
  String connection = 'auto';

  @override
  String? loadDeviceUdid() => deviceUdid;

  @override
  void saveDeviceUdid(String? udid) => deviceUdid = udid;

  @override
  String loadConnection() => connection;

  @override
  void saveConnection(String value) => connection = value;
}

EngineResult _ok(Object data) => EngineResult(ok: true, data: data);

EngineResult _failed(String error) => EngineResult(ok: false, error: error);

const String ourSerial = '29C8EC73C890EBCA0EE74E017975D97B';
const String sideStoreSerial = '6739B3069372332966091DE3341C96BE';
const String xcodeSerial = '63EDA768F91B8C905FC6877994086D66';

/// The real shape observed on hardware: three certificates on one free team.
Map<String, dynamic> _overview() => <String, dynamic>{
      'account': 'someone@example.com',
      'team': <String, dynamic>{
        'id': 'ASK9QR9SBC',
        'name': 'Someone',
        'type': 'Individual',
      },
      'certificates': <dynamic>[
        <String, dynamic>{
          'serial': ourSerial,
          'machine': 'EZSide',
          'type': 'iOS Development',
          'expires': '2027-07-26T11:13:24',
          'ours': true,
          'in_use_here': true,
        },
        <String, dynamic>{
          'serial': sideStoreSerial,
          'machine': "SideStore - Someone's iPhone",
          'type': 'iOS Development',
          'ours': false,
          'in_use_here': false,
        },
        <String, dynamic>{
          'serial': xcodeSerial,
          'machine': "Someone's MacBook Pro",
          'type': 'Development',
          'ours': false,
          'in_use_here': false,
        },
      ],
      'app_ids': <dynamic>[
        <String, dynamic>{
          'id': 'AAA1',
          'identifier': 'com.kdt.livecontainer.ASK9QR9SBC',
          'name': 'LiveContainer',
        },
      ],
      'devices': <dynamic>[
        <String, dynamic>{'id': 'D1', 'name': 'A phone', 'udid': '935cbbb9'},
      ],
      'registered_app_ids': 1,
      'weekly_app_id_limit': 10,
    };

/// A selection holding one signed-in Apple ID, over its own transport so its lookups
/// never land in the call list a test is asserting on.
Future<AccountSelection> _selection({String email = 'someone@example.com'}) async {
  final _FakeRunner runner = _FakeRunner()
    ..always(
      'login',
      _ok(<String, dynamic>{
        'accounts': <dynamic>[
          <String, dynamic>{'email': email, 'active': true},
        ],
      }),
    );
  final AccountSelection selection = AccountSelection(engine: EngineApi(runner));
  addTearDown(selection.dispose);
  await selection.refresh();
  return selection;
}

/// A device selection resolved to [udid] (or to nothing), over its own transport.
/// [settled] false leaves it unenumerated, as on a cold start.
Future<DeviceSelection> _devices({String? udid, bool settled = true}) async {
  final _FakeRunner runner = _FakeRunner()
    ..always(
      'devices',
      _ok(<dynamic>[
        if (udid != null)
          <String, dynamic>{'serial': udid, 'connection_type': 'USB'},
      ]),
    )
    ..always('device-info', _ok(<String, dynamic>{'DeviceName': 'Test iPhone'}));
  final DeviceSelection selection = DeviceSelection(
    engine: EngineApi(runner),
    settings: _FakeSettings(),
  );
  addTearDown(selection.dispose);
  if (settled) await selection.refresh();
  return selection;
}

const String phoneUdid = '00008020-0012345678901234';

/// `info` as the engine reports an imported certificate.
Map<String, dynamic> _certificate({bool? deviceOk = true}) => <String, dynamic>{
      'name': 'iPhone Distribution: Seller Ltd',
      'team_id': 'SELLER1234',
      'team_name': 'Seller Ltd',
      'serial': '0A1B2C',
      'fingerprint': 'ab12',
      'certificate_expires': '2027-11-01T00:00:00Z',
      'profile_name': 'Seller Ad Hoc',
      'profile_expires': '2027-10-01T00:00:00Z',
      'expires': '2027-10-01T00:00:00Z',
      'app_id': 'SELLER1234.*',
      'wildcard': true,
      'all_devices': false,
      'device_count': 12,
      'imported_at': '2026-11-11T10:00:00Z',
      'device_ok': deviceOk,
    };

EngineResult _status(Map<String, dynamic>? certificate) =>
    _ok(<String, dynamic>{'status': 'ok', 'certificate': certificate});

Future<AccountViewModel> _loaded(
  _FakeRunner runner, {
  _FakeDialogs? dialogs,
  AccountSelection? accounts,
  _FakePicker? picker,
  DeviceSelection? devices,
}) async {
  final AccountViewModel vm = AccountViewModel(
    engine: EngineApi(runner),
    dialogs: dialogs ?? _FakeDialogs(),
    accounts: accounts ?? await _selection(),
    picker: picker ?? _FakePicker(),
    devices: devices ?? await _devices(),
  );
  addTearDown(vm.dispose);
  await pumpEventQueue();
  return vm;
}

void main() {
  group('AccountViewModel load', () {
    test('reads the account on creation', () async {
      final _FakeRunner runner = _FakeRunner()..always('slots', _ok(_overview()));

      final AccountViewModel vm = await _loaded(runner);

      expect(runner.calls.first.first, 'slots');
      expect(vm.overview?.teamId, 'ASK9QR9SBC');
      expect(vm.overview?.certificates, hasLength(3));
      expect(vm.isLoading, isFalse);
      expect(vm.error, isNull);
    });

    test('asks about the selected Apple ID', () async {
      // iPASide can hold several signed in, each with its own team, so which one is
      // being described has to travel with the request.
      final _FakeRunner runner = _FakeRunner()..always('slots', _ok(_overview()));

      await _loaded(runner, accounts: await _selection(email: 'second@example.com'));

      final List<String> argv = runner.calls.first;
      expect(argv[argv.indexOf('--email') + 1], 'second@example.com');
    });

    test('an engine failure is shown cleaned, not thrown', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _failed('Apple said no'));

      final AccountViewModel vm = await _loaded(runner);

      expect(vm.error, contains('Apple said no'));
      expect(vm.isLoading, isFalse);
    });

    test('a second load while one runs is ignored', () async {
      final _FakeRunner runner = _FakeRunner()..always('slots', _ok(_overview()));

      final AccountViewModel vm = await _loaded(runner);
      final int before = runner.calls.length;
      await Future.wait<void>(<Future<void>>[vm.load(), vm.load()]);

      expect(runner.calls.length, before + 1);
    });
  });

  group('AccountViewModel certificate ownership', () {
    test('ours is labelled as the one signing here', () async {
      final _FakeRunner runner = _FakeRunner()..always('slots', _ok(_overview()));

      final AccountViewModel vm = await _loaded(runner);
      final AccountCertificate mine = vm.overview!.certificates
          .firstWhere((AccountCertificate c) => c.serial == ourSerial);

      expect(mine.inUseHere, isTrue);
      expect(mine.owner, contains('EZSide'));
      expect(mine.owner, contains('signing with it now'));
    });

    test("another tool's is labelled with its machine", () async {
      final _FakeRunner runner = _FakeRunner()..always('slots', _ok(_overview()));

      final AccountViewModel vm = await _loaded(runner);
      final AccountCertificate theirs = vm.overview!.certificates
          .firstWhere((AccountCertificate c) => c.serial == xcodeSerial);

      expect(theirs.ours, isFalse);
      expect(theirs.owner, "Someone's MacBook Pro");
    });

    test('one iPASide issued elsewhere is ours but not in use here', () async {
      final Map<String, dynamic> payload = _overview();
      (payload['certificates'] as List<dynamic>).add(<String, dynamic>{
        'serial': 'OTHERMACHINE01',
        'machine': 'EZSide',
        'ours': true,
        'in_use_here': false,
      });
      final _FakeRunner runner = _FakeRunner()..always('slots', _ok(payload));

      final AccountViewModel vm = await _loaded(runner);
      final AccountCertificate elsewhere = vm.overview!.certificates
          .firstWhere((AccountCertificate c) => c.serial == 'OTHERMACHINE01');

      expect(elsewhere.owner, contains('another machine'));
    });
  });

  group('AccountViewModel revoking', () {
    test('asks first, and revokes when confirmed', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always(
          'revoke-cert',
          _ok(<String, dynamic>{
            'revoked': sideStoreSerial,
            'machine': "SideStore - Someone's iPhone",
            'was_ours': false,
            'invalidates_local_apps': false,
          }),
        );
      final _FakeDialogs dialogs = _FakeDialogs();

      final AccountViewModel vm = await _loaded(runner, dialogs: dialogs);
      await vm.revoke(
        vm.overview!.certificates
            .firstWhere((AccountCertificate c) => c.serial == sideStoreSerial),
      );

      expect(dialogs.confirms.single.danger, isTrue);
      final List<String> argv =
          runner.calls.firstWhere((List<String> c) => c.first == 'revoke-cert');
      expect(argv[1], sideStoreSerial);
    });

    test('declining leaves the certificate alone', () async {
      final _FakeRunner runner = _FakeRunner()..always('slots', _ok(_overview()));
      final _FakeDialogs dialogs = _FakeDialogs()..answer = false;

      final AccountViewModel vm = await _loaded(runner, dialogs: dialogs);
      await vm.revoke(vm.overview!.certificates.first);

      expect(
        runner.calls.any((List<String> c) => c.first == 'revoke-cert'),
        isFalse,
      );
    });

    test('the warning is worded from who owns it', () async {
      // Three cases with very different consequences; only one is housekeeping.
      final _FakeRunner runner = _FakeRunner()..always('slots', _ok(_overview()));
      final _FakeDialogs dialogs = _FakeDialogs()..answer = false;

      final AccountViewModel vm = await _loaded(runner, dialogs: dialogs);
      final List<AccountCertificate> certificates = vm.overview!.certificates;

      await vm.revoke(
        certificates.firstWhere((AccountCertificate c) => c.serial == ourSerial),
      );
      expect(dialogs.confirms.last.message, contains('signs with on this PC'));

      await vm.revoke(
        certificates.firstWhere((AccountCertificate c) => c.serial == xcodeSerial),
      );
      expect(dialogs.confirms.last.message, contains("Someone's MacBook Pro"));
      expect(dialogs.confirms.last.message, contains('not to'));
    });

    test('revoking ours says the local apps have stopped working', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always(
          'revoke-cert',
          _ok(<String, dynamic>{
            'revoked': ourSerial,
            'machine': 'EZSide',
            'was_ours': true,
            'invalidates_local_apps': true,
          }),
        );

      final AccountViewModel vm = await _loaded(runner);
      await vm.revoke(
        vm.overview!.certificates
            .firstWhere((AccountCertificate c) => c.serial == ourSerial),
      );

      expect(vm.notice, contains('stop opening'));
    });

    test('a revocation failure is reported, not thrown', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always('revoke-cert', _failed('Apple refused'));

      final AccountViewModel vm = await _loaded(runner);
      await vm.revoke(vm.overview!.certificates.first);

      expect(vm.notice, contains('Apple refused'));
    });

    test('a certificate with no serial cannot be revoked', () async {
      final _FakeRunner runner = _FakeRunner()..always('slots', _ok(_overview()));
      final _FakeDialogs dialogs = _FakeDialogs();

      final AccountViewModel vm = await _loaded(runner, dialogs: dialogs);
      await vm.revoke(const AccountCertificate());

      expect(dialogs.confirms, isEmpty);
    });

    test('the list is re-read afterwards', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always(
          'revoke-cert',
          _ok(<String, dynamic>{'revoked': sideStoreSerial}),
        );

      final AccountViewModel vm = await _loaded(runner);
      final int before =
          runner.calls.where((List<String> c) => c.first == 'slots').length;
      await vm.revoke(vm.overview!.certificates.first);

      expect(
        runner.calls.where((List<String> c) => c.first == 'slots').length,
        greaterThan(before),
      );
    });
  });

  group('AccountViewModel App IDs', () {
    test('deleting asks first and says the quota is unaffected', () async {
      final _FakeRunner runner = _FakeRunner()..always('slots', _ok(_overview()));
      final _FakeDialogs dialogs = _FakeDialogs();

      final AccountViewModel vm = await _loaded(runner, dialogs: dialogs);
      await vm.deleteAppId(vm.overview!.appIds.single);

      // The obvious reading - that deleting frees a slot for this week - is the wrong
      // one, and is how somebody gets refused mid-install.
      expect(dialogs.confirms.single.message, contains('rolling seven days'));
      final List<String> argv =
          runner.calls.firstWhere((List<String> c) => c.first == 'delete-app-id');
      expect(argv[1], 'AAA1');
    });

    test('declining leaves it registered', () async {
      final _FakeRunner runner = _FakeRunner()..always('slots', _ok(_overview()));
      final _FakeDialogs dialogs = _FakeDialogs()..answer = false;

      final AccountViewModel vm = await _loaded(runner, dialogs: dialogs);
      await vm.deleteAppId(vm.overview!.appIds.single);

      expect(
        runner.calls.any((List<String> c) => c.first == 'delete-app-id'),
        isFalse,
      );
    });

    test('registered count and weekly ceiling are separate numbers', () async {
      final _FakeRunner runner = _FakeRunner()..always('slots', _ok(_overview()));

      final AccountViewModel vm = await _loaded(runner);

      expect(vm.overview!.registeredAppIds, 1);
      expect(vm.overview!.weeklyAppIdLimit, 10);
    });
  });

  group('AccountViewModel notices', () {
    test('a notice can be dismissed', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always('revoke-cert', _ok(<String, dynamic>{'revoked': ourSerial}));

      final AccountViewModel vm = await _loaded(runner);
      await vm.revoke(vm.overview!.certificates.first);
      expect(vm.notice, isNotNull);

      vm.dismissNotice();

      expect(vm.notice, isNull);
    });
  });

  group('AccountViewModel imported certificate', () {
    test('reads it on creation, asking about the selected iPhone', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always('cert-status', _status(_certificate()));

      final AccountViewModel vm =
          await _loaded(runner, devices: await _devices(udid: phoneUdid));

      expect(
        runner.callTo('cert-status'),
        <String>['cert-status', '--udid', phoneUdid],
      );
      expect(vm.certificate?.teamId, 'SELLER1234');
      expect(vm.certificate?.deviceOk, isTrue);
      expect(vm.isCertificateLoading, isFalse);
    });

    test('a cold start waits for the iPhone list, so the udid still goes', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always('cert-status', _status(_certificate()));

      await _loaded(
        runner,
        devices: await _devices(udid: phoneUdid, settled: false),
      );

      expect(
        runner.callTo('cert-status'),
        <String>['cert-status', '--udid', phoneUdid],
      );
    });

    test('nothing imported reads as none, not as an error', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always('cert-status', _status(null));

      final AccountViewModel vm = await _loaded(runner);

      expect(vm.certificate, isNull);
      expect(vm.certificateError, isNull);
    });

    test('it is read even when the Apple ID cannot be', () async {
      // An imported certificate needs no Apple ID, so a failed `slots` must not hide it.
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _failed('not signed in'))
        ..always('cert-status', _status(_certificate()));

      final AccountViewModel vm = await _loaded(runner);

      expect(vm.error, contains('not signed in'));
      expect(vm.certificate, isNotNull);
    });

    test('import sends the paths in argv and the password only in env', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..next('cert-status', _status(null))
        ..always(
          'cert-import',
          _ok(<String, dynamic>{
            'status': 'ok',
            'certificate': _certificate(deviceOk: null),
          }),
        )
        ..always('cert-status', _status(_certificate()));
      final _FakePicker picker = _FakePicker()
        ..certificate = r'C:\Downloads\seller.p12'
        ..profile = r'C:\Downloads\seller.mobileprovision';

      final AccountViewModel vm = await _loaded(runner, picker: picker);
      vm.openImport();
      await vm.chooseCertificateFile();
      await vm.chooseProfileFile();
      vm.certificatePassword.text = 'p12-s3cret';
      await vm.importCertificate();

      final int at = runner.calls.indexOf(runner.callTo('cert-import'));
      expect(runner.calls[at], <String>[
        'cert-import',
        '--p12',
        r'C:\Downloads\seller.p12',
        '--profile',
        r'C:\Downloads\seller.mobileprovision',
      ]);
      expect(runner.calls[at], isNot(contains('p12-s3cret')));
      expect(
        runner.envs[at],
        <String, String>{'IPASIDE_CERT_PASSWORD': 'p12-s3cret'},
      );
      expect(vm.certificatePassword.text, isEmpty, reason: 'the password is not kept');
      expect(vm.isImportOpen, isFalse);
      expect(vm.isImporting, isFalse);
      expect(vm.certificate?.deviceOk, isTrue, reason: 're-read for the selected iPhone');
      expect(vm.certificateNotice, contains('New sideloads'));
    });

    test('an empty password goes to the engine, which is what checks it', () async {
      // Some .p12 files have no password; only the two files are required here.
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..next('cert-status', _status(null))
        ..always(
          'cert-import',
          _ok(<String, dynamic>{
            'status': 'ok',
            'certificate': _certificate(deviceOk: null),
          }),
        )
        ..always('cert-status', _status(_certificate()));
      final _FakePicker picker = _FakePicker()
        ..certificate = r'C:\c.p12'
        ..profile = r'C:\p.mobileprovision';

      final AccountViewModel vm = await _loaded(runner, picker: picker);
      vm.openImport();
      await vm.chooseCertificateFile();
      await vm.chooseProfileFile();
      await vm.importCertificate();

      expect(runner.countOf('cert-import'), 1);
      final int at = runner.calls.indexOf(runner.callTo('cert-import'));
      expect(runner.envs[at], <String, String>{'IPASIDE_CERT_PASSWORD': ''});
      expect(vm.certificateError, isNull);
      expect(vm.certificate, isNotNull);
    });

    test('a failed import shows the reason and still forgets the password', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always('cert-status', _status(null))
        ..always(
          'cert-import',
          const EngineResult(
            ok: false,
            data: <String, dynamic>{
              'status': 'error',
              'error': 'The password is wrong or the .p12 file cannot be read.',
            },
          ),
        );
      final _FakePicker picker = _FakePicker()
        ..certificate = r'C:\c.p12'
        ..profile = r'C:\p.mobileprovision';

      final AccountViewModel vm = await _loaded(runner, picker: picker);
      vm.openImport();
      await vm.chooseCertificateFile();
      await vm.chooseProfileFile();
      vm.certificatePassword.text = 'wrong';
      await vm.importCertificate();

      expect(vm.certificateError, contains('password is wrong'));
      expect(vm.certificatePassword.text, isEmpty);
      expect(vm.isImportOpen, isTrue, reason: 'the chosen files stay for a retry');
      expect(vm.certificatePath, r'C:\c.p12');
      expect(vm.certificate, isNull);
    });

    test('an iPhone outside the new profile is named in the import notice', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..next('cert-status', _status(null))
        ..always(
          'cert-import',
          _ok(<String, dynamic>{
            'status': 'ok',
            'certificate': _certificate(deviceOk: null),
          }),
        )
        ..always('cert-status', _status(_certificate(deviceOk: false)));
      final _FakePicker picker = _FakePicker()
        ..certificate = r'C:\c.p12'
        ..profile = r'C:\p.mobileprovision';

      final AccountViewModel vm = await _loaded(
        runner,
        picker: picker,
        devices: await _devices(udid: phoneUdid),
      );
      vm.openImport();
      await vm.chooseCertificateFile();
      await vm.chooseProfileFile();
      await vm.importCertificate();

      expect(vm.certificate?.deviceOk, isFalse, reason: 're-read for the selected iPhone');
      expect(
        vm.certificateNotice,
        'Imported. This iPhone is not in its profile, so its sideloads still use '
        'your Apple ID.',
      );
    });

    test("a status read clears only its own error, not an import's", () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..next('cert-status', _failed('certificate.json is unreadable'))
        ..always('cert-status', _status(null))
        ..always(
          'cert-import',
          const EngineResult(
            ok: false,
            data: <String, dynamic>{
              'status': 'error',
              'error': 'The password is wrong or the .p12 file cannot be read.',
            },
          ),
        );
      final _FakePicker picker = _FakePicker()
        ..certificate = r'C:\c.p12'
        ..profile = r'C:\p.mobileprovision';

      final AccountViewModel vm = await _loaded(runner, picker: picker);
      expect(vm.certificateError, contains('unreadable'));
      await vm.loadCertificate();
      expect(vm.certificateError, isNull, reason: 'a read clears what a read said');

      vm.openImport();
      await vm.chooseCertificateFile();
      await vm.chooseProfileFile();
      vm.certificatePassword.text = 'wrong';
      await vm.importCertificate();
      // e.g. an iPhone plugged in, or Refresh pressed, while the form is still open.
      await vm.loadCertificate();

      expect(vm.certificateError, contains('password is wrong'));
      expect(vm.isImportOpen, isTrue);
    });

    test('a status read still out when an import lands cannot undo it', () async {
      // e.g. the iPhone was switched just before Import: that read began before the
      // import, so its "nothing imported" is older than the import's answer.
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..next('cert-status', _status(null));
      final _FakePicker picker = _FakePicker()
        ..certificate = r'C:\c.p12'
        ..profile = r'C:\p.mobileprovision';

      final AccountViewModel vm = await _loaded(runner, picker: picker);
      final Completer<EngineResult> older = Completer<EngineResult>();
      runner
        ..next('cert-status', older.future)
        ..always(
          'cert-import',
          _ok(<String, dynamic>{
            'status': 'ok',
            'certificate': _certificate(deviceOk: null),
          }),
        )
        ..always('cert-status', _status(_certificate()));

      final Future<void> inFlight = vm.loadCertificate();
      vm.openImport();
      await vm.chooseCertificateFile();
      await vm.chooseProfileFile();
      vm.certificatePassword.text = 'p12-s3cret';
      await vm.importCertificate();
      older.complete(_status(null));
      await inFlight;

      expect(vm.certificate, isNotNull, reason: 'the older read is dropped');
      expect(vm.certificate?.deviceOk, isTrue, reason: 'and read again after it');
      expect(vm.certificateNotice, contains('Imported'));
      expect(runner.countOf('cert-status'), 3);
    });

    test('a status read still out when a removal lands cannot bring it back', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..next('cert-status', _status(_certificate()));

      final AccountViewModel vm = await _loaded(runner);
      final Completer<EngineResult> older = Completer<EngineResult>();
      runner
        ..next('cert-status', older.future)
        ..always(
          'cert-remove',
          _ok(<String, dynamic>{'status': 'ok', 'removed': true}),
        )
        ..always('cert-status', _status(null));

      final Future<void> inFlight = vm.loadCertificate();
      await vm.removeCertificate();
      older.complete(_status(_certificate()));
      await inFlight;

      expect(vm.certificate, isNull);
      expect(vm.certificateNotice, contains('Removed'));
    });

    test('import asks for the missing piece instead of calling the engine', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always('cert-status', _status(null));
      final _FakePicker picker = _FakePicker()..certificate = r'C:\c.p12';

      final AccountViewModel vm = await _loaded(runner, picker: picker);
      vm.openImport();
      await vm.chooseCertificateFile();
      await vm.importCertificate();

      expect(runner.countOf('cert-import'), 0);
      expect(vm.certificateError, isNotNull);
    });

    test('a cancelled file prompt keeps the earlier choice', () async {
      final _FakeRunner runner = _FakeRunner()..always('slots', _ok(_overview()));
      final _FakePicker picker = _FakePicker()..certificate = r'C:\c.p12';

      final AccountViewModel vm = await _loaded(runner, picker: picker);
      await vm.chooseCertificateFile();
      picker.certificate = null;
      await vm.chooseCertificateFile();

      expect(vm.certificatePath, r'C:\c.p12');
    });

    test('remove asks first, as a danger, and clears it when confirmed', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always('cert-status', _status(_certificate()))
        ..always(
          'cert-remove',
          _ok(<String, dynamic>{'status': 'ok', 'removed': true}),
        );
      final _FakeDialogs dialogs = _FakeDialogs();

      final AccountViewModel vm = await _loaded(runner, dialogs: dialogs);
      await vm.removeCertificate();

      expect(dialogs.confirms.single.danger, isTrue);
      expect(dialogs.confirms.single.message, contains('Apple ID'));
      expect(runner.callTo('cert-remove'), <String>['cert-remove']);
      expect(vm.certificate, isNull);
      expect(vm.certificateNotice, isNotNull);
    });

    test('declining the removal keeps the certificate', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always('cert-status', _status(_certificate()));
      final _FakeDialogs dialogs = _FakeDialogs()..answer = false;

      final AccountViewModel vm = await _loaded(runner, dialogs: dialogs);
      await vm.removeCertificate();

      expect(runner.countOf('cert-remove'), 0);
      expect(vm.certificate, isNotNull);
    });

    test('re-signing reports every app, failures included', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always('cert-status', _status(_certificate()))
        ..always(
          'cert-resign',
          const EngineResult(
            ok: false,
            data: <String, dynamic>{
              'status': 'ok',
              'results': <dynamic>[
                <String, dynamic>{'bundle_id': 'com.a', 'name': 'App A', 'ok': true},
                <String, dynamic>{'bundle_id': 'com.b', 'name': 'App B', 'ok': true},
                <String, dynamic>{
                  'bundle_id': 'com.c',
                  'name': 'App C',
                  'ok': false,
                  'error': 'The iPhone is locked.',
                },
              ],
            },
          ),
        );
      runner.progress['cert-resign'] = <String>[
        '{"event":"progress","phase":"sign","step":"Signing the app","bundle_id":"com.a"}',
        '{"event":"progress","phase":"install","percent":40,"step":null,"bundle_id":"com.b"}',
        '{"event":"progress","phase":"finalize","step":"","bundle_id":"com.c"}',
        '{"event":"progress","phase":"sign","bundle_id":"com.unknown"}',
      ];
      final List<String?> steps = <String?>[];

      final AccountViewModel vm =
          await _loaded(runner, devices: await _devices(udid: phoneUdid));
      // The progress lines carry only the bundle id; the names come from the records.
      runner.always(
        'installs',
        _ok(<dynamic>[
          <String, dynamic>{'bundle_id': 'com.a', 'name': 'App A'},
          <String, dynamic>{'bundle_id': 'com.b', 'name': 'App B'},
          <String, dynamic>{'bundle_id': 'com.c', 'name': 'App C'},
        ]),
      );
      vm.addListener(() => steps.add(vm.resignStep));
      await vm.resignAll();

      expect(
        runner.callTo('cert-resign'),
        <String>['cert-resign', '--udid', phoneUdid],
      );
      expect(steps, contains('App A: Signing the app'));
      expect(steps, contains('App B: Installing'));
      expect(steps, contains('App C: Finishing'));
      // No record for it: the bundle id stands in for the name.
      expect(steps, contains('com.unknown: Signing'));
      expect(vm.isResigning, isFalse);
      expect(vm.resignResults, hasLength(3));
      expect(
        vm.certificateNotice,
        'Re-signed 2 of 3 apps. The ones that failed are listed below.',
      );
      expect(vm.resignHasFailures, isTrue);
    });

    test('the summary covers all done and nothing to do', () {
      expect(
        AccountViewModel.resignSummary(const <CertificateResignResult>[
          CertificateResignResult(bundleId: 'com.a', ok: true),
        ]),
        'Re-signed 1 app with this certificate.',
      );
      expect(
        AccountViewModel.resignSummary(const <CertificateResignResult>[]),
        contains('Nothing to re-sign'),
      );
    });

    test('a re-sign that fails outright is shown, not thrown', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always('cert-status', _status(_certificate()))
        ..always('cert-resign', _failed('No iPhone is connected.'));

      final AccountViewModel vm = await _loaded(runner);
      runner.always('installs', _failed('sideloads.json is unreadable'));
      await vm.resignAll();

      // The name lookup failing does not stop the re-sign; the engine's answer is shown.
      expect(runner.countOf('cert-resign'), 1);
      expect(vm.certificateError, contains('No iPhone is connected.'));
      expect(vm.resignResults, isNull);
      expect(vm.isResigning, isFalse);
    });

    test('a status failure is shown in the card, not as the account error', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('slots', _ok(_overview()))
        ..always('cert-status', _failed('certificate.json is unreadable'));

      final AccountViewModel vm = await _loaded(runner);

      expect(vm.certificateError, contains('unreadable'));
      expect(vm.error, isNull);
    });
  });
}
