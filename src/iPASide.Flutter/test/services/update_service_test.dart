import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
          'https://github.com/pwnapplehat/iPASide/releases/tag/v1.2.0',
        ).toString(),
        'https://github.com/pwnapplehat/iPASide/releases/tag/v1.2.0',
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
    test('opens https notes through cmd start', () async {
      final List<(String, List<String>)> launches = <(String, List<String>)>[];
      final UpdateService service = UpdateService(
        currentVersion: '1.0.0',
        log: (_) {},
        launchDetached: (String exe, List<String> args) async {
          launches.add((exe, List<String>.from(args)));
        },
      );

      const String page =
          'https://github.com/pwnapplehat/iPASide/releases/tag/v1.2.0';
      expect(await service.openReleaseNotes(page), isTrue);
      expect(launches.single.$1, 'cmd');
      expect(launches.single.$2, <String>['/c', 'start', '', page]);
    });

    test('falls back to the releases index for an unsafe URL', () async {
      final List<(String, List<String>)> launches = <(String, List<String>)>[];
      final UpdateService service = UpdateService(
        currentVersion: '1.0.0',
        log: (_) {},
        launchDetached: (String exe, List<String> args) async {
          launches.add((exe, List<String>.from(args)));
        },
      );

      expect(await service.openReleaseNotes('file:///tmp/x'), isTrue);
      expect(launches.single.$2.last, service.releasesPage.toString());
    });
  });
}
