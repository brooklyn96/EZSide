import 'package:flutter/material.dart';

import '../../viewmodels/update_view_model.dart';
import '../theme/app_theme.dart';
import 'buttons.dart';
import 'progress.dart';

/// Compact update strip under the title bar (BitBroom InfoBar shape).
///
/// One horizontal row: status on the left, See Changes / Download|Install /
/// Later on the right — uses the width, not a stack of title + body + buttons.
/// Listens to [model] so progress and action swaps repaint without a parent
/// rebuild.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.model});

  final UpdateViewModel model;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: model,
        builder: (BuildContext context, Widget? _) => _BannerBody(model: model),
      );
}

class _BannerBody extends StatelessWidget {
  const _BannerBody({required this.model});

  final UpdateViewModel model;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final String? version = model.latestVersion;
    final String line = model.isDownloading
        ? 'Downloading${version == null ? '' : ' $version'}\u2026'
        : model.canInstall
            ? 'Update ready \u2014 version $version is downloaded and verified.'
            : 'Update available \u2014 version $version is available.';

    return Container(
      padding: const EdgeInsets.fromLTRB(Space.s3, Space.s2, Space.s2, Space.s2),
      decoration: BoxDecoration(
        color: p.accentSubtle,
        borderRadius: Radii.rMedium,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.info_outline_rounded, size: Sizes.icon, color: p.accent),
              const SizedBox(width: Space.s3),
              Expanded(
                child: Text(
                  line,
                  style: context.t.small.copyWith(color: p.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: Space.s3),
              _Actions(model: model, version: version),
            ],
          ),
          if (model.isDownloading) ...<Widget>[
            const SizedBox(height: Space.s2),
            AppProgressBar(value: model.progress * 100, height: 3),
          ],
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.model, required this.version});

  final UpdateViewModel model;
  final String? version;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppButton(
            label: 'See Changes',
            compact: true,
            onPressed: model.seeChanges,
          ),
          const SizedBox(width: Space.s2),
          if (model.canInstall)
            AppButton(
              label: 'Install now',
              icon: Icons.download_rounded,
              tone: ButtonTone.primary,
              compact: true,
              onPressed: model.install,
            )
          else if (!model.hasLaunchedInstaller)
            AppButton(
              label: version == null ? 'Download' : 'Download $version',
              icon: Icons.download_rounded,
              tone: ButtonTone.primary,
              compact: true,
              busy: model.isDownloading,
              onPressed: model.canDownload ? model.download : null,
            ),
          const SizedBox(width: Space.s2),
          AppButton(
            label: 'Later',
            compact: true,
            onPressed: model.isDownloading ? null : model.dismissBanner,
          ),
        ],
      );
}
