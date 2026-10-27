import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine.dart';
import 'package:ipaside/platform/app_paths.dart';
import 'package:ipaside/services/auto_refresh_runner.dart';
import 'package:ipaside/services/settings_store.dart';

/// A transport stand-in that records argv and replays one canned frame.
class _FakeRunner with EngineCommandRunner {
  _FakeRunner({this.outcome});

  /// The result frame to answer with, or an error to throw. Null answers with an
  /// empty summary.
  Object? outcome;

  final List<List<String>> calls = <List<String>>[];

  @override
  Future<EngineResult> run(
    List<String> args, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  }) async {
    calls.add(args);
    final Object? result = outcome;
    if (result == null) {
      return const EngineResult(ok: true, data: <String, dynamic>{});
    }
    if (result is EngineResult) return result;
    throw result;
  }
}

/// An in-memory settings store, so the headless run never reads the real file.
class _FakeSettings extends SettingsStore {
  _FakeSettings({this.signedIpa = const SignedIpaSettings()});

  SignedIpaSettings signedIpa;
  int reads = 0;

  @override
  SignedIpaSettings loadSignedIpa() {
    reads++;
    return signedIpa;
  }
}

void main() {
  late Directory temp;
  late AppPaths paths;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('ipaside_autorefresh');
    paths = AppPaths.rooted(temp.path);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  String log() {
    final File file = File(paths.autoRefreshLogPath);
    return file.existsSync() ? file.readAsStringSync() : '';
  }

  group('AutoRefreshRunner.isRequested', () {
    test('matches the flag whatever its case', () {
      expect(AutoRefreshRunner.isRequested(<String>['--AUTO-REFRESH']), isTrue);
      expect(AutoRefreshRunner.isRequested(<String>['--auto-refresh']), isTrue);
      expect(AutoRefreshRunner.isRequested(<String>['-x', '--auto-refresh']),
          isTrue);
    });

    test('is absent from an ordinary launch', () {
      expect(AutoRefreshRunner.isRequested(const <String>[]), isFalse);
      expect(AutoRefreshRunner.isRequested(<String>['--autorefresh']), isFalse);
    });
  });

  // The scheduled run is the one nobody watches: if it ignored the keep-signed
  // setting it would quietly delete the files the user asked to keep, every
  // night, with nothing on screen to notice.
  group('AutoRefreshRunner keep-signed setting', () {
    test('refreshes only what is due, with neither flag by default', () async {
      final _FakeRunner runner = _FakeRunner();

      final int code = await AutoRefreshRunner.run(
        paths: paths,
        settings: _FakeSettings(),
        transport: runner,
      );

      expect(code, 0);
      expect(
        runner.calls.single,
        <String>['refresh'],
        reason: 'neither --all nor --bundle-id is how the engine is told '
            '"only the ones that are due"',
      );
    });

    test('passes --keep-signed when the setting is on', () async {
      final _FakeRunner runner = _FakeRunner();

      await AutoRefreshRunner.run(
        paths: paths,
        settings: _FakeSettings(
          signedIpa: const SignedIpaSettings(keep: true),
        ),
        transport: runner,
      );

      expect(runner.calls.single, <String>['refresh', '--keep-signed']);
    });

    test('passes the configured folder too', () async {
      final _FakeRunner runner = _FakeRunner();

      await AutoRefreshRunner.run(
        paths: paths,
        settings: _FakeSettings(
          signedIpa: const SignedIpaSettings(
            keep: true,
            directory: r'D:\Signed',
          ),
        ),
        transport: runner,
      );

      expect(runner.calls.single, <String>[
        'refresh',
        '--keep-signed',
        '--signed-dir',
        r'D:\Signed',
      ]);
    });

    test('reads the setting on the run, not at import time', () async {
      final _FakeSettings settings = _FakeSettings();

      await AutoRefreshRunner.run(
        paths: paths,
        settings: settings,
        transport: _FakeRunner(),
      );

      expect(settings.reads, 1);
    });
  });

  group('AutoRefreshRunner logging', () {
    test('records that there was nothing to do', () async {
      await AutoRefreshRunner.run(
        paths: paths,
        settings: _FakeSettings(),
        transport: _FakeRunner(),
      );

      expect(log(), contains('nothing to refresh'));
    });

    test('writes one line per app the engine reported on', () async {
      final _FakeRunner runner = _FakeRunner(
        outcome: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'refreshed': <dynamic>[
              <String, dynamic>{'bundle_id': 'com.a', 'status': 'installed'},
              <String, dynamic>{
                'bundle_id': 'com.b',
                'status': 'error',
                'error': 'device is not connected',
              },
            ],
          },
        ),
      );

      final int code = await AutoRefreshRunner.run(
        paths: paths,
        settings: _FakeSettings(),
        transport: runner,
      );

      expect(code, 0, reason: 'per-app failures are not a failed run');
      expect(log(), contains('com.a'));
      expect(log(), contains('com.b'));
      expect(log(), contains('device is not connected'));
    });

    test('a thrown run is logged and exits non-zero', () async {
      final _FakeRunner runner = _FakeRunner(
        outcome: EngineException('the engine could not be started'),
      );

      final int code = await AutoRefreshRunner.run(
        paths: paths,
        settings: _FakeSettings(),
        transport: runner,
      );

      expect(code, 1);
      expect(log(), contains('the engine could not be started'));
    });

    test('creates the data root it logs into', () async {
      final AppPaths nested = AppPaths.rooted(
        '${temp.path}${Platform.pathSeparator}fresh',
      );

      await AutoRefreshRunner.run(
        paths: nested,
        settings: _FakeSettings(),
        transport: _FakeRunner(),
      );

      expect(File(nested.autoRefreshLogPath).existsSync(), isTrue);
    });
  });
}
