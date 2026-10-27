import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine_api.dart';
import 'package:ipaside/engine/engine_client.dart';
import 'package:ipaside/engine/engine_exception.dart';
import 'package:ipaside/engine/models.dart';

class _StreamingRunner extends _FakeRunner {
  final StreamController<Map<String, dynamic>> bus =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => bus.stream;
}

/// A transport stand-in: records what the facade asked for and replays a
/// canned result plus canned progress lines.
class _FakeRunner with EngineCommandRunner {
  _FakeRunner({
    this.result = const EngineResult(ok: true, data: <String, dynamic>{}),
    this.progress = const <String>[],
  });

  EngineResult result;
  List<String> progress;

  final List<List<String>> calls = <List<String>>[];
  final List<Map<String, String>?> envs = <Map<String, String>?>[];
  bool progressWired = false;

  List<String> get lastArgs => calls.last;
  Map<String, String>? get lastEnv => envs.last;

  @override
  Future<EngineResult> run(
    List<String> args, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  }) async {
    calls.add(args);
    envs.add(env);
    progressWired = onProgress != null;
    for (final String line in progress) {
      onProgress?.call(line);
    }
    return result;
  }
}

Matcher _failsWith(String message) => throwsA(
      isA<EngineException>()
          .having((EngineException e) => e.message, 'message', message),
    );

void main() {
  group('EngineApi.buildSideloadArgs', () {
    test('default options emit only the path', () {
      expect(
        EngineApi.buildSideloadArgs(r'C:\ipa\app.ipa', const SideloadOptions()),
        <String>['sideload', r'C:\ipa\app.ipa'],
      );
    });

    test('a forced transport is named, automatic is not', () {
      // Automatic is what the engine does unasked, so emitting the flag would only
      // be noise; a forced choice has to be stated or it cannot be honoured.
      expect(
        EngineApi.buildSideloadArgs(
          'app.ipa',
          const SideloadOptions(udid: 'UDID1', connection: 'auto'),
        ),
        <String>['sideload', 'app.ipa', '--udid', 'UDID1'],
      );
      expect(
        EngineApi.buildSideloadArgs(
          'app.ipa',
          const SideloadOptions(udid: 'UDID1', connection: 'wifi'),
        ),
        <String>['sideload', 'app.ipa', '--udid', 'UDID1', '--connection', 'wifi'],
      );
      // A transport without a device is still meaningful on a one-device machine.
      expect(
        EngineApi.buildSideloadArgs(
          'app.ipa',
          const SideloadOptions(connection: 'usb'),
        ),
        <String>['sideload', 'app.ipa', '--connection', 'usb'],
      );
    });

    test('fully customised options emit every flag in order', () {
      expect(
        EngineApi.buildSideloadArgs(
          r'C:\ipa\app.ipa',
          const SideloadOptions(
            bundleId: '  com.example.app  ',
            name: '  Example  ',
            removeExtensions: false,
            removeDeviceRestrictions: false,
            enableFileSharing: true,
            weakDylibs: true,
            keepSigned: true,
            signedDirectory: r'D:\signed',
            dylibs: <String>[r'C:\tweaks\a.dylib', r'C:\tweaks\b.dylib'],
          ),
        ),
        <String>[
          'sideload',
          r'C:\ipa\app.ipa',
          '--bundle-id',
          'com.example.app',
          '--name',
          'Example',
          '--no-remove-extensions',
          '--no-remove-device-restrictions',
          '--enable-file-sharing',
          '--keep-signed',
          '--signed-dir',
          r'D:\signed',
          '--dylib',
          r'C:\tweaks\a.dylib',
          '--dylib',
          r'C:\tweaks\b.dylib',
          '--weak-dylibs',
        ],
      );
    });

    test('keeping the signed IPA emits the flag on its own', () {
      expect(
        EngineApi.buildSideloadArgs(
          'app.ipa',
          const SideloadOptions(keepSigned: true),
        ),
        <String>['sideload', 'app.ipa', '--keep-signed'],
      );
    });

    test('--no-keep-signed is never emitted, since false is the default', () {
      final List<String> args = EngineApi.buildSideloadArgs(
        'app.ipa',
        const SideloadOptions(),
      );

      expect(args, isNot(contains('--no-keep-signed')));
      expect(args, isNot(contains('--keep-signed')));
    });

    test('a signed folder is emitted whether or not the file is kept', () {
      // The folder is also where a `signed` listing looks, so it is not
      // conditional on the flag that writes into it.
      expect(
        EngineApi.buildSideloadArgs(
          'app.ipa',
          const SideloadOptions(signedDirectory: r'D:\signed'),
        ),
        <String>['sideload', 'app.ipa', '--signed-dir', r'D:\signed'],
      );
    });

    test('a blank signed folder means the engine default', () {
      expect(
        EngineApi.buildSideloadArgs(
          'app.ipa',
          const SideloadOptions(keepSigned: true, signedDirectory: '   '),
        ),
        <String>['sideload', 'app.ipa', '--keep-signed'],
      );
    });

    test('a signed folder is trimmed like the other overrides', () {
      expect(
        EngineApi.buildSideloadArgs(
          'app.ipa',
          const SideloadOptions(signedDirectory: '  D:\\signed  '),
        ),
        <String>['sideload', 'app.ipa', '--signed-dir', r'D:\signed'],
      );
    });

    test('the signed flags sit before the dylib block, not inside it', () {
      final List<String> args = EngineApi.buildSideloadArgs(
        'app.ipa',
        const SideloadOptions(
          keepSigned: true,
          signedDirectory: r'D:\signed',
          weakDylibs: true,
          dylibs: <String>['/a.dylib'],
        ),
      );

      expect(args, <String>[
        'sideload',
        'app.ipa',
        '--keep-signed',
        '--signed-dir',
        r'D:\signed',
        '--dylib',
        '/a.dylib',
        '--weak-dylibs',
      ]);
    });

    test('blank overrides are omitted', () {
      expect(
        EngineApi.buildSideloadArgs(
          'app.ipa',
          const SideloadOptions(bundleId: '   ', name: ''),
        ),
        <String>['sideload', 'app.ipa'],
      );
    });

    test('weak dylibs are dropped when nothing is injected', () {
      expect(
        EngineApi.buildSideloadArgs(
          'app.ipa',
          const SideloadOptions(weakDylibs: true),
        ),
        <String>['sideload', 'app.ipa'],
      );
    });

    test('dylibs without the weak flag emit no --weak-dylibs', () {
      expect(
        EngineApi.buildSideloadArgs(
          'app.ipa',
          const SideloadOptions(dylibs: <String>['/a.dylib']),
        ),
        <String>['sideload', 'app.ipa', '--dylib', '/a.dylib'],
      );
    });

    test('the remove flags only appear in their negated form', () {
      final List<String> args = EngineApi.buildSideloadArgs(
        'app.ipa',
        const SideloadOptions(),
      );
      expect(args, isNot(contains('--remove-extensions')));
      expect(args, isNot(contains('--no-remove-extensions')));
    });
  });

  group('EngineApi.parseProgress', () {
    test('parses a full progress event', () {
      expect(
        EngineApi.parseProgress(
          '{"event":"progress","phase":"provision","percent":null,'
          '"step":"Contacting Apple\u2026","bundle_id":"com.example.app"}',
        ),
        const SideloadProgress(
          phase: 'provision',
          step: 'Contacting Apple\u2026',
          bundleId: 'com.example.app',
        ),
      );
    });

    test('reads an integer percent as a double', () {
      final SideloadProgress? progress = EngineApi.parseProgress(
        '{"event":"progress","phase":"install","percent":42}',
      );
      expect(progress?.percent, 42.0);
    });

    test('reads a fractional percent', () {
      final SideloadProgress? progress = EngineApi.parseProgress(
        '{"event":"progress","phase":"install","percent":99.5}',
      );
      expect(progress?.percent, 99.5);
    });

    test('ignores a non-numeric percent', () {
      final SideloadProgress? progress = EngineApi.parseProgress(
        '{"event":"progress","percent":"42"}',
      );
      expect(progress, isNotNull);
      expect(progress?.percent, isNull);
    });

    test('rejects a different event type', () {
      expect(
        EngineApi.parseProgress('{"event":"done","phase":"install"}'),
        isNull,
      );
    });

    test('rejects an object without an event field', () {
      expect(EngineApi.parseProgress('{"phase":"install"}'), isNull);
    });

    test('rejects malformed JSON', () {
      expect(EngineApi.parseProgress('{"event":"progress"'), isNull);
      expect(EngineApi.parseProgress('not json at all'), isNull);
      expect(EngineApi.parseProgress(''), isNull);
    });

    test('rejects valid JSON that is not an object', () {
      expect(EngineApi.parseProgress('["event","progress"]'), isNull);
      expect(EngineApi.parseProgress('"progress"'), isNull);
      expect(EngineApi.parseProgress('7'), isNull);
    });

    test('tolerates a progress event with no other fields', () {
      expect(
        EngineApi.parseProgress('{"event":"progress"}'),
        const SideloadProgress(),
      );
    });
  });

  group('EngineApi typed commands', () {
    test('inspect maps the snake_case payload', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'bundle_id': 'com.burbn.instagram',
            'display_name': 'Instagram',
            'icon': 'aGk=',
            'version': '439.0.0',
            'minimum_os': '16.3',
            'frameworks': <String>['Flipper.framework'],
            'extensions': <String>['Share.appex', 'Widget.appex'],
            'has_sc_info': false,
          },
        ),
      );

      final IpaInspection inspection =
          await EngineApi(runner).inspect(r'C:\ipa\app.ipa');

      expect(runner.lastArgs, <String>['inspect', r'C:\ipa\app.ipa']);
      expect(inspection.bundleId, 'com.burbn.instagram');
      expect(inspection.displayName, 'Instagram');
      expect(inspection.minimumOs, '16.3');
      expect(inspection.frameworks, <String>['Flipper.framework']);
      expect(inspection.extensions, hasLength(2));
      expect(inspection.hasScInfo, isFalse);
    });

    test('resolveTweak unwraps the dylibs array', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'dylibs': <dynamic>[
              <String, dynamic>{
                'path': '/tmp/a.dylib',
                'name': 'a.dylib',
                'arches': <String>['arm64'],
                'from_deb': 'tweak.deb',
              },
            ],
          },
        ),
      );

      final List<TweakDylib> dylibs =
          await EngineApi(runner).resolveTweak('tweak.deb');

      expect(runner.lastArgs, <String>['resolve-tweak', 'tweak.deb']);
      expect(dylibs, hasLength(1));
      expect(dylibs.single.path, '/tmp/a.dylib');
      expect(dylibs.single.arches, <String>['arm64']);
      expect(dylibs.single.fromDeb, 'tweak.deb');
    });

    test('resolveTweak treats a missing dylibs key as empty', () async {
      final EngineApi api = EngineApi(
        _FakeRunner(
          result: const EngineResult(ok: true, data: <String, dynamic>{}),
        ),
      );
      expect(await api.resolveTweak('tweak.deb'), isEmpty);
    });

    test('sideload forwards argv and pumps parsed progress', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'status': 'installed',
            'name': 'Example',
            'bundle_id': 'com.example.app',
          },
        ),
        progress: <String>[
          '{"event":"progress","phase":"sign","step":"Signing"}',
          'plain stderr chatter',
          '{"event":"other","phase":"sign"}',
          '{"event":"progress","phase":"install","percent":100}',
        ],
      );
      final List<SideloadProgress> seen = <SideloadProgress>[];

      final SideloadResult result = await EngineApi(runner).sideload(
        'app.ipa',
        const SideloadOptions(),
        onProgress: seen.add,
      );

      expect(runner.lastArgs, <String>['sideload', 'app.ipa']);
      expect(result.status, 'installed');
      expect(result.bundleId, 'com.example.app');
      expect(seen, <SideloadProgress>[
        const SideloadProgress(phase: 'sign', step: 'Signing'),
        const SideloadProgress(phase: 'install', percent: 100),
      ]);
    });

    test('sideload wires no progress callback when none was given', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(ok: true, data: <String, dynamic>{}),
      );
      await EngineApi(runner).sideload('app.ipa', const SideloadOptions());
      expect(runner.progressWired, isFalse);
    });

    test('login sends the password via env, never argv', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{'status': '2fa_required', 'method': 'sms'},
        ),
      );

      final LoginResult result = await EngineApi(runner)
          .login('user@example.com', 'sup3r-s3cret');

      expect(
        runner.lastArgs,
        <String>['login', '--email', 'user@example.com'],
      );
      expect(runner.lastArgs, isNot(contains('sup3r-s3cret')));
      expect(
        runner.lastEnv,
        <String, String>{'IPASIDE_APPLE_PASSWORD': 'sup3r-s3cret'},
      );
      expect(result.requiresTwoFactor, isTrue);
      expect(result.method, 'sms');
    });

    test('login appends a verification code when given', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{'status': 'authenticated'},
        ),
      );

      await EngineApi(runner)
          .login('user@example.com', 'pw', code: '123456');

      expect(runner.lastArgs, <String>[
        'login',
        '--email',
        'user@example.com',
        '--code',
        '123456',
      ]);
    });

    test('login omits an empty code', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{'status': 'authenticated'},
        ),
      );

      await EngineApi(runner).login('user@example.com', 'pw', code: '');

      expect(runner.lastArgs, isNot(contains('--code')));
    });

    test('loginStatus, logout and uninstall use the documented argv', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{'authenticated': true, 'email': 'a@b.c'},
        ),
      );
      final EngineApi api = EngineApi(runner);

      final LoginStatus status = await api.loginStatus();
      expect(runner.lastArgs, <String>['login', '--status']);
      expect(status.authenticated, isTrue);
      expect(status.email, 'a@b.c');

      await api.logout();
      expect(runner.lastArgs, <String>['login', '--logout']);

      await api.uninstall('com.example.app');
      expect(runner.lastArgs, <String>['uninstall', 'com.example.app']);

      await api.forget('com.example.app');
      expect(runner.lastArgs, <String>['forget', 'com.example.app']);
    });

    test('devices maps the array and tolerates an empty one', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <dynamic>[
            <String, dynamic>{'connection_type': 'USB'},
            <String, dynamic>{'connection_type': 'Network'},
          ],
        ),
      );
      final EngineApi api = EngineApi(runner);

      expect(await api.devices(), <DeviceEntry>[
        const DeviceEntry(connectionType: 'USB'),
        const DeviceEntry(connectionType: 'Network'),
      ]);
      expect(runner.lastArgs, <String>['devices']);

      runner.result = const EngineResult(ok: true, data: <dynamic>[]);
      expect(await api.devices(), isEmpty);
    });

    test('deviceEvents maps live usbmux listings', () async {
      final _StreamingRunner runner = _StreamingRunner();
      final EngineApi api = EngineApi(runner);
      final Future<List<DeviceEntry>> next = api.deviceEvents.first;

      runner.bus.add(<String, dynamic>{
        'type': 'event',
        'name': 'devices',
        'data': <dynamic>[
          <String, dynamic>{
            'serial': 'AAAA1111',
            'connection_type': 'USB',
          },
        ],
      });

      expect(await next, <DeviceEntry>[
        const DeviceEntry(serial: 'AAAA1111', connectionType: 'USB'),
      ]);
    });

    test('deviceInfo maps the PascalCase lockdown keys', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'DeviceName': "iOS_hAT's iPhone",
            'ProductType': 'iPhone10,2',
            'ProductVersion': '16.7.15',
            'BuildVersion': '20H380',
            'UniqueDeviceID': '935cbbb9b82d25d15566e5939bcea5677b1c44ae',
          },
        ),
      );

      final DeviceInfo info = await EngineApi(runner).deviceInfo();

      expect(runner.lastArgs, <String>['device-info']);
      expect(info.deviceName, "iOS_hAT's iPhone");
      expect(info.productType, 'iPhone10,2');
      expect(info.productVersion, '16.7.15');
      expect(info.buildVersion, '20H380');
      expect(info.uniqueDeviceId, '935cbbb9b82d25d15566e5939bcea5677b1c44ae');
    });

    test('pairingStatus maps the pairing payload', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'udid': '00008150-001479110E20401C',
            'source': 'imported',
            'has_lockdown': true,
            'has_rppairing': true,
            'consumers': <dynamic>[
              <String, dynamic>{
                'id': 'escapeos',
                'name': 'EscapeOS',
                'bundle_id': 'com.ipaside.escapeos.TEAM',
                'needs_rppairing': true,
              },
            ],
          },
        ),
      );

      final PairingStatus status = await EngineApi(runner).pairingStatus(
        udid: '00008150-001479110E20401C',
      );

      expect(runner.lastArgs, <String>[
        'pairing',
        '--udid',
        '00008150-001479110E20401C',
      ]);
      expect(status.source, 'imported');
      expect(status.hasRppairing, isTrue);
      expect(status.consumers.single.id, 'escapeos');
    });

    test('exportPairing, importPairing and deliverPairing forward flags',
        () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'exported': true,
            'path': r'D:\pairingFile.plist',
            'imported': true,
            'placed': <dynamic>[],
          },
        ),
      );
      final EngineApi api = EngineApi(runner);

      await api.exportPairing(r'D:\pairingFile.plist', udid: 'U');
      expect(runner.lastArgs, <String>[
        'pairing',
        '--export',
        r'D:\pairingFile.plist',
        '--udid',
        'U',
      ]);

      await api.importPairing(r'C:\in.plist', udid: 'U', connection: 'usb');
      expect(runner.lastArgs, <String>[
        'pairing',
        '--import',
        r'C:\in.plist',
        '--udid',
        'U',
        '--connection',
        'usb',
      ]);

      await api.deliverPairing(udid: 'U');
      expect(runner.lastArgs, <String>['pairing', '--deliver', '--udid', 'U']);

      await api.deliverPairing(udid: 'U', bundleId: 'com.ipaside.escapeos.TEAM');
      expect(runner.lastArgs, <String>[
        'pairing',
        '--deliver',
        '--app',
        'com.ipaside.escapeos.TEAM',
        '--udid',
        'U',
      ]);

      await api.createPairing(udid: 'U');
      expect(runner.lastArgs, <String>['pairing', '--create', '--udid', 'U']);
    });

    test('apps maps the bundle-id keyed dict', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'com.example.app': <String, dynamic>{
              'name': 'Example',
              'version': '1.2',
            },
            'com.broken.app': 'not an object',
          },
        ),
      );

      final Map<String, InstalledApp> apps = await EngineApi(runner).apps();

      expect(runner.lastArgs, <String>['apps']);
      expect(apps, hasLength(1));
      expect(
        apps['com.example.app'],
        const InstalledApp(name: 'Example', version: '1.2'),
      );
    });

    test('installs maps records including nested options', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <dynamic>[
            <String, dynamic>{
              'bundle_id': 'com.ipaside.instagram',
              'name': 'Instagram',
              'days_left': 5,
              'expired': false,
              'options': <String, dynamic>{
                'dylibs': <String>['/tmp/a.dylib'],
              },
            },
            <String, dynamic>{'bundle_id': 'com.no.options'},
          ],
        ),
      );

      final List<InstallRecord> records = await EngineApi(runner).installs();

      expect(runner.lastArgs, <String>['installs']);
      expect(records, hasLength(2));
      expect(records.first.daysLeft, 5.0);
      expect(records.first.options?.dylibs, <String>['/tmp/a.dylib']);
      expect(records.last.options, isNull);
    });

    test('refresh argv covers the bundle, all and due-only cases', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{'refreshed': <dynamic>[]},
        ),
      );
      final EngineApi api = EngineApi(runner);

      await api.refresh();
      expect(runner.lastArgs, <String>['refresh']);

      await api.refresh(all: true);
      expect(runner.lastArgs, <String>['refresh', '--all']);

      await api.refresh(bundleId: 'com.example.app', all: true);
      expect(
        runner.lastArgs,
        <String>['refresh', '--bundle-id', 'com.example.app'],
        reason: 'a specific bundle wins over --all',
      );
    });

    test('refresh carries the same signed-IPA flags a sideload does', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{'refreshed': <dynamic>[]},
        ),
      );
      final EngineApi api = EngineApi(runner);

      await api.refresh(all: true, keepSigned: true);
      expect(
        runner.lastArgs,
        <String>['refresh', '--all', '--keep-signed'],
      );

      await api.refresh(
        bundleId: 'com.example.app',
        keepSigned: true,
        signedDirectory: r'D:\signed',
      );
      expect(runner.lastArgs, <String>[
        'refresh',
        '--bundle-id',
        'com.example.app',
        '--keep-signed',
        '--signed-dir',
        r'D:\signed',
      ]);

      await api.refresh();
      expect(
        runner.lastArgs,
        <String>['refresh'],
        reason: 'the default refresh is unchanged',
      );
    });

    test('refresh names a forced transport, and never a device', () async {
      // A refresh reinstalls onto the device its record names, so --udid would mean
      // nothing; the transport is a preference about this PC, and the unattended run
      // has to honour it rather than quietly going over the air after USB was asked for.
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{'refreshed': <dynamic>[]},
        ),
      );
      final EngineApi api = EngineApi(runner);

      await api.refresh(all: true, connection: 'wifi');
      expect(
        runner.lastArgs,
        <String>['refresh', '--all', '--connection', 'wifi'],
      );

      await api.refresh(bundleId: 'com.example.app', connection: 'usb');
      expect(runner.lastArgs, <String>[
        'refresh',
        '--bundle-id',
        'com.example.app',
        '--connection',
        'usb',
      ]);

      await api.refresh(all: true, connection: 'auto');
      expect(
        runner.lastArgs,
        <String>['refresh', '--all'],
        reason: 'automatic is the engine default, so it is left unsaid',
      );

      expect(
        runner.lastArgs,
        isNot(contains('--udid')),
        reason: 'refresh does not accept one',
      );
    });

    test('refresh maps per-app outcomes', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'refreshed': <dynamic>[
              <String, dynamic>{'bundle_id': 'com.a', 'status': 'refreshed'},
              <String, dynamic>{
                'bundle_id': 'com.b',
                'status': 'error',
                'error': 'no device',
              },
            ],
          },
        ),
      );

      final RefreshSummary summary = await EngineApi(runner).refresh(all: true);

      expect(summary.refreshed, hasLength(2));
      expect(summary.refreshed.last.error, 'no device');
    });

    test('signed reads the engine folder when none is given', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'directory': r'C:\signed',
            'count': 1,
            'bytes': 244318208,
            'files': <dynamic>[
              <String, dynamic>{
                'name': 'app.ipa',
                'bytes': 244318208,
                'modified': '2026-07-25T12:00:00Z',
              },
            ],
          },
        ),
      );

      final SignedIpaListing listing = await EngineApi(runner).signed();

      expect(runner.lastArgs, <String>['signed']);
      expect(listing.directory, r'C:\signed');
      expect(listing.count, 1);
      expect(listing.bytes, 244318208);
      expect(listing.files.single.name, 'app.ipa');
    });

    test('signed targets a folder when one is given', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(ok: true, data: <String, dynamic>{}),
      );
      final EngineApi api = EngineApi(runner);

      await api.signed(directory: r'D:\signed');
      expect(runner.lastArgs, <String>['signed', '--dir', r'D:\signed']);

      await api.signed(directory: '  D:\\signed  ');
      expect(
        runner.lastArgs,
        <String>['signed', '--dir', r'D:\signed'],
        reason: 'trimmed, like every other path argument',
      );

      await api.signed(directory: '   ');
      expect(
        runner.lastArgs,
        <String>['signed'],
        reason: 'a blank folder means the engine default',
      );
    });

    test('cleanSigned deletes and reports what it freed', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'directory': r'C:\signed',
            'removed': 3,
            'bytes_freed': 732823552,
          },
        ),
      );
      final EngineApi api = EngineApi(runner);

      final SignedIpaCleanup cleanup = await api.cleanSigned();
      expect(runner.lastArgs, <String>['signed', '--clean']);
      expect(cleanup.removed, 3);
      expect(cleanup.bytesFreed, 732823552);
      expect(cleanup.directory, r'C:\signed');

      await api.cleanSigned(directory: r'D:\signed');
      expect(
        runner.lastArgs,
        <String>['signed', '--clean', '--dir', r'D:\signed'],
      );
    });

    test('a signed listing that fails raises the cleaned error', () async {
      await expectLater(
        EngineApi(
          _FakeRunner(
            result: const EngineResult(
              ok: false,
              error: 'Engine exited with code 1. permission denied',
            ),
          ),
        ).signed(),
        _failsWith('permission denied'),
      );
    });

    test('anisette and version map their payloads', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'package_version': '1.2.4',
            'state_cached': true,
          },
        ),
      );
      final EngineApi api = EngineApi(runner);

      final AnisetteStatus anisette = await api.anisette();
      expect(runner.lastArgs, <String>['anisette']);
      expect(anisette.packageVersion, '1.2.4');
      expect(anisette.stateCached, isTrue);

      runner.result = const EngineResult(
        ok: true,
        data: <String, dynamic>{'version': '0.1.0'},
      );
      expect((await api.version()).version, '0.1.0');
      expect(runner.lastArgs, <String>['version']);
    });
  });

  group('EngineApi apple support', () {
    test('the status argv names no action, since status is the default', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'state': 'stopped',
            'service_name': 'Apple Mobile Device Service',
            'service_state': 'STOPPED',
            'itunes_installed': true,
            'itunes_version': '12.13.10.3',
            'detail': 'installed but not running',
          },
        ),
      );

      final AppleSupportStatus status = await EngineApi(runner).appleSupport();

      expect(runner.lastArgs, <String>['apple-support']);
      expect(status.state, AppleSupportStatus.stopped);
      expect(status.serviceState, 'STOPPED');
      expect(status.itunesInstalled, isTrue);
      expect(status.itunesVersion, '12.13.10.3');
      expect(status.detail, 'installed but not running');
      expect(status.isStopped, isTrue);
      expect(status.blocksDevices, isTrue);
    });

    test('each state is read as itself, and an unknown one blocks nothing', () async {
      final _FakeRunner runner = _FakeRunner();
      final EngineApi api = EngineApi(runner);

      Future<AppleSupportStatus> read(String state) {
        runner.result = EngineResult(
          ok: true,
          data: <String, dynamic>{'state': state},
        );
        return api.appleSupport();
      }

      expect((await read('running')).isRunning, isTrue);
      expect((await read('running')).blocksDevices, isFalse);
      expect((await read('stopped')).isStopped, isTrue);
      expect((await read('missing')).isMissing, isTrue);
      expect((await read('unsupported')).isUnsupported, isTrue);
      expect(
        (await read('unsupported')).blocksDevices,
        isFalse,
        reason: 'a host with no such service is not a machine to nag',
      );
      // A word from a newer engine must not blank a working machine's screen.
      final AppleSupportStatus future = await read('reinstalling');
      expect(future.isRunning, isFalse);
      expect(future.blocksDevices, isFalse);
    });

    test('downloadItunes asks for the download and pumps progress', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'path': r'C:\data\downloads\iTunes64Setup.exe',
            'bytes': 208064480,
            'signer': 'CN=Apple Inc., O=Apple Inc., C=US',
            'signature_status': 'Valid',
          },
        ),
        progress: <String>[
          '{"event":"progress","phase":"download","percent":42,'
              '"step":"Downloading iTunes"}',
        ],
      );
      final List<SideloadProgress> seen = <SideloadProgress>[];

      final ItunesDownload download = await EngineApi(runner).downloadItunes(
        onProgress: seen.add,
      );

      expect(runner.lastArgs, <String>['apple-support', '--download']);
      expect(download.path, r'C:\data\downloads\iTunes64Setup.exe');
      expect(download.bytes, 208064480);
      expect(download.signatureStatus, 'Valid');
      expect(seen.single.phase, 'download');
      expect(seen.single.percent, 42);
    });

    test('a download folder is named only when one is chosen', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(ok: true, data: <String, dynamic>{}),
      );
      final EngineApi api = EngineApi(runner);

      await api.downloadItunes(directory: r'D:\dl');
      expect(
        runner.lastArgs,
        <String>['apple-support', '--download', '--dir', r'D:\dl'],
      );

      await api.downloadItunes(directory: '  D:\\dl  ');
      expect(
        runner.lastArgs,
        <String>['apple-support', '--download', '--dir', r'D:\dl'],
        reason: 'trimmed, like every other path argument',
      );

      await api.downloadItunes(directory: '   ');
      expect(
        runner.lastArgs,
        <String>['apple-support', '--download'],
        reason: 'blank means the engine default',
      );
    });

    test('a refused download raises the engine sentence', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: false,
          data: <String, dynamic>{
            'status': 'error',
            'error': 'The downloaded iTunes installer is signed by '
                "'CN=Contoso Ltd', not by Apple Inc., so it was not installed.",
          },
          error: 'engine error',
        ),
      );

      await expectLater(
        EngineApi(runner).downloadItunes(),
        _failsWith(
          'The downloaded iTunes installer is signed by '
          "'CN=Contoso Ltd', not by Apple Inc., so it was not installed.",
        ),
      );
    });

    test('startAppleService carries the fresh status back with it', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'started': true,
            'reason': 'started',
            'detail': 'running now',
            'status': <String, dynamic>{'state': 'running'},
          },
        ),
      );

      final AppleServiceStart result =
          await EngineApi(runner).startAppleService();

      expect(runner.lastArgs, <String>['apple-support', '--start-service']);
      expect(result.started, isTrue);
      expect(result.wasDeclined, isFalse);
      expect(result.status?.isRunning, isTrue);
    });

    test('a declined elevation resolves rather than raising', () async {
      // Refusing administrator rights is an answer, not a fault: the engine exits
      // zero and says so, so nothing here may throw.
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'started': false,
            'reason': 'elevation_declined',
            'detail': 'the request was declined',
            'status': <String, dynamic>{'state': 'stopped'},
          },
        ),
      );

      final AppleServiceStart result =
          await EngineApi(runner).startAppleService();

      expect(result.started, isFalse);
      expect(result.wasDeclined, isTrue);
      expect(result.status?.isStopped, isTrue);
    });

    test('a start payload without its status is not invented', () async {
      final _FakeRunner runner = _FakeRunner(
        result: const EngineResult(
          ok: true,
          data: <String, dynamic>{'started': false, 'reason': 'failed'},
        ),
      );

      final AppleServiceStart result =
          await EngineApi(runner).startAppleService();

      expect(result.status, isNull);
    });
  });

  group('EngineApi doctor', () {
    const Map<String, dynamic> report = <String, dynamic>{
      'overall': 'fail',
      'checks': <dynamic>[
        <String, dynamic>{
          'status': 'fail',
          'name': 'iTunes',
          'detail': 'Apple Mobile Device Service is not running',
        },
      ],
    };

    test('returns the report on success', () async {
      final DoctorReport result = await EngineApi(
        _FakeRunner(
          result: const EngineResult(
            ok: true,
            data: <String, dynamic>{'overall': 'ok', 'checks': <dynamic>[]},
          ),
        ),
      ).doctor();

      expect(result.overall, 'ok');
      expect(result.checks, isEmpty);
    });

    test('returns the report even though a failing run exits non-zero', () async {
      final DoctorReport result = await EngineApi(
        _FakeRunner(
          result: const EngineResult(
            ok: false,
            data: report,
            error: 'engine error',
          ),
        ),
      ).doctor();

      expect(result.overall, 'fail');
      expect(result.checks.single.name, 'iTunes');
    });

    test('accepts a report that carries only checks', () async {
      final DoctorReport result = await EngineApi(
        _FakeRunner(
          result: const EngineResult(
            ok: false,
            data: <String, dynamic>{'checks': <dynamic>[]},
          ),
        ),
      ).doctor();

      expect(result.overall, isNull);
    });

    test('throws when a failure carries no report', () async {
      await expectLater(
        EngineApi(
          _FakeRunner(
            result: const EngineResult(
              ok: false,
              data: <String, dynamic>{'status': 'error', 'error': 'crashed'},
              error: 'crashed',
            ),
          ),
        ).doctor(),
        _failsWith('crashed'),
      );
    });

    test('throws when a failure carries no payload at all', () async {
      await expectLater(
        EngineApi(
          _FakeRunner(
            result: const EngineResult(ok: false, error: 'engine error'),
          ),
        ).doctor(),
        _failsWith('engine error'),
      );
    });

    test('throws when a successful run returns no data', () async {
      await expectLater(
        EngineApi(_FakeRunner(result: const EngineResult(ok: true))).doctor(),
        _failsWith('The engine returned no data.'),
      );
    });

    test('throws when a successful run returns an unusable payload', () async {
      await expectLater(
        EngineApi(
          _FakeRunner(result: const EngineResult(ok: true, data: <dynamic>[])),
        ).doctor(),
        _failsWith('The engine returned an unexpected null payload.'),
      );
    });
  });

  group('EngineApi failure mapping', () {
    test('a failed typed call raises the cleaned engine error', () async {
      await expectLater(
        EngineApi(
          _FakeRunner(
            result: const EngineResult(
              ok: false,
              data: <String, dynamic>{
                'status': 'error',
                'error': 'Login failed: invalid password',
              },
              error: 'Engine exited with code 1. noise',
            ),
          ),
        ).loginStatus(),
        _failsWith('invalid password'),
      );
    });

    test('a failed void call raises too', () async {
      await expectLater(
        EngineApi(
          _FakeRunner(
            result: const EngineResult(ok: false, error: 'device is locked'),
          ),
        ).uninstall('com.example.app'),
        _failsWith('device is locked'),
      );
    });

    test('a successful call with no data raises', () async {
      await expectLater(
        EngineApi(_FakeRunner(result: const EngineResult(ok: true)))
            .inspect('app.ipa'),
        _failsWith('The engine returned no data.'),
      );
    });

    test('a payload of the wrong shape raises', () async {
      await expectLater(
        EngineApi(
          _FakeRunner(
            result: const EngineResult(ok: true, data: <dynamic>['nope']),
          ),
        ).inspect('app.ipa'),
        _failsWith('The engine returned an unexpected null payload.'),
      );

      await expectLater(
        EngineApi(
          _FakeRunner(
            result: const EngineResult(ok: true, data: <String, dynamic>{}),
          ),
        ).devices(),
        _failsWith('The engine returned an unexpected null payload.'),
      );
    });

    test('a void call succeeds without any payload', () async {
      await EngineApi(_FakeRunner(result: const EngineResult(ok: true)))
          .logout();
    });
  });
}
