import 'package:flutter/material.dart';

import '../../viewmodels/apple_support_view_model.dart';
import '../theme/app_theme.dart';
import 'buttons.dart';
import 'progress.dart';
import 'surfaces.dart';

/// The one banner that says Apple's device support is missing, and offers the fix.
///
/// Shared rather than written per screen, the way `DeviceTargetBar` is: this shows
/// up on Home, on Sideload and in Diagnostics, and a problem that reads three
/// different ways is a problem the user has to solve three times. Build it only
/// when [AppleSupportViewModel.hasNotice] is true — the surrounding screen owns
/// the spacing around it, so an empty box here would leave a hole.
///
/// A missing service is [AlertKind.danger] and a stopped one is
/// [AlertKind.warning]: both block every install, but one is a 200 MB download and
/// the other is a click, and the colour is the fastest way to say which.
class AppleSupportBanner extends StatelessWidget {
  const AppleSupportBanner({super.key, required this.model});

  final AppleSupportViewModel model;

  @override
  Widget build(BuildContext context) => Alert(
        kind: model.isMissing ? AlertKind.danger : AlertKind.warning,
        title: model.title,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(model.message, style: context.t.small),
            if (model.isDownloading) _DownloadProgress(model: model),
            if (model.problem case final String problem) ...<Widget>[
              const SizedBox(height: Space.s2),
              Text(
                problem,
                style: context.t.small.copyWith(color: context.palette.danger),
              ),
            ],
            const SizedBox(height: Space.s4),
            _Actions(model: model),
          ],
        ),
      );
}

/// The download's bar, its live sub-step and its percentage.
///
/// Indeterminate until the first byte, because "0%" for the seconds spent opening
/// a connection reads as stuck rather than as starting.
class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({required this.model});

  final AppleSupportViewModel model;

  @override
  Widget build(BuildContext context) {
    final bool started = model.percent > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: Space.s3),
        AppProgressBar(value: model.percent, indeterminate: !started),
        const SizedBox(height: Space.s2),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                model.step ?? '',
                style: context.t.smallMuted,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (started) ...<Widget>[
              const SizedBox(width: Space.s3),
              Text(
                '${model.percent.round()}%',
                style: context.t.semi(FontSizes.small),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// The remedy, plus the re-check that follows it.
///
/// The re-check is always offered because the thing being reported lives outside
/// the app: someone can install iTunes, or start the service from the Services
/// console, without iPASide ever hearing about it.
class _Actions extends StatelessWidget {
  const _Actions({required this.model});

  final AppleSupportViewModel model;

  @override
  Widget build(BuildContext context) {
    final bool waitingOnInstaller = model.installerRunning;
    return Row(
      children: <Widget>[
        if (!waitingOnInstaller) ...<Widget>[
          if (model.isMissing)
            AppButton(
              label: 'Install iTunes',
              icon: Icons.download_rounded,
              tone: ButtonTone.primary,
              compact: true,
              busy: model.isDownloading,
              onPressed: model.canDownload ? model.installItunes : null,
            )
          else
            AppButton(
              label: 'Start the service',
              icon: Icons.play_arrow_rounded,
              tone: ButtonTone.primary,
              compact: true,
              busy: model.isStartingService,
              onPressed: model.canStartService ? model.startService : null,
              tooltip: 'Windows will ask for administrator rights',
            ),
          const SizedBox(width: Space.s2),
        ],
        AppButton(
          label: 'Check again',
          compact: true,
          tone: waitingOnInstaller ? ButtonTone.primary : ButtonTone.soft,
          busy: model.isChecking,
          onPressed: model.canRecheck ? model.refresh : null,
        ),
      ],
    );
  }
}
