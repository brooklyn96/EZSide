import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../engine/engine.dart';
import '../../viewmodels/apple_support_view_model.dart';
import '../../viewmodels/diagnostics_view_model.dart';
import '../theme/app_theme.dart';
import '../widgets/apple_support_banner.dart';
import '../widgets/buttons.dart';
import '../widgets/motion.dart';
import '../widgets/progress.dart';
import '../widgets/smooth_scroll.dart';
import '../widgets/surfaces.dart';

/// Diagnostics: the overall banner plus one row per environment check.
class DiagnosticsView extends StatelessWidget {
  const DiagnosticsView({super.key});

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (ctx) => DiagnosticsViewModel(
          engine: ctx.read<EngineApi>(),
          appleSupport: ctx.read<AppleSupportViewModel>(),
        ),
        child: const _DiagnosticsBody(),
      );
}

class _DiagnosticsBody extends StatelessWidget {
  const _DiagnosticsBody();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<DiagnosticsViewModel>();
    final apple = context.watch<AppleSupportViewModel>();

    return SmoothScrollView(
      padding: const EdgeInsets.fromLTRB(Space.s6, Space.s5, Space.s6, Space.s7),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Sizes.contentMax),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Entrance(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Diagnostics', style: context.t.display),
                    const SizedBox(height: Space.s1),
                    Text(
                      'Confirms iPASide can reach Apple and your device.',
                      style: context.t.bodyMuted,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.s4),
              // The Apple-service row below reports the same status this banner
              // does — it is the same probe — but a row can only tell you; this can
              // fix it. It leads because it is the one blocker on this screen that
              // stops every other check from mattering.
              if (apple.hasNotice) ...[
                Entrance(index: 1, child: AppleSupportBanner(model: apple)),
                const SizedBox(height: Space.s4),
              ],
              if (vm.isLoading) ...[
                const Entrance(
                  index: 2,
                  child: LoadingLine(label: 'Running checks\u2026'),
                ),
                const SizedBox(height: Space.s4),
              ],
              if (vm.hasError) ...[
                Entrance(
                  index: 2,
                  child: Alert(kind: AlertKind.danger, message: vm.error!),
                ),
                const SizedBox(height: Space.s4),
              ],
              if (vm.hasReport) ...[
                Entrance(index: 2, child: _OverallBanner(vm: vm)),
                for (var i = 0; i < vm.checks.length; i++) ...[
                  SizedBox(height: i == 0 ? Space.s4 : Space.s2),
                  Entrance(index: 3 + i, child: _CheckRow(row: vm.checks[i])),
                ],
                const SizedBox(height: Space.s4),
              ],
              AppButton(
                label: 'Re-run checks',
                onPressed: vm.isLoading ? null : vm.reRun,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverallBanner extends StatelessWidget {
  const _OverallBanner({required this.vm});

  final DiagnosticsViewModel vm;

  @override
  Widget build(BuildContext context) => Alert(
        kind: switch (vm.overallStatus) {
          DiagnosticsStatus.ok => AlertKind.success,
          DiagnosticsStatus.fail => AlertKind.danger,
          DiagnosticsStatus.warn || DiagnosticsStatus.unknown =>
            AlertKind.warning,
        },
        title: vm.overallLabel,
      );
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.row});

  final DiagnosticsCheckRow row;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final badge = switch (row.status) {
      DiagnosticsStatus.ok => (Icons.check_circle_rounded, p.success),
      DiagnosticsStatus.warn => (Icons.warning_amber_rounded, p.warning),
      DiagnosticsStatus.fail => (Icons.error_outline_rounded, p.danger),
      DiagnosticsStatus.unknown => null,
    };

    return AppCard(
      padding: Pad.card,
      // Flat, like the Library and Apps rows: a list of rows on one screen should
      // not be a different kind of surface from a list of rows on another.
      gradient: LinearGradient(colors: <Color>[p.bg1, p.bg1]),
      shadow: false,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The slot is reserved whether or not this check has a verdict: a status
          // the engine did not report used to drop the icon and take its space
          // with it, so that one row's text started 16px left of all the others.
          SizedBox(
            width: Sizes.icon,
            child: badge == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(badge.$1, size: Sizes.icon, color: badge.$2),
                  ),
          ),
          const SizedBox(width: Space.s4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.name, style: context.t.semi(FontSizes.body)),
                const SizedBox(height: Space.s1),
                Text(row.detail, style: context.t.smallMuted),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
