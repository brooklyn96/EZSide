import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine.dart';
import 'package:ipaside/viewmodels/account_selection.dart';

/// A transport stand-in scripted per engine command: it records every argv and
/// replays canned result frames (or throws a canned error).
class _FakeRunner with EngineCommandRunner {
  final Map<String, Queue<Object>> _scripted = <String, Queue<Object>>{};
  final Map<String, Object> _defaults = <String, Object>{};

  /// Every argv the facade issued, in order.
  final List<List<String>> calls = <List<String>>[];

  /// Parks each answer until completed, so a mid-flight state can be asserted.
  Completer<void>? hold;

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
    await hold?.future;

    final String command = args.first;
    final Queue<Object>? queued = _scripted[command];
    final Object outcome = queued != null && queued.isNotEmpty
        ? queued.removeFirst()
        : _defaults[command] ??
            const EngineResult(ok: true, data: <String, dynamic>{});
    if (outcome is EngineResult) return outcome;
    throw outcome;
  }
}

EngineResult _accounts(List<Map<String, dynamic>> entries) => EngineResult(
      ok: true,
      data: <String, dynamic>{'accounts': entries},
    );

Map<String, dynamic> _account(
  String email, {
  bool active = false,
  String? team,
}) =>
    <String, dynamic>{
      'email': email,
      'active': active,
      'team_id': ?team,
    };

void main() {
  late _FakeRunner runner;
  late AccountSelection selection;

  setUp(() {
    runner = _FakeRunner();
    selection = AccountSelection(engine: EngineApi(runner));
  });

  tearDown(() => selection.dispose());

  group('AccountSelection reading', () {
    test('starts empty, without having asked anything', () {
      expect(selection.accounts, isEmpty);
      expect(selection.activeEmail, isNull);
      expect(selection.hasLoaded, isFalse);
      expect(runner.calls, isEmpty);
    });

    test('reads the signed-in accounts and finds the active one', () async {
      runner.always('login', _accounts(<Map<String, dynamic>>[
        _account('one@example.com', active: true, team: 'TEAMONE'),
        _account('two@example.com'),
      ]));

      await selection.refresh();

      expect(selection.accounts.length, 2);
      expect(selection.activeEmail, 'one@example.com');
      expect(selection.active?.teamId, 'TEAMONE');
      expect(selection.hasLoaded, isTrue);
      expect(selection.hasError, isFalse);
    });

    test('asks the engine for the account list, not the session status', () async {
      runner.always('login', _accounts(<Map<String, dynamic>>[]));

      await selection.refresh();

      expect(runner.calls.single, <String>['login', '--accounts']);
    });

    test('one account is not a choice', () async {
      runner.always('login', _accounts(<Map<String, dynamic>>[
        _account('one@example.com', active: true),
      ]));

      await selection.refresh();

      expect(selection.hasChoice, isFalse,
          reason: 'a switcher that can only pick what is picked is noise');
    });

    test('two accounts are', () async {
      runner.always('login', _accounts(<Map<String, dynamic>>[
        _account('one@example.com', active: true),
        _account('two@example.com'),
      ]));

      await selection.refresh();

      expect(selection.hasChoice, isTrue);
    });

    test('no accounts reads as signed out rather than as an error', () async {
      runner.always('login', _accounts(<Map<String, dynamic>>[]));

      await selection.refresh();

      expect(selection.accounts, isEmpty);
      expect(selection.activeEmail, isNull);
      expect(selection.hasError, isFalse);
    });

    test('overlapping refreshes only hit the engine once', () async {
      runner.always('login', _accounts(<Map<String, dynamic>>[]));
      runner.hold = Completer<void>();

      final Future<void> first = selection.refresh();
      final Future<void> second = selection.refresh();
      runner.hold!.complete();
      await Future.wait(<Future<void>>[first, second]);

      expect(runner.calls.length, 1);
    });
  });

  group('AccountSelection switching', () {
    setUp(() {
      runner.always('login', _accounts(<Map<String, dynamic>>[
        _account('one@example.com', active: true),
        _account('two@example.com'),
      ]));
    });

    test('switching sends the address and re-reads the list', () async {
      await selection.refresh();
      runner.calls.clear();
      runner.always('login', _accounts(<Map<String, dynamic>>[
        _account('one@example.com'),
        _account('two@example.com', active: true),
      ]));

      await selection.use('two@example.com');

      expect(runner.calls.first, <String>['login', '--use', 'two@example.com']);
      expect(runner.calls.last, <String>['login', '--accounts'],
          reason: 'the new active account has to come from the engine');
      expect(selection.activeEmail, 'two@example.com');
    });

    test('switching to the account already in use does nothing', () async {
      await selection.refresh();
      runner.calls.clear();

      await selection.use('one@example.com');

      expect(runner.calls, isEmpty);
    });

    test('the account being switched to is reported as busy', () async {
      await selection.refresh();
      runner.hold = Completer<void>();

      final Future<void> switching = selection.use('two@example.com');
      await Future<void>.delayed(Duration.zero);
      expect(selection.busyEmail, 'two@example.com');

      runner.hold!.complete();
      await switching;
      expect(selection.busyEmail, isNull);
    });

    test('a second switch is ignored while one is in flight', () async {
      await selection.refresh();
      runner.hold = Completer<void>();

      final Future<void> first = selection.use('two@example.com');
      await Future<void>.delayed(Duration.zero);
      final Future<void> second = selection.use('one@example.com');

      runner.hold!.complete();
      await Future.wait(<Future<void>>[first, second]);

      expect(
        runner.calls.where((List<String> a) => a.contains('--use')).length,
        1,
      );
    });
  });

  group('AccountSelection signing out', () {
    setUp(() {
      runner.always('login', _accounts(<Map<String, dynamic>>[
        _account('one@example.com', active: true),
        _account('two@example.com'),
      ]));
    });

    test('signing one out names it, so the other survives', () async {
      await selection.refresh();
      runner.calls.clear();

      await selection.signOut('two@example.com');

      expect(
        runner.calls.first,
        <String>['login', '--logout', '--email', 'two@example.com'],
      );
    });

    test('signing all out names nobody', () async {
      await selection.refresh();
      runner.calls.clear();

      await selection.signOutAll();

      expect(runner.calls.first, <String>['login', '--logout']);
    });
  });

  group('AccountSelection failures', () {
    test('a failure is reported as a sentence', () async {
      runner.always('login', EngineException('The engine is not answering.'));

      await selection.refresh();

      expect(selection.hasError, isTrue);
      expect(selection.error, 'The engine is not answering.');
      expect(selection.hasLoaded, isTrue);
    });

    test('a failed refresh keeps the accounts it already had', () async {
      runner.always('login', _accounts(<Map<String, dynamic>>[
        _account('one@example.com', active: true),
      ]));
      await selection.refresh();

      runner.always('login', EngineException('Gone away.'));
      await selection.refresh();

      expect(selection.activeEmail, 'one@example.com',
          reason: 'a hiccup should not make the UI claim nobody is signed in');
      expect(selection.hasError, isTrue);
    });

    test('a failed switch clears busy so the row is not stuck', () async {
      runner.always('login', EngineException('No.'));

      await selection.use('two@example.com');

      expect(selection.busyEmail, isNull);
      expect(selection.hasError, isTrue);
    });

    test('a success after a failure clears the message', () async {
      runner.next('login', EngineException('Transient.'));
      await selection.refresh();
      expect(selection.hasError, isTrue);

      runner.always('login', _accounts(<Map<String, dynamic>>[
        _account('one@example.com', active: true),
      ]));
      await selection.refresh();

      expect(selection.hasError, isFalse);
      expect(selection.error, isNull);
    });
  });
}
