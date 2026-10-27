import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/platform/app_paths.dart';

/// Joins with the host separator, exactly as [AppPaths] does.
String _join(List<String> parts) => parts.join(Platform.pathSeparator);

void main() {
  group('AppPaths.resolveRoot on Windows', () {
    String resolve(Map<String, String> environment) =>
        AppPaths.resolveRoot(environment, host: AppDataHost.windows);

    test('appends EZSide to %LOCALAPPDATA%', () {
      expect(
        resolve(const <String, String>{
          'LOCALAPPDATA': r'C:\Users\test\AppData\Local',
        }),
        _join(<String>[r'C:\Users\test\AppData\Local', 'EZSide']),
      );
    });

    test('does not double the separator when LOCALAPPDATA ends with one', () {
      expect(
        resolve(<String, String>{
          'LOCALAPPDATA': 'C:\\Users\\test\\AppData\\Local\\',
        }),
        r'C:\Users\test\AppData\Local\EZSide',
      );
    });

    test('rebuilds the canonical path from %USERPROFILE%', () {
      expect(
        resolve(const <String, String>{'USERPROFILE': r'C:\Users\test'}),
        _join(<String>[r'C:\Users\test', 'AppData', 'Local', 'EZSide']),
      );
    });

    test('treats a blank LOCALAPPDATA as unset', () {
      expect(
        resolve(const <String, String>{
          'LOCALAPPDATA': '   ',
          'USERPROFILE': r'C:\Users\test',
        }),
        _join(<String>[r'C:\Users\test', 'AppData', 'Local', 'EZSide']),
      );
    });

    test('falls back to HOMEDRIVE + HOMEPATH', () {
      expect(
        resolve(const <String, String>{
          'HOMEDRIVE': 'C:',
          'HOMEPATH': r'\Users\test',
        }),
        _join(<String>[r'C:\Users\test', 'AppData', 'Local', 'EZSide']),
      );
    });

    test('ignores a half-specified HOMEDRIVE/HOMEPATH pair', () {
      final String root = resolve(const <String, String>{'HOMEDRIVE': 'C:'});
      expect(root, startsWith(Directory.systemTemp.path));
      expect(root, endsWith('EZSide'));
    });

    test('lands in the temp directory when the environment is empty', () {
      final String root = resolve(const <String, String>{});
      expect(root, startsWith(Directory.systemTemp.path));
      expect(root, endsWith('EZSide'));
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
          'EZSide',
        ]),
      );
    });

    test('other hosts prefer XDG_DATA_HOME', () {
      expect(
        AppPaths.resolveRoot(const <String, String>{
          'XDG_DATA_HOME': '/home/test/.share',
          'HOME': '/home/test',
        }, host: AppDataHost.other),
        _join(<String>['/home/test/.share', 'EZSide']),
      );
    });

    test('other hosts fall back to ~/.local/share', () {
      expect(
        AppPaths.resolveRoot(const <String, String>{
          'HOME': '/home/test',
        }, host: AppDataHost.other),
        _join(<String>['/home/test', '.local', 'share', 'EZSide']),
      );
    });
  });

  group('AppPaths.resolveRoot data folder order', () {
    late Directory install;

    setUp(() {
      install = Directory.systemTemp.createTempSync('ipaside_install_');
    });
    tearDown(() => install.deleteSync(recursive: true));

    String exe() => _join(<String>[install.path, 'EZSide.exe']);

    void installEngine() {
      File(
        _join(<String>[install.path, 'engine', 'python', 'python.exe']),
      ).createSync(recursive: true);
    }

    String resolve(Map<String, String> environment, {String? executablePath}) =>
        AppPaths.resolveRoot(
          environment,
          host: AppDataHost.windows,
          executablePath: executablePath,
        );

    const Map<String, String> userEnv = <String, String>{
      'LOCALAPPDATA': r'C:\Users\test\AppData\Local',
    };

    test('IPASIDE_DATA_DIR wins over everything, used as given', () {
      installEngine();

      expect(
        resolve(<String, String>{
          ...userEnv,
          'IPASIDE_DATA_DIR': r'D:\state\EZSide',
        }, executablePath: exe()),
        r'D:\state\EZSide',
      );
    });

    test('a blank IPASIDE_DATA_DIR is ignored', () {
      expect(
        resolve(<String, String>{...userEnv, 'IPASIDE_DATA_DIR': '  '}),
        _join(<String>[r'C:\Users\test\AppData\Local', 'EZSide']),
      );
    });

    test('an installed engine next to the exe puts data in <app>/data', () {
      installEngine();

      expect(
        resolve(userEnv, executablePath: exe()),
        _join(<String>[install.path, 'data']),
      );
    });

    test('no engine next to the exe falls back to LOCALAPPDATA', () {
      expect(
        resolve(userEnv, executablePath: exe()),
        _join(<String>[r'C:\Users\test\AppData\Local', 'EZSide']),
      );
    });

    test('no executable path means the installed layout is not considered', () {
      installEngine();

      expect(
        resolve(userEnv),
        _join(<String>[r'C:\Users\test\AppData\Local', 'EZSide']),
      );
    });
  });

  group('AppPaths layout', () {
    const AppPaths paths = AppPaths.rooted(r'C:\data\EZSide');

    test('derives the fault log and scratch paths from the root', () {
      expect(
        paths.engineFaultLogPath,
        _join(<String>[r'C:\data\EZSide', 'engine-fault.log']),
      );
      expect(paths.tempPath, _join(<String>[r'C:\data\EZSide', 'tmp']));
    });

    test('derives the auto-refresh log path from the root', () {
      expect(
        paths.autoRefreshLogPath,
        _join(<String>[r'C:\data\EZSide', 'autorefresh.log']),
      );
    });

    test('derives the settings path from the root', () {
      expect(
        paths.settingsPath,
        _join(<String>[r'C:\data\EZSide', 'settings.json']),
      );
    });

    test('the default instance is rooted at a real absolute path', () {
      expect(AppPaths.instance.root, endsWith('EZSide'));
      expect(AppPaths.instance.settingsPath, endsWith('settings.json'));
    });
  });

  group('AppPaths.ensureRootExists', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('ipaside_paths'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('creates the root and any missing parents', () {
      final AppPaths paths = AppPaths.rooted(
        _join(<String>[temp.path, 'nested', 'EZSide']),
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
