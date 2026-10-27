import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/services/startup_query.dart';

void main() {
  group('StartupQuery.parse', () {
    test('returns the empty options for null, blank and empty input', () {
      expect(StartupQuery.parse(null), StartupOptions.empty);
      expect(StartupQuery.parse(''), StartupOptions.empty);
      expect(StartupQuery.parse('   '), StartupOptions.empty);
    });

    test('accepts a query with or without the leading question mark', () {
      expect(StartupQuery.parse('?view=library').view, 'library');
      expect(StartupQuery.parse('view=library').view, 'library');
      expect(StartupQuery.parse('  ?view=library  ').view, 'library');
    });

    test('reads every recognised key from one query', () {
      final StartupOptions options = StartupQuery.parse(
        '?view=sideload&theme=dark&ipa=C:\\apps\\demo.ipa'
        '&tweaks=C:\\t\\a.dylib|C:\\t\\b.deb&adv=1',
      );

      expect(options.view, 'sideload');
      expect(options.theme, 'dark');
      expect(options.ipaPath, r'C:\apps\demo.ipa');
      expect(options.tweakPaths, <String>[r'C:\t\a.dylib', r'C:\t\b.deb']);
      expect(options.advancedOpen, isTrue);
    });

    test('decodes + as a space', () {
      expect(StartupQuery.parse('ipa=my+app.ipa').ipaPath, 'my app.ipa');
    });

    test('decodes percent escapes', () {
      expect(
        StartupQuery.parse('ipa=C%3A%5Cmy%20apps%5Cdemo.ipa').ipaPath,
        r'C:\my apps\demo.ipa',
      );
    });

    test('decodes percent-escaped non-ASCII as UTF-8', () {
      expect(StartupQuery.parse('view=caf%C3%A9').view, 'café');
    });

    test('decodes the key as well as the value', () {
      expect(StartupQuery.parse('%76iew=home').view, 'home');
    });

    test('keeps the first occurrence of a duplicated key', () {
      expect(StartupQuery.parse('view=home&view=library').view, 'home');
    });

    test('keeps the first occurrence even when it is empty', () {
      // An empty first value wins the slot, and then reads as "not supplied".
      expect(StartupQuery.parse('view=&view=library').view, isNull);
    });

    test('skips pairs with no separator or an empty key', () {
      final StartupOptions options = StartupQuery.parse(
        'view&=orphan&&theme=light',
      );

      expect(options.view, isNull);
      expect(options.theme, 'light');
    });

    test('treats an empty value as absent', () {
      final StartupOptions options = StartupQuery.parse(
        'view=&theme=&ipa=&tweaks=',
      );

      expect(options.view, isNull);
      expect(options.theme, isNull);
      expect(options.ipaPath, isNull);
      expect(options.tweakPaths, isEmpty);
    });

    test('survives a malformed percent escape instead of throwing', () {
      expect(StartupQuery.parse('ipa=100%+demo').ipaPath, '100% demo');
    });

    test('accepts only light and dark as a theme override', () {
      expect(StartupQuery.parse('theme=light').theme, 'light');
      expect(StartupQuery.parse('theme=dark').theme, 'dark');
      expect(StartupQuery.parse('theme=sepia').theme, isNull);
      expect(StartupQuery.parse('theme=Dark').theme, isNull);
    });

    test('splits tweaks on the pipe and drops empty segments', () {
      expect(StartupQuery.parse('tweaks=a.dylib').tweakPaths, <String>[
        'a.dylib',
      ]);
      expect(StartupQuery.parse('tweaks=|a.dylib||b.deb|').tweakPaths, <String>[
        'a.dylib',
        'b.deb',
      ]);
    });

    test('decodes a percent-escaped pipe as a tweak separator', () {
      expect(StartupQuery.parse('tweaks=a.dylib%7Cb.deb').tweakPaths, <String>[
        'a.dylib',
        'b.deb',
      ]);
    });

    test('exposes tweak paths as an unmodifiable list', () {
      final List<String> tweaks = StartupQuery.parse(
        'tweaks=a.dylib',
      ).tweakPaths;

      expect(() => tweaks.add('b.deb'), throwsUnsupportedError);
    });

    test('opens Advanced only for exactly "1"', () {
      expect(StartupQuery.parse('adv=1').advancedOpen, isTrue);
      expect(StartupQuery.parse('adv=0').advancedOpen, isFalse);
      expect(StartupQuery.parse('adv=true').advancedOpen, isFalse);
      expect(StartupQuery.parse('view=home').advancedOpen, isFalse);
    });
  });

  group('StartupQuery.fromEnvironment', () {
    test('parses the IPASIDE_STARTUP_QUERY variable', () {
      final StartupOptions options = StartupQuery.fromEnvironment(
        const <String, String>{
          StartupQuery.environmentVariableName: '?view=settings&theme=light',
        },
      );

      expect(options.view, 'settings');
      expect(options.theme, 'light');
    });

    test('returns the empty options when the variable is missing', () {
      expect(
        StartupQuery.fromEnvironment(const <String, String>{
          'PATH': '/usr/bin',
        }),
        StartupOptions.empty,
      );
    });

    test('returns the empty options when the variable is blank', () {
      expect(
        StartupQuery.fromEnvironment(const <String, String>{
          StartupQuery.environmentVariableName: '  ',
        }),
        StartupOptions.empty,
      );
    });
  });

  group('StartupQuery.toThemeMode', () {
    test('maps only the two supported overrides', () {
      expect(StartupQuery.toThemeMode('light'), ThemeMode.light);
      expect(StartupQuery.toThemeMode('dark'), ThemeMode.dark);
      expect(StartupQuery.toThemeMode('default'), isNull);
      expect(StartupQuery.toThemeMode(null), isNull);
    });

    test('is reachable from the parsed options', () {
      expect(StartupQuery.parse('theme=dark').themeOverride, ThemeMode.dark);
      expect(StartupQuery.parse('view=home').themeOverride, isNull);
    });
  });

  group('StartupOptions equality', () {
    test('compares by value, including the tweak list', () {
      expect(
        StartupQuery.parse('view=home&tweaks=a.dylib'),
        StartupQuery.parse('view=home&tweaks=a.dylib'),
      );
      expect(
        StartupQuery.parse('view=home&tweaks=a.dylib'),
        isNot(StartupQuery.parse('view=home&tweaks=b.deb')),
      );
    });

    test('hashes equal options identically', () {
      expect(
        StartupQuery.parse('view=home&adv=1').hashCode,
        StartupQuery.parse('view=home&adv=1').hashCode,
      );
    });
  });
}
