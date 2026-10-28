// Ported from iPASide.App/Platform/IBackgroundRefreshScheduler.cs,
// iPASide.Platform.Windows/WindowsBackgroundRefreshScheduler.cs and the
// UnsupportedBackgroundRefreshScheduler in iPASide.App/Platform/Fallbacks.cs.

import 'dart:io';

import 'package:flutter/foundation.dart';

/// Name of the OS scheduled task, matched exactly by create, delete and query.
const String autoRefreshTaskName = 'EZSide Auto-Refresh';

/// Raised when the OS scheduler rejects a create or delete.
///
/// [message] is presentable as-is, so Settings can bind it directly.
class BackgroundRefreshException implements Exception {
  /// Creates a failure carrying a presentable [message].
  BackgroundRefreshException(this.message);

  /// The failure text, e.g. `schtasks failed: Access is denied.`.
  final String message;

  @override
  String toString() => 'BackgroundRefreshException: $message';
}

/// OS-level hourly background refresh: schedules a headless
/// `EZSide --auto-refresh` run that re-signs apps whose free-account signature
/// is about to expire, without the UI running.
abstract class BackgroundRefreshScheduler {
  /// Whether this OS has a scheduler integration.
  ///
  /// When false, Settings hides or disables the auto-refresh toggle instead of
  /// calling [setEnabled].
  bool get isSupported;

  /// True when the background refresh schedule currently exists.
  Future<bool> isEnabled();

  /// Creates ([enabled] true) or removes (false) the background refresh
  /// schedule.
  Future<void> setEnabled(bool enabled);
}

/// The scheduler for this OS: `schtasks` on Windows, the unsupported fallback
/// elsewhere.
BackgroundRefreshScheduler createBackgroundRefreshScheduler() =>
    Platform.isWindows
    ? const WindowsBackgroundRefreshScheduler()
    : const UnsupportedBackgroundRefreshScheduler();

/// Manages the "EZSide Auto-Refresh" Windows Scheduled Task - every hour, all
/// day, running `"{exe}" --auto-refresh` - through `schtasks.exe`.
class WindowsBackgroundRefreshScheduler implements BackgroundRefreshScheduler {
  /// Creates the scheduler; it holds no state between calls.
  const WindowsBackgroundRefreshScheduler();

  @override
  bool get isSupported => true;

  @override
  Future<bool> isEnabled() async {
    final ProcessResult result = await Process.run('schtasks', <String>[
      '/Query',
      '/TN',
      autoRefreshTaskName,
    ]);
    return result.exitCode == 0;
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    if (!enabled) {
      // Turning off something already off is a success, not a failure. schtasks
      // /Delete reports "cannot find the file specified" for a task that is not
      // there, which surfaced in Settings as an error for having done nothing —
      // and would greet anyone whose task had been removed from Task Scheduler.
      if (await isEnabled()) {
        await _run(_deleteArguments());
      }
      return;
    }

    // Registered from XML rather than with `/SC HOURLY`, because the
    // command-line form cannot reach the three settings that decide whether this
    // ever actually runs, and its defaults are wrong for us on all three.
    final File definition = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'ipaside-autorefresh-$pid.xml',
    );
    try {
      // schtasks rejects the definition outright unless it is UTF-16.
      await definition.writeAsBytes(_utf16Le(_taskXml()));
      await _run(<String>[
        '/Create',
        '/F',
        '/TN',
        autoRefreshTaskName,
        '/XML',
        definition.path,
      ]);
    } finally {
      try {
        if (definition.existsSync()) definition.deleteSync();
      } on FileSystemException {
        // A leftover temp file is not worth failing an otherwise good register.
      }
    }
  }

  Future<void> _run(List<String> arguments) async {
    final ProcessResult result = await Process.run('schtasks', arguments);
    if (result.exitCode != 0) {
      throw BackgroundRefreshException(
        'schtasks failed: ${_trimmedStderr(result)}',
      );
    }
  }

  /// The task definition: every hour, running the app headlessly.
  ///
  /// Three settings are the whole reason this is XML rather than a command line,
  /// and each one is a way the feature silently does nothing:
  ///
  /// * `StartWhenAvailable` — without it a machine that is off or asleep on the
  ///   hour simply skips the run, and nothing retries it. Signatures last 7 days,
  ///   so a laptop that stays closed would let apps expire while the toggle sat
  ///   there saying it was on.
  /// * `DisallowStartIfOnBatteries` — Windows defaults this to true, so on an
  ///   unplugged laptop the task would not start at all.
  /// * `StopIfGoingOnBatteries` — also true by default, so pulling the charger
  ///   mid-run would kill a refresh, potentially between signing and installing.
  ///
  /// `IgnoreNew` keeps a slow run from being overlapped by the next hour's.
  ///
  /// The hourly cadence is a daily trigger from 00:00 that repeats every hour for
  /// a day without stopping a run in progress at the end of it.
  @visibleForTesting
  static String taskDefinitionXml() => _taskXml();

  /// The task definition.
  ///
  /// `ExecutionTimeLimit` is PT1H: Windows ends the run after one hour, and that
  /// includes the time the failure notice stays open. A user who is away for more
  /// than an hour finds no box; the task then shows a termination code instead of
  /// exit 1, and the refresh log still holds the failure.
  static String _taskXml() {
    final String exe = _escape(Platform.resolvedExecutable);
    return '''
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Re-signs the apps EZSide has sideloaded, before their 7-day free-account signature expires.</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <Repetition>
        <Interval>PT1H</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowHardTerminate>true</AllowHardTerminate>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$exe</Command>
      <Arguments>--auto-refresh</Arguments>
    </Exec>
  </Actions>
</Task>
''';
  }

  /// UTF-16 little-endian with a byte-order mark, which is what schtasks expects.
  static List<int> _utf16Le(String xml) {
    final List<int> bytes = <int>[0xFF, 0xFE];
    for (final int unit in xml.codeUnits) {
      bytes.add(unit & 0xFF);
      bytes.add(unit >> 8);
    }
    return bytes;
  }

  /// Escapes the install path for XML; `&` in a folder name would otherwise make
  /// the definition malformed and the register fail for a reason nobody could
  /// guess from the message.
  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static List<String> _deleteArguments() => <String>[
    '/Delete',
    '/F',
    '/TN',
    autoRefreshTaskName,
  ];

  static String _trimmedStderr(ProcessResult result) {
    final Object? error = result.stderr;
    return error is String ? error.trim() : '';
  }
}

/// Fallback for OSes without a scheduler integration; consumers must check
/// [isSupported] and hide or disable the feature.
class UnsupportedBackgroundRefreshScheduler
    implements BackgroundRefreshScheduler {
  /// Creates the fallback scheduler.
  const UnsupportedBackgroundRefreshScheduler();

  @override
  bool get isSupported => false;

  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<void> setEnabled(bool enabled) async => throw UnsupportedError(
    'Background auto-refresh scheduling is not supported on this OS.',
  );
}

/// Brings a task registered by an older build up to date.
///
/// An install that turned auto-refresh on while it was a daily-noon task keeps
/// that task until it is registered again, so every app start re-registers it
/// (`/F`, same name) when it exists. When auto-refresh is off nothing is
/// created. A failure here is swallowed: the old task still runs, and a start-up
/// check must never stop the app from opening.
Future<void> refreshAutoRefreshTask(BackgroundRefreshScheduler scheduler) async {
  try {
    if (scheduler.isSupported && await scheduler.isEnabled()) {
      await scheduler.setEnabled(true);
    }
  } catch (_) {
    // Left as it is; Settings shows the real state and any error on toggle.
  }
}
