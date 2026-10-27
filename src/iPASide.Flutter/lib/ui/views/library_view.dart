import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../engine/engine.dart';
import '../../services/icon_cache.dart';
import '../../services/settings_store.dart';
import '../../viewmodels/device_selection.dart';
import '../../viewmodels/library_view_model.dart';
import '../shell/app_dialogs.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icon_image.dart';
import '../widgets/buttons.dart';
import '../widgets/motion.dart';
import '../widgets/progress.dart';
import '../widgets/smooth_scroll.dart';
import '../widgets/surfaces.dart';

/// Library: every sideloaded app with its expiry countdown, a per-row Refresh
/// and Remove, and a Refresh-all toolbar.
class LibraryView extends StatelessWidget {
  const LibraryView({super.key});

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (ctx) => LibraryViewModel(
          engine: ctx.read<EngineApi>(),
          dialogs: ctx.read<DialogService>(),
          icons: ctx.read<IconCache>(),
          settings: ctx.read<SettingsStore>(),
          devices: ctx.read<DeviceSelection>(),
        ),
        child: const _LibraryBody(),
      );
}

class _LibraryBody extends StatelessWidget {
  const _LibraryBody();

  /// Entrance delays stop growing past this row so a large library still
  /// finishes arriving in under half a second.
  static const int _maxStagger = 8;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<LibraryViewModel>();

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
              if (vm.hasItems) ...[
                const SizedBox(height: Space.s4),
                Entrance(index: 1, child: _RefreshAllButton(vm: vm)),
              ],
              if (vm.isLoading) ...[
                const SizedBox(height: Space.s4),
                const Entrance(
                  index: 1,
                  child: LoadingLine(label: 'Loading\u2026'),
                ),
              ],
              if (vm.hasError) ...[
                const SizedBox(height: Space.s4),
                Entrance(
                  index: 1,
                  child: Alert(
                    kind: AlertKind.danger,
                    title: "Couldn't load your library",
                    message: vm.error!,
                  ),
                ),
              ],
              if (vm.isEmpty) ...[
                const SizedBox(height: Space.s4),
                const Entrance(
                  index: 1,
                  child: SizedBox(
                    width: double.infinity,
                    child: EmptyState(
                      icon: Icons.collections_bookmark_outlined,
                      title: 'No sideloaded apps yet',
                      subtitle: "Sideload an app and it'll show up here with "
                          'its expiry countdown.',
                    ),
                  ),
                ),
              ],
              for (int i = 0; i < vm.rows.length; i++) ...[
                SizedBox(height: i == 0 ? Space.s4 : Space.s2),
                Entrance(
                  key: ValueKey<String>(vm.rows[i].bundleId),
                  index: math.min(i + 2, _maxStagger),
                  child: _LibraryRowTile(vm: vm, row: vm.rows[i]),
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
          Text('Library', style: context.t.display),
          const SizedBox(height: Space.s1),
          Text(
            "Apps you've sideloaded. Free-account signatures expire after "
            '7 days \u2014 refresh to keep them working.',
            style: context.t.bodyMuted,
          ),
        ],
      );
}

class _RefreshAllButton extends StatelessWidget {
  const _RefreshAllButton({required this.vm});

  final LibraryViewModel vm;

  @override
  Widget build(BuildContext context) => AppButton(
        label: vm.isRefreshingAll ? 'Refreshing\u2026' : 'Refresh all',
        icon: Icons.refresh_rounded,
        busy: vm.isRefreshingAll,
        onPressed: vm.refreshAll,
      );
}

class _LibraryRowTile extends StatelessWidget {
  const _LibraryRowTile({required this.vm, required this.row});

  final LibraryViewModel vm;
  final LibraryRow row;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return AppCard(
      padding: Pad.card,
      // The Avalonia rows used `card flat`: a plain Bg1 fill, no elevation.
      gradient: LinearGradient(colors: <Color>[p.bg1, p.bg1]),
      shadow: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _rowHeader(context),
          // A refresh re-signs, so it runs the same provision → sign → install a
          // sideload does; showing it the same way means the wait is legible
          // instead of a spinner that could mean anything. The row only grows
          // while it is actually working.
          if (row.isRefreshing) ...[
            const SizedBox(height: Space.s4),
            SideloadStepper(
              activeIndex: row.progress.activeIndex,
              stepText: row.progress.stepText,
              percent: row.progress.percent,
              isIndeterminate: row.progress.isIndeterminate,
            ),
          ],
        ],
      ),
    );
  }

  Widget _rowHeader(BuildContext context) {
    return Row(
      children: [
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
        Pill(label: row.pillText, kind: row.pillKind),
        const SizedBox(width: Space.s4),
        AppButton(
          label: 'Refresh',
          icon: Icons.refresh_rounded,
          compact: true,
          busy: row.isRefreshing,
          tooltip: row.refreshStepText,
          onPressed: row.isBusy ? null : () => vm.refreshRow(row),
        ),
        const SizedBox(width: Space.s2),
        AppButton(
          label: 'Remove',
          tone: ButtonTone.danger,
          compact: true,
          busy: row.isRemoving,
          onPressed: row.isBusy ? null : () => vm.removeRow(row),
        ),
      ],
    );
  }
}
