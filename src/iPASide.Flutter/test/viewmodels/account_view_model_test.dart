import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine.dart';
import 'package:ipaside/ui/shell/app_dialogs.dart';
import 'package:ipaside/viewmodels/account_selection.dart';
import 'package:ipaside/viewmodels/account_view_model.dart';

/// A transport stand-in scripted per engine command, recording every argv.
class _FakeRunner with EngineCommandRunner {
  final Map<String, Queue<Object>> _scripted = <String, Queue<Object>>{};
  final Map<String, Object> _defaults = <String, Object>{};

  final List<List<String>> calls = <List<String>>[];

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
    final String command = args.first;
    final Queue<Object>? queued = _scripted[command];
    final Object outcome = queued != null && queued.isNotEmpty
        ? queued.removeFirst()
        : _defaults[command] ??
            const EngineResult(ok: true, data: <String, dynamic>{});
    if (outcome is EngineResult) {
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
          'machine': 'iPASide',
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

Future<AccountViewModel> _loaded(
  _FakeRunner runner, {
  _FakeDialogs? dialogs,
  AccountSelection? accounts,
}) async {
  final AccountViewModel vm = AccountViewModel(
    engine: EngineApi(runner),
    dialogs: dialogs ?? _FakeDialogs(),
    accounts: accounts ?? await _selection(),
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
      expect(mine.owner, contains('iPASide'));
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
        'machine': 'iPASide',
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
            'machine': 'iPASide',
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
}
