import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../engine/engine.dart';
import '../../services/icon_cache.dart';
import '../../viewmodels/apps_view_model.dart';
import '../../viewmodels/device_selection.dart';
import '../shell/app_dialogs.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icon_image.dart';
import '../widgets/buttons.dart';
import '../widgets/motion.dart';
import '../widgets/progress.dart';
import '../widgets/smooth_scroll.dart';
import '../widgets/surfaces.dart';

/// Apps: the user apps installed on the iPhone, each with an Uninstall.
class AppsView extends StatelessWidget {
  const AppsView({super.key});

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (ctx) => AppsViewModel(
          engine: ctx.read<EngineApi>(),
          dialogs: ctx.read<DialogService>(),
          icons: ctx.read<IconCache>(),
          devices: ctx.read<DeviceSelection>(),
        ),
        child: const _AppsBody(),
      );
}

class _AppsBody extends StatelessWidget {
  const _AppsBody();

  /// Entrance delays stop growing past this row so a phone full of apps still
  /// finishes arriving in under half a second.
  static const int _maxStagger = 8;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AppsViewModel>();

    return SmoothScrollView(
      padding: Pad.page,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Sizes.contentMax),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Entrance(child: _Header()),
              if (vm.isLoading) ...[
                const SizedBox(height: Space.s4),
                const Entrance(
                  index: 1,
                  child: LoadingLine(label: 'Loading apps\u2026'),
                ),
              ],
              if (vm.hasError) ...[
                const SizedBox(height: Space.s4),
                Entrance(
                  index: 1,
                  child: Alert(
                    kind: AlertKind.danger,
                    title: "Couldn't read your iPhone",
                    message: vm.error!,
                  ),
                ),
              ],
              if (vm.isEmpty) ...[
                const SizedBox(height: Space.s4),
                // The same centred treatment the Library's empty state uses: two
                // lists of the same kind of row should not go blank differently.
                const Entrance(
                  index: 1,
                  child: SizedBox(
                    width: double.infinity,
                    child: EmptyState(
                      icon: Icons.grid_view_rounded,
                      title: 'No user apps found.',
                      subtitle: 'Only apps you installed yourself are listed '
                          "here \u2014 iOS's own apps are not.",
                    ),
                  ),
                ),
              ],
              for (int i = 0; i < vm.rows.length; i++) ...[
                SizedBox(height: i == 0 ? Space.s4 : Space.s2),
                Entrance(
                  key: ValueKey<String>(vm.rows[i].bundleId),
                  index: math.min(i + 1, _maxStagger),
                  child: _AppRowTile(vm: vm, row: vm.rows[i]),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Installed apps', style: context.t.display),
          const SizedBox(height: Space.s1),
          Text('User apps on your iPhone.', style: context.t.bodyMuted),
        ],
      );
}

class _AppRowTile extends StatelessWidget {
  const _AppRowTile({required this.vm, required this.row});

  final AppsViewModel vm;
  final AppRow row;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return AppCard(
      padding: Pad.card,
      // The Avalonia rows used `card flat`: a plain Bg1 fill, no elevation.
      gradient: LinearGradient(colors: <Color>[p.bg1, p.bg1]),
      shadow: false,
      child: Row(
        children: [
          // Arrives on a second pass; until then this is the placeholder tile,
          // which keeps the row height stable so the list never jumps.
          AppIconImage(bytes: row.iconBytes, size: Sizes.appIconSmall),
          const SizedBox(width: Space.s4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.name,
                  style: context.t.semi(FontSizes.body),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: Space.s1),
                Text(
                  row.subtitle,
                  style: context.t.smallMuted,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.s4),
          AppButton(
            label: row.isRemoving ? 'Removing\u2026' : 'Uninstall',
            tone: ButtonTone.danger,
            compact: true,
            busy: row.isRemoving,
            onPressed: row.isRemoving ? null : () => vm.uninstallRow(row),
          ),
        ],
      ),
    );
  }
}
