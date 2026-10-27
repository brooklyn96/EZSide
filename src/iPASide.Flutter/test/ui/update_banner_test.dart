import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/services/update_planner.dart';
import 'package:ipaside/services/update_service.dart';
import 'package:ipaside/ui/theme/app_theme.dart';
import 'package:ipaside/ui/widgets/update_banner.dart';
import 'package:ipaside/viewmodels/update_view_model.dart';

class _StubUpdateService extends UpdateService {
  _StubUpdateService() : super(currentVersion: '1.0.0', log: (_) {});

  bool installSucceeds = true;
  int downloads = 0;
  int installs = 0;
  int releaseNotesOpens = 0;

  static const PendingUpdate _staged = PendingUpdate(
    version: '1.2.0',
    setupPath: r'C:\nowhere\iPASide-Setup-1.2.0-x64.exe',
    sizeBytes: 96 << 20,
  );

  @override
  Future<UpdateCheck> peekLatest() async => const UpdateCheck(
        UpdateOutcome.updateAvailable,
        latestVersion: '1.2.0',
        releasePageUrl:
            'https://github.com/pwnapplehat/iPASide/releases/tag/v1.2.0',
      );

  @override
  Future<UpdateCheck> downloadUpdate({
    void Function(double progress)? onProgress,
  }) async {
    downloads++;
    onProgress?.call(1);
    return const UpdateCheck(
      UpdateOutcome.readyToInstall,
      latestVersion: '1.2.0',
      pending: _staged,
    );
  }

  @override
  Future<bool> installStaged(PendingUpdate update) async {
    installs++;
    return installSucceeds;
  }

  @override
  Future<bool> openReleaseNotes([String? url]) async {
    releaseNotesOpens++;
    return true;
  }
}

/// Pumps the banner and disposes the view model before the binding checks for
/// leftover timers (tearDown runs too late for that invariant).
Future<UpdateViewModel> _pumpBanner(
  WidgetTester tester,
  _StubUpdateService service,
) async {
  final UpdateViewModel model = UpdateViewModel(
    service: service,
    checkInterval: const Duration(days: 365),
  );
  await model.check();

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(body: UpdateBanner(model: model)),
    ),
  );
  await tester.pump();
  return model;
}

Future<void> _finish(UpdateViewModel model) async {
  model.dispose();
}

void main() {
  testWidgets('available update offers See Changes, Download, and Later',
      (tester) async {
    final UpdateViewModel model = await _pumpBanner(tester, _StubUpdateService());

    expect(find.textContaining('Update available'), findsOneWidget);
    expect(find.textContaining('version 1.2.0 is available'), findsOneWidget);
    expect(find.text('See Changes'), findsOneWidget);
    expect(find.text('Download 1.2.0'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
    expect(find.text('Install now'), findsNothing);

    await _finish(model);
  });

  testWidgets('See Changes reaches the update service', (tester) async {
    final _StubUpdateService service = _StubUpdateService();
    final UpdateViewModel model = await _pumpBanner(tester, service);

    await tester.tap(find.text('See Changes'));
    await tester.pump();

    expect(service.releaseNotesOpens, 1);
    await _finish(model);
  });

  testWidgets('Later hides the banner for that version', (tester) async {
    final UpdateViewModel model =
        await _pumpBanner(tester, _StubUpdateService());

    await tester.tap(find.text('Later'));
    await tester.pump();

    expect(model.showBanner, isFalse);
    await _finish(model);
  });

  testWidgets('Install now hands off to the update service', (tester) async {
    final _StubUpdateService service = _StubUpdateService();
    final UpdateViewModel model = await _pumpBanner(tester, service);

    await model.download();
    await tester.pump();

    await tester.tap(find.text('Install now'));
    await tester.pump();

    expect(service.installs, 1);
    expect(model.hasLaunchedInstaller, isTrue);
    await _finish(model);
  });

  testWidgets('stays a single horizontal strip', (tester) async {
    final UpdateViewModel model = await _pumpBanner(tester, _StubUpdateService());

    final Size size = tester.getSize(find.byType(UpdateBanner));
    expect(size.height, lessThan(56), reason: 'must not stack title/body/buttons');
    expect(size.width, greaterThan(400));

    await _finish(model);
  });
}
