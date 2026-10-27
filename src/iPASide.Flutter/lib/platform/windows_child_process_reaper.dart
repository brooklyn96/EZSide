// Ported from iPASide.Platform.Windows/WindowsChildProcessReaper.cs.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'child_process_reaper.dart';

/// The reaper for this OS: the Win32 Job Object on Windows, the documented
/// no-op fallback everywhere else.
///
/// Mirrors `AddPlatformServices`: every construction site takes the interface,
/// so this function is the only place that names the Windows implementation.
ChildProcessReaper createChildProcessReaper() => Platform.isWindows
    ? WindowsChildProcessReaper()
    : const NoopChildProcessReaper();

/// A Windows Job Object that kills every adopted child when this process dies -
/// including on a crash or force-kill - so the resident Python engine (and
/// transitively zsign) can never be orphaned.
///
/// The job is created lazily on first [adopt] and its handle is then held for
/// the life of the process: closing it is what triggers the kill, so that is
/// left to the OS at exit. Every step is best-effort and never throws, because
/// graceful shutdown already covers the normal case.
class WindowsChildProcessReaper implements ChildProcessReaper {
  /// Creates a reaper; no Win32 object exists until the first [adopt].
  WindowsChildProcessReaper();

  /// `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, absent from package:win32.
  static const int _jobObjectLimitKillOnJobClose = 0x2000;

  HANDLE? _job;
  bool _jobResolved = false;

  @override
  void adopt(int pid) {
    // The Win32 bindings resolve kernel32.dll lazily, so merely importing
    // package:win32 is safe off-Windows - calling into it is not.
    if (!Platform.isWindows) return;

    try {
      final HANDLE? job = _ensureJob();
      if (job == null) return;

      // The C# reaper had a Process and could pass Process.Handle straight in;
      // from Dart only the pid is available, so open a handle with the two
      // rights AssignProcessToJobObject needs.
      final HANDLE process = OpenProcess(
        PROCESS_SET_QUOTA | PROCESS_TERMINATE,
        false,
        pid,
      ).value;
      if (!process.isValid) return;

      try {
        // The job keeps its own reference to the process; this handle is only
        // needed for the assignment itself.
        AssignProcessToJobObject(job, process);
      } finally {
        CloseHandle(process);
      }
    } catch (_) {
      // Best effort; graceful shutdown still handles the normal case.
    }
  }

  HANDLE? _ensureJob() {
    if (_jobResolved) return _job;
    _jobResolved = true;
    _job = _createKillOnCloseJob();
    return _job;
  }

  static HANDLE? _createKillOnCloseJob() {
    final HANDLE job = CreateJobObject(nullptr, null).value;
    if (!job.isValid) return null;

    final Pointer<_JobObjectExtendedLimitInformation> info =
        calloc<_JobObjectExtendedLimitInformation>();
    try {
      info.ref.basicLimitInformation.limitFlags = _jobObjectLimitKillOnJobClose;
      // A failure here leaves a job without the kill-on-close limit, which makes
      // adoption inert rather than harmful - same trade-off as the C# original.
      SetInformationJobObject(
        job,
        JobObjectExtendedLimitInformation,
        info,
        sizeOf<_JobObjectExtendedLimitInformation>(),
      );
    } finally {
      calloc.free(info);
    }

    return job;
  }
}

/// `JOBOBJECT_BASIC_LIMIT_INFORMATION` (winnt.h).
final class _JobObjectBasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;

  @Int64()
  external int perJobUserTimeLimit;

  @Uint32()
  external int limitFlags;

  @Size()
  external int minimumWorkingSetSize;

  @Size()
  external int maximumWorkingSetSize;

  @Uint32()
  external int activeProcessLimit;

  @Size()
  external int affinity;

  @Uint32()
  external int priorityClass;

  @Uint32()
  external int schedulingClass;
}

/// `IO_COUNTERS` (winnt.h).
final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;

  @Uint64()
  external int writeOperationCount;

  @Uint64()
  external int otherOperationCount;

  @Uint64()
  external int readTransferCount;

  @Uint64()
  external int writeTransferCount;

  @Uint64()
  external int otherTransferCount;
}

/// `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` (winnt.h), the payload for info class
/// [JobObjectExtendedLimitInformation]. package:win32 declares the info class
/// but not this struct.
final class _JobObjectExtendedLimitInformation extends Struct {
  external _JobObjectBasicLimitInformation basicLimitInformation;

  external _IoCounters ioInfo;

  @Size()
  external int processMemoryLimit;

  @Size()
  external int jobMemoryLimit;

  @Size()
  external int peakProcessMemoryUsed;

  @Size()
  external int peakJobMemoryUsed;
}
