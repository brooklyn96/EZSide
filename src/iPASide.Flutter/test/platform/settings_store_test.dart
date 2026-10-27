import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/platform/app_paths.dart';
import 'package:ipaside/services/settings_store.dart';

void main() {
  late Directory temp;
  late AppPaths paths;
  late SettingsStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('ipaside_settings');
    paths = AppPaths.rooted(temp.path);
    store = SettingsStore(paths: paths);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  void writeSettings(String contents) =>
      File(paths.settingsPath).writeAsStringSync(contents);

  Map<String, dynamic> readSettings() =>
      jsonDecode(File(paths.settingsPath).readAsStringSync())
          as Map<String, dynamic>;

  group('SettingsStore theme round trip', () {
    test('persists and reloads every mode', () {
      for (final ThemeMode mode in ThemeMode.values) {
        store.saveTheme(mode);
        expect(SettingsStore(paths: paths).loadTheme(), mode);
      }
    });

    test('writes the theme-only JSON shape the C# store used', () {
      store.saveTheme(ThemeMode.dark);

      expect(readSettings(), <String, String>{'theme': 'dark'});
    });

    test('writes "default" for the follow-the-OS mode', () {
      store.saveTheme(ThemeMode.system);

      expect(
        File(paths.settingsPath).readAsStringSync(),
        '{"theme":"default"}',
      );
    });

    test('overwrites a previous choice rather than appending', () {
      store.saveTheme(ThemeMode.light);
      store.saveTheme(ThemeMode.dark);

      expect(File(paths.settingsPath).readAsStringSync(), '{"theme":"dark"}');
    });

    test('creates the data root on first save', () {
      final AppPaths nested = AppPaths.rooted(
        '${temp.path}${Platform.pathSeparator}fresh',
      );

      SettingsStore(paths: nested).saveTheme(ThemeMode.light);

      expect(File(nested.settingsPath).existsSync(), isTrue);
      expect(SettingsStore(paths: nested).loadTheme(), ThemeMode.light);
    });
  });

  group('SettingsStore theme recovery', () {
    test('follows the OS when no settings file exists', () {
      expect(store.loadTheme(), ThemeMode.system);
    });

    test('follows the OS when the file is not valid JSON', () {
      writeSettings('{"theme":');

      expect(store.loadTheme(), ThemeMode.system);
    });

    test('follows the OS when the file is empty', () {
      writeSettings('');

      expect(store.loadTheme(), ThemeMode.system);
    });

    test('follows the OS when the root is a JSON array', () {
      writeSettings('["dark"]');

      expect(store.loadTheme(), ThemeMode.system);
    });

    test('follows the OS when the theme value is not a string', () {
      writeSettings('{"theme":42}');

      expect(store.loadTheme(), ThemeMode.system);
    });

    test('follows the OS for an unknown theme name', () {
      writeSettings('{"theme":"sepia"}');

      expect(store.loadTheme(), ThemeMode.system);
    });

    test('follows the OS when the theme key is missing', () {
      writeSettings('{"advOpen":true}');

      expect(store.loadTheme(), ThemeMode.system);
    });

    test('ignores any other keys a hand-edited file carries', () {
      writeSettings('{"advOpen":true,"theme":"light"}');

      expect(store.loadTheme(), ThemeMode.light);
    });

    test('a corrupt file is repaired by the next save', () {
      writeSettings('not json at all');
      expect(store.loadTheme(), ThemeMode.system);

      store.saveTheme(ThemeMode.dark);

      expect(store.loadTheme(), ThemeMode.dark);
    });

    test('saving into an unwritable location is swallowed', () {
      // A file where the root directory has to go: creating the root fails, so
      // the write cannot happen.
      final String blocked = '${temp.path}${Platform.pathSeparator}blocked';
      File(blocked).writeAsStringSync('not a directory');

      expect(
        () => SettingsStore(
          paths: AppPaths.rooted(blocked),
        ).saveTheme(ThemeMode.dark),
        returnsNormally,
      );
    });

    test('loading from an unreadable location is swallowed', () {
      final String blocked = '${temp.path}${Platform.pathSeparator}blocked';
      File(blocked).writeAsStringSync('not a directory');

      expect(
        SettingsStore(paths: AppPaths.rooted(blocked)).loadTheme(),
        ThemeMode.system,
      );
    });
  });

  group('SettingsStore signed IPAs', () {
    test('defaults to deleting into the engine directory', () {
      final SignedIpaSettings signed = store.loadSignedIpa();

      expect(signed.keep, isFalse);
      expect(signed.directory, isNull);
      expect(signed.usesDefaultDirectory, isTrue);
      expect(signed, const SignedIpaSettings());
    });

    test('round-trips both members', () {
      store.saveSignedIpa(
        const SignedIpaSettings(keep: true, directory: r'D:\signed'),
      );

      expect(
        SettingsStore(paths: paths).loadSignedIpa(),
        const SignedIpaSettings(keep: true, directory: r'D:\signed'),
      );
    });

    test('writes the documented shape, with a null for the default folder', () {
      store.saveSignedIpa(const SignedIpaSettings(keep: true));

      expect(readSettings(), <String, dynamic>{
        'signedIpa': <String, dynamic>{'keep': true, 'directory': null},
      });
    });

    test('a directory reset back to the default is stored as null', () {
      store.saveSignedIpa(
        const SignedIpaSettings(keep: true, directory: r'D:\signed'),
      );

      store.saveSignedIpa(
        store.loadSignedIpa().withDirectory(null),
      );

      expect(store.loadSignedIpa().directory, isNull);
      expect(store.loadSignedIpa().keep, isTrue, reason: 'keep is untouched');
    });

    test('a blank directory reads as the engine default', () {
      writeSettings('{"signedIpa":{"keep":true,"directory":"   "}}');

      expect(store.loadSignedIpa().directory, isNull);
      expect(store.loadSignedIpa().keep, isTrue);
    });

    test('a stored directory is trimmed', () {
      writeSettings('{"signedIpa":{"directory":"  D:\\\\signed  "}}');

      expect(store.loadSignedIpa().directory, r'D:\signed');
    });

    test('defaults apply member by member when the section is partial', () {
      writeSettings('{"signedIpa":{"keep":true}}');

      expect(store.loadSignedIpa(), const SignedIpaSettings(keep: true));
    });

    test('a section of the wrong type falls back to the defaults', () {
      writeSettings('{"signedIpa":42}');

      expect(store.loadSignedIpa(), const SignedIpaSettings());
    });

    test('members of the wrong type fall back individually', () {
      writeSettings('{"signedIpa":{"keep":"yes","directory":7}}');

      expect(store.loadSignedIpa(), const SignedIpaSettings());
    });
  });

  group('SettingsStore key preservation', () {
    test('saving the theme keeps the signed-IPA section', () {
      store.saveSignedIpa(
        const SignedIpaSettings(keep: true, directory: r'D:\signed'),
      );

      store.saveTheme(ThemeMode.dark);

      expect(store.loadTheme(), ThemeMode.dark);
      expect(
        store.loadSignedIpa(),
        const SignedIpaSettings(keep: true, directory: r'D:\signed'),
      );
    });

    test('saving the signed-IPA section keeps the theme', () {
      store.saveTheme(ThemeMode.light);

      store.saveSignedIpa(const SignedIpaSettings(keep: true));

      expect(store.loadTheme(), ThemeMode.light);
      expect(store.loadSignedIpa().keep, isTrue);
    });

    test('a key only a newer version knows survives every save', () {
      // What a downgrade looks like: this build has to write the file without
      // understanding all of it.
      writeSettings(
        '{"theme":"light","telemetry":{"optIn":true},"windowWidth":1400}',
      );

      store.saveTheme(ThemeMode.dark);
      store.saveSignedIpa(const SignedIpaSettings(keep: true));

      expect(readSettings(), <String, dynamic>{
        'theme': 'dark',
        'telemetry': <String, dynamic>{'optIn': true},
        'windowWidth': 1400,
        'signedIpa': <String, dynamic>{'keep': true, 'directory': null},
      });
    });

    test('an unknown member inside a known section survives too', () {
      writeSettings('{"signedIpa":{"keep":false,"compress":"zstd"}}');

      store.saveSignedIpa(const SignedIpaSettings(keep: true));

      expect(readSettings()['signedIpa'], <String, dynamic>{
        'keep': true,
        'compress': 'zstd',
        'directory': null,
      });
    });

    test('the file survives a round trip through an unrelated build', () {
      // Two stores over the same file, as the app and a future version would be.
      SettingsStore(paths: paths).saveTheme(ThemeMode.dark);
      writeSettings(
        jsonEncode(<String, dynamic>{
          ...readSettings(),
          'futureFeature': <String>['a', 'b'],
        }),
      );

      SettingsStore(paths: paths).saveSignedIpa(
        const SignedIpaSettings(keep: true, directory: r'D:\keep'),
      );

      final SettingsStore reopened = SettingsStore(paths: paths);
      expect(reopened.loadTheme(), ThemeMode.dark);
      expect(reopened.loadSignedIpa().directory, r'D:\keep');
      expect(readSettings()['futureFeature'], <String>['a', 'b']);
    });
  });

  group('SignedIpaSettings value semantics', () {
    test('equal sections compare and hash equal', () {
      const SignedIpaSettings a =
          SignedIpaSettings(keep: true, directory: r'D:\signed');
      const SignedIpaSettings b =
          SignedIpaSettings(keep: true, directory: r'D:\signed');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const SignedIpaSettings(directory: r'D:\signed')));
      expect(a, isNot(const SignedIpaSettings(keep: true)));
    });

    test('withKeep and withDirectory each change one member', () {
      const SignedIpaSettings start = SignedIpaSettings(directory: r'D:\a');

      expect(
        start.withKeep(true),
        const SignedIpaSettings(keep: true, directory: r'D:\a'),
      );
      expect(
        start.withKeep(true).withDirectory(r'D:\b'),
        const SignedIpaSettings(keep: true, directory: r'D:\b'),
      );
      expect(
        start.withDirectory(null),
        const SignedIpaSettings(),
        reason: 'null is a reset to the engine default, not "leave it alone"',
      );
    });

    test('carries both members in toString, for the failure log', () {
      expect(
        const SignedIpaSettings(keep: true, directory: r'D:\signed').toString(),
        r'SignedIpaSettings(keep: true, directory: D:\signed)',
      );
    });
  });
}
