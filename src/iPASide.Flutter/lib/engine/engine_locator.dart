// Ported from iPASide.App/Engine/EngineLocator.cs.

import 'dart:io';

/// A fully-resolved way to launch the engine's `serve` process.
///
/// [fileName] is the executable, [prefixArgs] precede the `serve` argument, and
/// [workingDirectory] is the interpreter's need in the repo-checkout case.
class EngineLaunchSpec {
  /// Creates a launch spec.
  const EngineLaunchSpec({
    required this.fileName,
    required this.prefixArgs,
    this.workingDirectory,
  });

  /// The executable to start.
  final String fileName;

  /// Arguments inserted before `serve` (`['-m', 'ipaside_engine']`, or empty
  /// for a frozen engine executable).
  final List<String> prefixArgs;

  /// Working directory for the child, or null to inherit ours.
  ///
  /// This is how a repo checkout finds the package: `-m` puts the working
  /// directory on `sys.path`. `PYTHONPATH` is deliberately unused, because the
  /// interpreter is launched with `-E` and would ignore it.
  final String? workingDirectory;

  @override
  String toString() => 'EngineLaunchSpec(fileName: $fileName, '
      'prefixArgs: $prefixArgs, workingDirectory: $workingDirectory)';
}

/// Resolves how to start the Python engine, probing in this order:
///
/// 1. The `IPASIDE_ENGINE_EXE` override, run as `<exe> serve` (no `-m`).
/// 2. A portable interpreter bundled next to the app
///    (`engine/python/python.exe` on Windows, `engine/python/bin/python3`
///    elsewhere).
/// 3. A repo checkout: the `.venv` interpreter (or bare `python`) with the
///    working directory pointed at `src/iPASide.Engine`.
/// 4. Bare `python` on `PATH`.
class EngineLocator {
  /// Creates a locator.
  ///
  /// The parameters exist so tests can probe a scratch directory; production
  /// code constructs this with no arguments and gets the real environment, the
  /// directory holding the app executable, and the real OS.
  EngineLocator({
    Map<String, String>? environment,
    String? baseDirectory,
    bool? isWindows,
  })  : _environment = environment ?? Platform.environment,
        _baseDirectory =
            baseDirectory ?? File(Platform.resolvedExecutable).parent.path,
        _isWindows = isWindows ?? Platform.isWindows;

  /// How to run the engine as a module, isolated from the user's environment.
  ///
  /// `-E` is the load-bearing flag: without it a `PYTHONPATH` set in the user's
  /// environment is inherited by the child, and a developer who happens to have
  /// one pointing at a checkout of this project gets *that* engine instead of the
  /// one iPASide shipped -- observed reporting the wrong version, and able to fail
  /// far more confusingly than that. `PYTHONHOME` would be worse still.
  ///
  /// `-E` also discards `PYTHONUTF8` and `PYTHONUNBUFFERED`, so the two settings
  /// the engine genuinely needs are stated as flags instead: `-X utf8` (so
  /// non-ASCII app and device names survive the Windows code page) and `-u` (so
  /// progress frames arrive as they happen rather than when a buffer fills).
  static const List<String> _moduleArgs = <String>[
    '-E',
    '-u',
    '-X',
    'utf8',
    '-m',
    'ipaside_engine',
  ];

  final Map<String, String> _environment;
  final String _baseDirectory;
  final bool _isWindows;

  /// Resolves the launch spec against the current environment and OS.
  EngineLaunchSpec resolve() {
    final String? overrideExe = _environment['IPASIDE_ENGINE_EXE'];
    if (overrideExe != null &&
        overrideExe.isNotEmpty &&
        File(overrideExe).existsSync()) {
      // A frozen engine build: it *is* the entry point, so no `-m` prefix.
      return EngineLaunchSpec(
        fileName: overrideExe,
        prefixArgs: const <String>[],
      );
    }

    final String bundledPython = _isWindows
        ? _join(<String>[_baseDirectory, 'engine', 'python', 'python.exe'])
        : _join(<String>[_baseDirectory, 'engine', 'python', 'bin', 'python3']);
    if (File(bundledPython).existsSync()) {
      // Portable interpreter shipped by the installer: ipaside_engine and its
      // dependencies live in that interpreter's site-packages.
      return EngineLaunchSpec(
        fileName: bundledPython,
        prefixArgs: _moduleArgs,
      );
    }

    final String? repo = findRepoRoot(_baseDirectory);
    if (repo != null) {
      final String venvPython = _isWindows
          ? _join(<String>[repo, '.venv', 'Scripts', 'python.exe'])
          : _join(<String>[repo, '.venv', 'bin', 'python3']);
      final String fileName =
          File(venvPython).existsSync() ? venvPython : 'python';
      // -m puts the working directory on sys.path, which is how the package is
      // found -- PYTHONPATH is deliberately not used, since -E ignores it.
      final String engineDir = _join(<String>[repo, 'src', 'iPASide.Engine']);
      return EngineLaunchSpec(
        fileName: fileName,
        prefixArgs: _moduleArgs,
        workingDirectory: engineDir,
      );
    }

    return const EngineLaunchSpec(
      fileName: 'python',
      prefixArgs: _moduleArgs,
    );
  }

  /// Walks up from [start] until it finds the repo root - the directory holding
  /// `src/iPASide.Engine/ipaside_engine` - or null when there is none.
  String? findRepoRoot(String start) {
    Directory dir = Directory(start).absolute;
    while (true) {
      final String marker =
          _join(<String>[dir.path, 'src', 'iPASide.Engine', 'ipaside_engine']);
      if (Directory(marker).existsSync()) {
        return dir.path;
      }
      final Directory parent = dir.parent;
      if (parent.path == dir.path) {
        return null;
      }
      dir = parent;
    }
  }

  // Follows the injected OS rather than Platform.pathSeparator so a test can
  // resolve macOS layouts on a Windows host.
  String _join(List<String> parts) => parts.join(_isWindows ? r'\' : '/');
}
