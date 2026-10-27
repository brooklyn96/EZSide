import 'dart:io';

/// Hands a verified installer to the user's session.
///
/// Abstracted for the same reason `FilePickerService` is: a view model that runs
/// third-party installers cannot be exercised without a seam, and "did it launch,
/// and only after verification?" is exactly the thing worth testing.
abstract class InstallerLauncher {
  /// Starts the installer at [path], detached, and reports whether it began.
  ///
  /// False for a path that is not there or that Windows refused to start; the
  /// caller owns saying so.
  Future<bool> launch(String path);
}

/// Process-backed implementation.
///
/// Detached on purpose. Apple's installer elevates itself, runs for minutes, and
/// reboots nothing — iPASide has no business owning its lifetime, and holding the
/// child would tie the installer's fate to an app the user may well close while it
/// works. This mirrors how `UpdateService.installStaged` hands off iPASide's own
/// installer.
class ProcessInstallerLauncher implements InstallerLauncher {
  const ProcessInstallerLauncher();

  @override
  Future<bool> launch(String path) async {
    if (path.isEmpty || !File(path).existsSync()) return false;
    try {
      await Process.start(
        path,
        const <String>[],
        mode: ProcessStartMode.detached,
        runInShell: true,
      );
      return true;
    } on Object {
      // A refused elevation or a blocked executable; the caller reports it.
      return false;
    }
  }
}
