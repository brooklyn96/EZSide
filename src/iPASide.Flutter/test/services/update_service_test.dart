import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/platform/url_opener.dart';
import 'package:ipaside/services/update_planner.dart';
import 'package:ipaside/services/update_service.dart';

void main() {
  group('silentInstallArgs', () {
    test('matches the BitBroom silent-upgrade flag set', () {
      expect(
        UpdateService.silentInstallArgs,
        <String>[
          '/SILENT',
          '/NORESTART',
          '/CLOSEAPPLICATIONS',
          '/RESTARTAPPLICATIONS',
        ],
      );
    });
  });

  group('resolveReleaseNotesUri', () {
    late UpdateService service;

    setUp(() {
      service = UpdateService(currentVersion: '1.0.0', log: (_) {});
    });

    test('keeps a https release page from GitHub', () {
      expect(
        service.resolveReleaseNotesUri(
          'https://github.com/brooklyn96/EZSide/releases/tag/v1.2.0',
        ).toString(),
        'https://github.com/brooklyn96/EZSide/releases/tag/v1.2.0',
      );
    });

    test('falls back when the URL is missing or blank', () {
      expect(service.resolveReleaseNotesUri(null), service.releasesPage);
      expect(service.resolveReleaseNotesUri(''), service.releasesPage);
      expect(service.resolveReleaseNotesUri('   '), service.releasesPage);
    });

    test('refuses non-http schemes from a release payload', () {
      expect(
        service.resolveReleaseNotesUri(r'file:///C:/Windows/System32/calc.exe'),
        service.releasesPage,
      );
      expect(
        service.resolveReleaseNotesUri('javascript:alert(1)'),
        service.releasesPage,
      );
    });
  });

  group('installStaged', () {
    test('refuses a setup path that is not on disk', () async {
      final List<(String, List<String>)> launches = <(String, List<String>)>[];
      final UpdateService service = UpdateService(
        currentVersion: '1.0.0',
        log: (_) {},
        launchDetached: (String exe, List<String> args) async {
          launches.add((exe, args));
        },
      );

      final bool started = await service.installStaged(
        const PendingUpdate(
          version: '1.2.0',
          setupPath: r'C:\nowhere\missing-setup.exe',
          sizeBytes: 1,
        ),
      );

      expect(started, isFalse);
      expect(launches, isEmpty);
    });

    test('launches the staged setup with the silent-upgrade args', () async {
      final Directory directory =
          Directory.systemTemp.createTempSync('ipaside-update-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final File setup = File('${directory.path}${Platform.pathSeparator}setup.exe')
        ..writeAsBytesSync(const <int>[0x4D, 0x5A]);

      final List<(String, List<String>)> launches = <(String, List<String>)>[];
      final UpdateService service = UpdateService(
        currentVersion: '1.0.0',
        log: (_) {},
        launchDetached: (String exe, List<String> args) async {
          launches.add((exe, List<String>.from(args)));
        },
      );

      final bool started = await service.installStaged(
        PendingUpdate(
          version: '1.2.0',
          setupPath: setup.path,
          sizeBytes: 2,
        ),
      );

      expect(started, isTrue);
      expect(launches, hasLength(1));
      expect(launches.single.$1, setup.path);
      expect(launches.single.$2, UpdateService.silentInstallArgs);
    });

    test('a refused launch returns false without claiming success', () async {
      final Directory directory =
          Directory.systemTemp.createTempSync('ipaside-update-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final File setup = File('${directory.path}${Platform.pathSeparator}setup.exe')
        ..writeAsBytesSync(const <int>[0x4D, 0x5A]);

      final UpdateService service = UpdateService(
        currentVersion: '1.0.0',
        log: (_) {},
        launchDetached: (String exe, List<String> args) async {
          throw const FileSystemException('blocked');
        },
      );

      expect(
        await service.installStaged(
          PendingUpdate(
            version: '1.2.0',
            setupPath: setup.path,
            sizeBytes: 2,
          ),
        ),
        isFalse,
      );
    });
  });

  group('openReleaseNotes', () {
    late List<String> opened;
    late List<(String, List<String>)> launches;
    late UpdateService service;

    setUp(() {
      opened = <String>[];
      launches = <(String, List<String>)>[];
      service = UpdateService(
        currentVersion: '1.0.0',
        log: (_) {},
        launchDetached: (String exe, List<String> args) async {
          launches.add((exe, List<String>.from(args)));
        },
        urlOpener: (String url) async {
          opened.add(url);
          return true;
        },
      );
    });

    test('hands https notes to the opener, never to cmd', () async {
      const String page =
          'https://github.com/brooklyn96/EZSide/releases/tag/v1.2.0';
      expect(await service.openReleaseNotes(page), isTrue);
      expect(opened, <String>[page]);
      expect(launches, isEmpty, reason: 'no process, and so no cmd, is started');
    });

    test('keeps & in a URL intact', () async {
      const String page = 'https://example.com/a?x=1&y=2';
      await service.openReleaseNotes(page);
      expect(opened.single, page);
    });

    test('falls back to the releases index for an unsafe URL', () async {
      expect(await service.openReleaseNotes('file:///tmp/x'), isTrue);
      expect(opened.single, service.releasesPage.toString());
      expect(launches, isEmpty);
    });

    test('reports false when the opener refuses', () async {
      final UpdateService refusing = UpdateService(
        currentVersion: '1.0.0',
        log: (_) {},
        urlOpener: (String url) async => false,
      );
      expect(await refusing.openReleaseNotes(), isFalse);
    });

    test('reports false when the opener throws', () async {
      final UpdateService failing = UpdateService(
        currentVersion: '1.0.0',
        log: (_) {},
        urlOpener: (String url) async => throw const FileSystemException('x'),
      );
      expect(await failing.openReleaseNotes(), isFalse);
    });
  });

  group('openUrl', () {
    test('rejects every non-http scheme before touching the shell', () async {
      expect(await openUrl('file:///C:/Windows/System32/calc.exe'), isFalse);
      expect(await openUrl('javascript:alert(1)'), isFalse);
      expect(await openUrl('ms-settings:'), isFalse);
      expect(await openUrl('calc.exe'), isFalse);
      expect(await openUrl(''), isFalse);
    });
  });
}
