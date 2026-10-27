import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine_locator.dart';

/// The separator the host OS uses; the locator under test is left on the host
/// OS so every probe hits the real filesystem layout.
final String sep = Platform.pathSeparator;

/// Where a bundled interpreter lives, per OS.
List<String> get bundledPythonParts => Platform.isWindows
    ? const <String>['engine', 'python', 'python.exe']
    : const <String>['engine', 'python', 'bin', 'python3'];

/// Where a checkout's virtualenv interpreter lives, per OS.
List<String> get venvPythonParts => Platform.isWindows
    ? const <String>['.venv', 'Scripts', 'python.exe']
    : const <String>['.venv', 'bin', 'python3'];

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ipaside_locator_');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  String path(List<String> parts) => <String>[root.path, ...parts].join(sep);

  String touch(List<String> parts) {
    final File file = File(path(parts));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('');
    return file.path;
  }

  String mkdir(List<String> parts) {
    final Directory dir = Directory(path(parts));
    dir.createSync(recursive: true);
    return dir.path;
  }

  EngineLocator locatorAt(String baseDirectory) => EngineLocator(
        environment: const <String, String>{},
        baseDirectory: baseDirectory,
      );

  group('EngineLocator.resolve', () {
    test('honours IPASIDE_ENGINE_EXE and runs it without -m', () {
      final String exe = touch(<String>['frozen', 'ipaside-engine.exe']);

      final EngineLaunchSpec spec = EngineLocator(
        environment: <String, String>{'IPASIDE_ENGINE_EXE': exe},
        baseDirectory: root.path,
      ).resolve();

      expect(spec.fileName, exe);
      expect(spec.prefixArgs, isEmpty);
      expect(spec.workingDirectory, isNull);
    });

    test('ignores an override that does not exist', () {
      final EngineLaunchSpec spec = EngineLocator(
        environment: <String, String>{
          'IPASIDE_ENGINE_EXE': path(<String>['missing.exe']),
        },
        baseDirectory: root.path,
      ).resolve();

      expect(spec.fileName, 'python');
      expect(spec.prefixArgs, <String>['-E', '-u', '-X', 'utf8', '-m', 'ipaside_engine']);
    });

    test('ignores an empty override', () {
      final EngineLaunchSpec spec = EngineLocator(
        environment: <String, String>{'IPASIDE_ENGINE_EXE': ''},
        baseDirectory: root.path,
      ).resolve();

      expect(spec.fileName, 'python');
    });

    test('prefers the bundled interpreter beside the app', () {
      final String python = touch(<String>['app', ...bundledPythonParts]);
      // A checkout further up must not win over the bundled interpreter.
      mkdir(<String>['src', 'iPASide.Engine', 'ipaside_engine']);

      final EngineLaunchSpec spec = locatorAt(path(<String>['app'])).resolve();

      expect(spec.fileName, python);
      expect(spec.prefixArgs, <String>['-E', '-u', '-X', 'utf8', '-m', 'ipaside_engine']);
      expect(spec.workingDirectory, isNull);
    });

    test('falls back to a repo checkout with a venv interpreter', () {
      mkdir(<String>['src', 'iPASide.Engine', 'ipaside_engine']);
      final String venv = touch(venvPythonParts);
      final String appDir =
          mkdir(<String>['src', 'iPASide.Flutter', 'build', 'runner']);

      final EngineLaunchSpec spec = locatorAt(appDir).resolve();
      final String expectedEngineDir =
          path(<String>['src', 'iPASide.Engine']);

      expect(spec.fileName, venv);
      expect(spec.prefixArgs, <String>['-E', '-u', '-X', 'utf8', '-m', 'ipaside_engine']);
      expect(spec.workingDirectory, expectedEngineDir);
    });

    test('uses bare python when the checkout has no venv', () {
      mkdir(<String>['src', 'iPASide.Engine', 'ipaside_engine']);

      final EngineLaunchSpec spec = locatorAt(root.path).resolve();

      expect(spec.fileName, 'python');
      // The working directory is how `-m` finds the package here.
      expect(spec.workingDirectory, path(<String>['src', 'iPASide.Engine']));
    });

    test('every interpreter launch is isolated from the environment', () {
      // Without -E the child inherits our PYTHONPATH, and a developer with one
      // pointing at a checkout of this project gets that engine rather than the
      // one iPASide shipped. Asserted for every interpreter path, since the flag
      // going missing on any one of them reopens the hole.
      final String bundled = touch(<String>['app', ...bundledPythonParts]);
      mkdir(<String>['src', 'iPASide.Engine', 'ipaside_engine']);
      final String venv = touch(venvPythonParts);

      final List<EngineLaunchSpec> interpreterSpecs = <EngineLaunchSpec>[
        locatorAt(path(<String>['app'])).resolve(),
        locatorAt(
          mkdir(<String>['src', 'iPASide.Flutter', 'build', 'runner']),
        ).resolve(),
      ];

      expect(interpreterSpecs.map((EngineLaunchSpec s) => s.fileName), <String>[
        bundled,
        venv,
      ]);
      for (final EngineLaunchSpec spec in interpreterSpecs) {
        expect(spec.prefixArgs, contains('-E'), reason: spec.fileName);
      }
    });

    test('falls back to bare python with no working directory', () {
      final EngineLaunchSpec spec = locatorAt(root.path).resolve();

      expect(spec.fileName, 'python');
      expect(spec.prefixArgs, <String>['-E', '-u', '-X', 'utf8', '-m', 'ipaside_engine']);
      expect(spec.workingDirectory, isNull);
    });

    test('a spec describes itself for diagnostics', () {
      expect(
        locatorAt(root.path).resolve().toString(),
        contains('fileName: python'),
      );
    });
  });

  group('EngineLocator.findRepoRoot', () {
    test('walks up to the directory holding the engine package', () {
      mkdir(<String>['src', 'iPASide.Engine', 'ipaside_engine']);
      final String deep = mkdir(<String>['a', 'b', 'c']);

      expect(locatorAt(root.path).findRepoRoot(deep), root.path);
    });

    test('returns the start directory when it is itself the root', () {
      mkdir(<String>['src', 'iPASide.Engine', 'ipaside_engine']);

      expect(locatorAt(root.path).findRepoRoot(root.path), root.path);
    });

    test('returns null when no ancestor is a checkout', () {
      expect(locatorAt(root.path).findRepoRoot(mkdir(<String>['a'])), isNull);
    });

    test('stops at the filesystem root instead of looping', () {
      expect(
        locatorAt(root.path).findRepoRoot(Directory.systemTemp.path),
        isNull,
      );
    });
  });
}
