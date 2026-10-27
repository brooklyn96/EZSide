/// Ties a spawned child process to this one so the OS tears it down with us.
///
/// The Python engine is a long-lived child. Without this, force-killing the app
/// (or crashing) would strand `python.exe` and its own children.
abstract class ChildProcessReaper {
  /// Adopt a freshly started child. Best-effort: never throws.
  void adopt(int pid);
}

/// Used where the platform offers no reaping primitive; a stranded child is
/// possible after an abnormal exit.
class NoopChildProcessReaper implements ChildProcessReaper {
  const NoopChildProcessReaper();

  @override
  void adopt(int pid) {}
}
