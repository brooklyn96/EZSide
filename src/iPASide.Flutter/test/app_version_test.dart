import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/app_version.dart';

void main() {
  test('kAppVersion matches the version in pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)', multiLine: true)
        .firstMatch(pubspec);

    expect(match, isNotNull, reason: 'pubspec.yaml has no three-part version');
    expect(
      kAppVersion,
      match!.group(1),
      reason: 'kAppVersion drifted from pubspec.yaml; the updater compares against it',
    );
  });

  test('resolvedAppVersion defaults to kAppVersion', () {
    expect(
      Platform.environment.containsKey('IPASIDE_TEST_CURRENT_VERSION'),
      isFalse,
      reason: 'the suite must not inherit a fake updater version',
    );
    expect(resolvedAppVersion, kAppVersion);
  });
}
