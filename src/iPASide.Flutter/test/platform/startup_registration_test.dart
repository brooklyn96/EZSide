import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/platform/startup_registration.dart';

/// A Run key stand-in, so no test ever touches the real registry.
class _FakeRunKey implements RunKeyStore {
  final Map<String, String> values = <String, String>{};
  final List<String> writes = <String>[];
  int deletes = 0;

  /// Thrown by [read] when set.
  Object? readFailure;

  @override
  String? read(String name) {
    final Object? failure = readFailure;
    if (failure != null) throw failure;
    return values[name];
  }

  @override
  void write(String name, String data) {
    writes.add(data);
    values[name] = data;
  }

  @override
  void delete(String name) {
    deletes++;
    values.remove(name);
  }
}

const String _exe = r'C:\Program Files\EZSide\app\EZSide.exe';
const String _command = '"$_exe" --tray';

void main() {
  late _FakeRunKey runKey;
  late StartupRegistration startup;

  setUp(() {
    runKey = _FakeRunKey();
    startup = StartupRegistration(exePath: _exe, store: runKey);
  });

  test('names the Run key, value and argument from the contract', () {
    expect(
      StartupRegistration.runKeyPath,
      r'Software\Microsoft\Windows\CurrentVersion\Run',
    );
    expect(StartupRegistration.valueName, 'EZSide');
    expect(StartupRegistration.trayArg, '--tray');
  });

  test('is off when there is no value', () async {
    expect(startup.isSupported, isTrue);
    expect(await startup.isEnabled(), isFalse);
  });

  test('turning on writes the quoted exe path and --tray', () async {
    await startup.setEnabled(true);

    expect(runKey.values[StartupRegistration.valueName], _command);
    expect(await startup.isEnabled(), isTrue);
  });

  test('turning on again does not rewrite a correct value', () async {
    runKey.values[StartupRegistration.valueName] = _command;

    await startup.setEnabled(true);

    expect(runKey.writes, isEmpty);
  });

  test('the path compares without regard to case', () async {
    runKey.values[StartupRegistration.valueName] = _command.toUpperCase();

    expect(await startup.isEnabled(), isTrue);
  });

  test('a value for another exe counts as off and is rewritten', () async {
    runKey.values[StartupRegistration.valueName] =
        r'"D:\Old\EZSide.exe" --tray';

    expect(await startup.isEnabled(), isFalse);

    await startup.setEnabled(true);

    expect(runKey.values[StartupRegistration.valueName], _command);
    expect(await startup.isEnabled(), isTrue);
  });

  test('a value without --tray counts as off', () async {
    runKey.values[StartupRegistration.valueName] = '"$_exe"';

    expect(await startup.isEnabled(), isFalse);
  });

  test('turning off removes the value, even one for another exe', () async {
    runKey.values[StartupRegistration.valueName] =
        r'"D:\Old\EZSide.exe" --tray';

    await startup.setEnabled(false);

    expect(runKey.deletes, 1);
    expect(runKey.values, isEmpty);
    expect(await startup.isEnabled(), isFalse);
  });

  test('turning on repairs a value that cannot be read', () async {
    runKey.values[StartupRegistration.valueName] = 'garbage';
    runKey.readFailure = StartupRegistrationException('unsupported type');

    await startup.setEnabled(true);

    expect(runKey.writes, <String>[_command]);
  });

  test('turning off when already off is a success', () async {
    await startup.setEnabled(false);

    expect(runKey.deletes, 1);
    expect(runKey.values, isEmpty);
  });

  test('defaults to the running exe', () {
    final StartupRegistration current = StartupRegistration(store: runKey);

    expect(current.command, '"${Platform.resolvedExecutable}" --tray');
  });

  test(
    'is unsupported off Windows and changes nothing',
    () async {
      final StartupRegistration none = StartupRegistration(exePath: _exe);

      expect(none.isSupported, isFalse);
      expect(await none.isEnabled(), isFalse);
      await none.setEnabled(true);
    },
    skip: Platform.isWindows ? 'the real Run key exists here' : false,
  );
}
