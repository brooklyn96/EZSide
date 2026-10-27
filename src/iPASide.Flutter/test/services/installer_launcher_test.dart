import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/services/installer_launcher.dart';

/// Only the refusals are exercised here: the success path starts a real third-party
/// installer, which is not something a test suite gets to do. What matters is that
/// a path the app was handed but cannot run comes back as false rather than as an
/// exception, because the view model turns that into a sentence naming the file.
void main() {
  group('ProcessInstallerLauncher', () {
    test('an empty path is refused', () async {
      expect(await const ProcessInstallerLauncher().launch(''), isFalse);
    });

    test('a path that is not there is refused', () async {
      final Directory directory = Directory.systemTemp.createTempSync('ipaside');
      addTearDown(() => directory.deleteSync(recursive: true));

      final String missing =
          '${directory.path}${Platform.pathSeparator}iTunes64Setup.exe';

      expect(await const ProcessInstallerLauncher().launch(missing), isFalse);
    });
  });
}
