import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/platform/app_paths.dart';

/// Joins with the host separator, exactly as [AppPaths] does.
String _join(List<String> parts) => parts.join(Platform.pathSeparator);

void main() {
  group('AppPaths.resolveRoot on Windows', () {
    String resolve(Map<String, String> environment) =>
        AppPaths.resolveRoot(environment, host: AppDataHost.windows);

    test('appends iPASide to %LOCALAPPDATA%', () {
      expect(
        resolve(const <String, String>{
          'LOCALAPPDATA': r'C:\Users\test\AppData\Local',
        }),
        _join(<String>[r'C:\Users\test\AppData\Local', 'iPASide']),
      );
    });

    test('does not double the separator when LOCALAPPDATA ends with one', () {
      expect(
        resolve(<String, String>{
          'LOCALAPPDATA': 'C:\\Users\\test\\AppData\\Local\\',
        }),
        r'C:\Users\test\AppData\Local\iPASide',
      );
    });

    test('rebuilds the canonical path from %USERPROFILE%', () {
      expect(
        resolve(const <String, String>{'USERPROFILE': r'C:\Users\test'}),
        _join(<String>[r'C:\Users\test', 'AppData', 'Local', 'iPASide']),
      );
    });

    test('treats a blank LOCALAPPDATA as unset', () {
      expect(
        resolve(const <String, String>{
          'LOCALAPPDATA': '   ',
          'USERPROFILE': r'C:\Users\test',
        }),
        _join(<String>[r'C:\Users\test', 'AppData', 'Local', 'iPASide']),
      );
    });

    test('falls back to HOMEDRIVE + HOMEPATH', () {
      expect(
        resolve(const <String, String>{
          'HOMEDRIVE': 'C:',
          'HOMEPATH': r'\Users\test',
        }),
        _join(<String>[r'C:\Users\test', 'AppData', 'Local', 'iPASide']),
      );
    });

    test('ignores a half-specified HOMEDRIVE/HOMEPATH pair', () {
      final String root = resolve(const <String, String>{'HOMEDRIVE': 'C:'});
      expect(root, startsWith(Directory.systemTemp.path));
      expect(root, endsWith('iPASide'));
    });

    test('lands in the temp directory when the environment is empty', () {
      final String root = resolve(const <String, String>{});
      expect(root, startsWith(Directory.systemTemp.path));
      expect(root, endsWith('iPASide'));
    });
  });

  group('AppPaths.resolveRoot on other hosts', () {
    test('macOS uses ~/Library/Application Support', () {
      expect(
        AppPaths.resolveRoot(const <String, String>{
          'HOME': '/Users/test',
        }, host: AppDataHost.macOS),
        _join(<String>[
          '/Users/test',
          'Library',
          'Application Support',
          'iPASide',
        ]),
      );
    });

    test('other hosts prefer XDG_DATA_HOME', () {
      expect(
        AppPaths.resolveRoot(const <String, String>{
          'XDG_DATA_HOME': '/home/test/.share',
          'HOME': '/home/test',
        }, host: AppDataHost.other),
        _join(<String>['/home/test/.share', 'iPASide']),
      );
    });

    test('other hosts fall back to ~/.local/share', () {
      expect(
        AppPaths.resolveRoot(const <String, String>{
          'HOME': '/home/test',
        }, host: AppDataHost.other),
        _join(<String>['/home/test', '.local', 'share', 'iPASide']),
      );
    });
  });

  group('AppPaths layout', () {
    const AppPaths paths = AppPaths.rooted(r'C:\data\iPASide');

    test('derives the auto-refresh log path from the root', () {
      expect(
        paths.autoRefreshLogPath,
        _join(<String>[r'C:\data\iPASide', 'autorefresh.log']),
      );
    });

    test('derives the settings path from the root', () {
      expect(
        paths.settingsPath,
        _join(<String>[r'C:\data\iPASide', 'settings.json']),
      );
    });

    test('the default instance is rooted at a real absolute path', () {
      expect(AppPaths.instance.root, endsWith('iPASide'));
      expect(AppPaths.instance.settingsPath, endsWith('settings.json'));
    });
  });

  group('AppPaths.ensureRootExists', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('ipaside_paths'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('creates the root and any missing parents', () {
      final AppPaths paths = AppPaths.rooted(
        _join(<String>[temp.path, 'nested', 'iPASide']),
      );

      paths.ensureRootExists();

      expect(Directory(paths.root).existsSync(), isTrue);
    });

    test('is a no-op when the root already exists', () {
      final AppPaths paths = AppPaths.rooted(temp.path);

      paths.ensureRootExists();
      paths.ensureRootExists();

      expect(Directory(paths.root).existsSync(), isTrue);
    });
  });
}
