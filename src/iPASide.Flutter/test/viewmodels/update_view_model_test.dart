import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/services/update_planner.dart';
import 'package:ipaside/services/update_service.dart';
import 'package:ipaside/viewmodels/update_view_model.dart';

/// An [UpdateService] that answers from memory and counts what it was asked,
/// so no test touches the network, the filesystem or a real installer.
class _StubUpdateService extends UpdateService {
  _StubUpdateService({this.outcome = UpdateOutcome.upToDate})
      : super(currentVersion: '1.0.0', log: _swallow);

  static void _swallow(String message) {}

  static const PendingUpdate _staged = PendingUpdate(
    version: '1.2.0',
    setupPath: r'C:\nowhere\iPASide-Setup-1.2.0-x64.exe',
    sizeBytes: 96 << 20,
  );

  /// What the next [peekLatest] reports.
  UpdateOutcome outcome;

  /// What [installStaged] reports, without launching anything.
  bool installSucceeds = true;

  int peeks = 0;
  int downloads = 0;
  int installs = 0;
  int releaseNotesOpens = 0;
  String? lastReleaseNotesUrl;

  /// Set to hold a download open for as long as a test needs it in flight.
  Completer<UpdateCheck>? blockDownload;

  /// Set to hold an install open so overlapping Install clicks can be asserted.
  Completer<bool>? blockInstall;

  @override
  Future<UpdateCheck> peekLatest() async {
    peeks++;
    final bool failed = outcome == UpdateOutcome.error;
    return UpdateCheck(
      outcome,
      latestVersion: failed ? null : '1.2.0',
      releasePageUrl: failed
          ? null
          : 'https://github.com/pwnapplehat/iPASide/releases/tag/v1.2.0',
      detail: failed ? 'no network' : null,
    );
  }

  @override
  Future<UpdateCheck> downloadUpdate({
    void Function(double progress)? onProgress,
  }) {
    downloads++;
    onProgress?.call(0.5);
    return blockDownload?.future ??
        Future<UpdateCheck>.value(
          const UpdateCheck(
            UpdateOutcome.readyToInstall,
            latestVersion: '1.2.0',
            releasePageUrl:
                'https://github.com/pwnapplehat/iPASide/releases/tag/v1.2.0',
            pending: _staged,
          ),
        );
  }

  @override
  Future<bool> installStaged(PendingUpdate update) async {
    installs++;
    return blockInstall?.future ?? Future<bool>.value(installSucceeds);
  }

  @override
  Future<bool> openReleaseNotes([String? url]) async {
    releaseNotesOpens++;
    lastReleaseNotesUrl = url;
    return true;
  }
}

/// A view model wired to [service], disposed when the running test ends.
UpdateViewModel _model(_StubUpdateService service, {Duration? interval, Future<void> Function()? exitForUpdate}) {
  final UpdateViewModel model = UpdateViewModel(
    service: service,
    checkInterval: interval ?? UpdateViewModel.checkEvery,
    exitForUpdate: exitForUpdate,
  );
  addTearDown(model.dispose);
  return model;
}

/// The re-check interval the timing tests use in place of six hours.
///
/// Only ever elapsed in virtual time, so its size costs nothing.
const Duration _tick = Duration(milliseconds: 20);

/// How many intervals the timing tests run for, and so how many checks a
/// still-running view model owes by the time they assert.
const int _ticks = 8;

/// Builds a view model on [_tick] inside a virtual-time zone.
///
/// Constructed here rather than through `_model` because the periodic timer must
/// belong to the same zone that elapses it, and be cancelled before that zone
/// ends rather than by a tear-down running outside it.
UpdateViewModel _ticking(_StubUpdateService service) =>
    UpdateViewModel(service: service, checkInterval: _tick);

void main() {
  group('Last-checked formatting', () {
    test('a check earlier today reads as a zero-padded 24-hour time', () {
      expect(
        UpdateViewModel.describeLastChecked(
          DateTime(2026, 7, 25, 9, 5),
          DateTime(2026, 7, 25, 11, 48),
        ),
        'Last checked 09:05',
      );
    });

    test('midnight and the last minute of the day both render', () {
      expect(
        UpdateViewModel.describeLastChecked(
          DateTime(2026, 7, 25),
          DateTime(2026, 7, 25, 6),
        ),
        'Last checked 00:00',
      );
      expect(
        UpdateViewModel.describeLastChecked(
          DateTime(2026, 7, 25, 23, 59),
          DateTime(2026, 7, 25, 23, 59, 30),
        ),
        'Last checked 23:59',
      );
    });

    test('a check on an earlier day reads as a day and short month', () {
      expect(
        UpdateViewModel.describeLastChecked(
          DateTime(2026, 7, 25, 11, 48),
          DateTime(2026, 7, 26, 9),
        ),
        'Last checked 25 Jul',
      );
    });

    test('the same clock time a year earlier is still a date', () {
      // Comparing only hours and minutes would make this read as "today".
      expect(
        UpdateViewModel.describeLastChecked(
          DateTime(2025, 7, 25, 11, 48),
          DateTime(2026, 7, 25, 11, 48),
        ),
        'Last checked 25 Jul',
      );
    });

    test('the first and last months are named, not off by one', () {
      expect(
        UpdateViewModel.describeLastChecked(
          DateTime(2026, 1, 1, 8),
          DateTime(2026, 6),
        ),
        'Last checked 1 Jan',
      );
      expect(
        UpdateViewModel.describeLastChecked(
          DateTime(2025, 12, 31, 8),
          DateTime(2026, 6),
        ),
        'Last checked 31 Dec',
      );
    });
  });

  group('Last-checked tracking', () {
    test('nothing is claimed before the first check', () {
      final UpdateViewModel model = _model(_StubUpdateService());

      expect(model.lastCheckedAt, isNull);
      expect(model.lastCheckedLabel, isNull);
    });

    test('a successful check is stamped and surfaced', () async {
      final UpdateViewModel model = _model(_StubUpdateService());

      await model.check();

      expect(model.lastCheckedAt, isNotNull);
      expect(model.lastCheckedLabel, startsWith('Last checked '));
    });

    test('a failed check leaves the stamp alone', () async {
      final UpdateViewModel model = _model(
        _StubUpdateService(outcome: UpdateOutcome.error),
      );

      await model.check();

      expect(model.isProblem, isTrue);
      expect(model.lastCheckedAt, isNull, reason: 'a failure learned nothing');
      expect(model.lastCheckedLabel, isNull);
    });

    test('a failure after a success does not refresh the stamp', () async {
      final _StubUpdateService service = _StubUpdateService();
      final UpdateViewModel model = _model(service);

      await model.check();
      final DateTime? afterSuccess = model.lastCheckedAt;

      service.outcome = UpdateOutcome.error;
      await model.check();

      expect(model.lastCheckedAt, afterSuccess);
    });

    test('a download that read a version counts as a check', () async {
      final UpdateViewModel model = _model(_StubUpdateService());

      await model.download();

      expect(model.lastCheckedAt, isNotNull);
      expect(model.progress, 0.5);
      expect(model.canInstall, isTrue);
    });
  });

  group('Periodic re-checking', () {
    test('the shipped interval is six hours', () {
      expect(UpdateViewModel.checkEvery, const Duration(hours: 6));
    });

    test('the check repeats on its own while the app runs', () {
      fakeAsync((FakeAsync time) {
        final _StubUpdateService service = _StubUpdateService();
        final UpdateViewModel model = _ticking(service);

        time.elapse(_tick * _ticks);

        expect(service.peeks, _ticks, reason: 'one check per interval');
        model.dispose();
      });
    });

    test('an available update is offered, never taken', () {
      fakeAsync((FakeAsync time) {
        final _StubUpdateService service = _StubUpdateService(
          outcome: UpdateOutcome.updateAvailable,
        );
        final UpdateViewModel model = _ticking(service);

        time.elapse(_tick * _ticks);

        expect(service.peeks, _ticks);
        expect(service.downloads, 0, reason: 'noticing is not taking');
        expect(model.canDownload, isTrue, reason: 'offered, and settled');
        model.dispose();
      });
    });

    test('disposing stops the timer', () {
      fakeAsync((FakeAsync time) {
        final _StubUpdateService service = _StubUpdateService();
        final UpdateViewModel model = _ticking(service);

        time.elapse(_tick * _ticks);
        expect(service.peeks, _ticks, reason: 'was running');

        model.dispose();
        time.elapse(_tick * _ticks);

        expect(service.peeks, _ticks, reason: 'and stopped for good');
      });
    });

    test('a download in flight is never interrupted by a re-check', () {
      fakeAsync((FakeAsync time) {
        final _StubUpdateService service = _StubUpdateService(
          outcome: UpdateOutcome.updateAvailable,
        )..blockDownload = Completer<UpdateCheck>();
        final UpdateViewModel model = _ticking(service);

        unawaited(model.download());
        time.elapse(_tick * _ticks);

        expect(service.peeks, 0, reason: 'the download holds isBusy');
        expect(model.isDownloading, isTrue);

        service.blockDownload!.complete(
          const UpdateCheck(UpdateOutcome.readyToInstall, latestVersion: '1.2.0'),
        );
        time.flushMicrotasks();

        expect(model.isDownloading, isFalse);
        model.dispose();
      });
    });

    test('the asking stops once the installer has been handed off', () {
      fakeAsync((FakeAsync time) {
        final _StubUpdateService service = _StubUpdateService(
          outcome: UpdateOutcome.updateAvailable,
        );
        final UpdateViewModel model = _ticking(service);

        unawaited(model.download());
        time.flushMicrotasks();
        unawaited(model.install());
        time.flushMicrotasks();
        expect(model.hasLaunchedInstaller, isTrue);

        final int afterHandoff = service.peeks;
        time.elapse(_tick * _ticks);

        expect(service.peeks, afterHandoff, reason: 'nothing left to notice');
        expect(service.installs, 1);
        model.dispose();
      });
    });
  });

  group('Shell banner', () {
    test('an available update shows the banner', () async {
      final UpdateViewModel model = _model(
        _StubUpdateService(outcome: UpdateOutcome.updateAvailable),
      );

      await model.check();

      expect(model.showBanner, isTrue);
      expect(model.canDownload, isTrue);
    });

    test('Later hides the banner for that version', () async {
      final UpdateViewModel model = _model(
        _StubUpdateService(outcome: UpdateOutcome.updateAvailable),
      );

      await model.check();
      model.dismissBanner();

      expect(model.showBanner, isFalse);
      expect(model.canDownload, isTrue, reason: 'Settings still offers it');
    });

    test('a finished download brings the banner back for Install', () async {
      final UpdateViewModel model = _model(
        _StubUpdateService(outcome: UpdateOutcome.updateAvailable),
      );

      await model.check();
      model.dismissBanner();
      await model.download();

      expect(model.canInstall, isTrue);
      expect(model.showBanner, isTrue);
    });

    test('handing off the installer clears the banner', () async {
      final UpdateViewModel model = _model(
        _StubUpdateService(outcome: UpdateOutcome.updateAvailable),
      );

      await model.download();
      expect(model.showBanner, isTrue);

      await model.install();

      expect(model.hasLaunchedInstaller, isTrue);
      expect(model.showBanner, isFalse);
    });

    test('a successful install exits so Setup can replace binaries', () async {
      var exited = false;
      final UpdateViewModel model = _model(
        _StubUpdateService(outcome: UpdateOutcome.updateAvailable),
        exitForUpdate: () async {
          exited = true;
        },
      );

      await model.download();
      await model.install();

      expect(model.hasLaunchedInstaller, isTrue);
      expect(exited, isTrue);
    });

    test('a failed install does not exit the app', () async {
      var exited = false;
      final UpdateViewModel model = _model(
        _StubUpdateService(outcome: UpdateOutcome.updateAvailable)
          ..installSucceeds = false,
        exitForUpdate: () async {
          exited = true;
        },
      );

      await model.download();
      await model.install();

      expect(model.hasLaunchedInstaller, isFalse);
      expect(model.isProblem, isTrue);
      expect(model.canInstall, isTrue, reason: 'retry stays available');
      expect(exited, isFalse);
    });

    test('See Changes opens the release page from the last check', () async {
      final _StubUpdateService service = _StubUpdateService(
        outcome: UpdateOutcome.updateAvailable,
      );
      final UpdateViewModel model = _model(service);

      await model.check();
      await model.seeChanges();

      expect(service.releaseNotesOpens, 1);
      expect(
        service.lastReleaseNotesUrl,
        'https://github.com/pwnapplehat/iPASide/releases/tag/v1.2.0',
      );
    });

    test('a second Install while the first is handing off is ignored', () async {
      final _StubUpdateService service = _StubUpdateService(
        outcome: UpdateOutcome.updateAvailable,
      )..blockInstall = Completer<bool>();
      final UpdateViewModel model = _model(service);

      await model.download();

      final Future<void> first = model.install();
      await model.install();

      expect(service.installs, 1, reason: 'busy guard stopped the second click');

      service.blockInstall!.complete(true);
      await first;

      expect(service.installs, 1);
      expect(model.hasLaunchedInstaller, isTrue);
      expect(model.canInstall, isFalse);
    });

    test('exit failure after a successful launch leaves a clear problem', () async {
      final UpdateViewModel model = _model(
        _StubUpdateService(outcome: UpdateOutcome.updateAvailable),
        exitForUpdate: () async {
          throw StateError('window destroy failed');
        },
      );

      await model.download();
      await model.install();

      expect(model.hasLaunchedInstaller, isTrue);
      expect(model.isProblem, isTrue);
      expect(model.message, contains('could not close itself'));
    });
  });
}
