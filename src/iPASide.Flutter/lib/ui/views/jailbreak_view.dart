import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../engine/engine.dart';
import '../../viewmodels/jailbreak_view_model.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icon_image.dart';
import '../widgets/buttons.dart';
import '../widgets/motion.dart';
import '../widgets/progress.dart';
import '../widgets/smooth_scroll.dart';
import '../widgets/surfaces.dart';

/// Jailbreak: check whether Dopamine fits the connected device, and install it.
class JailbreakView extends StatefulWidget {
  const JailbreakView({super.key});

  @override
  State<JailbreakView> createState() => _JailbreakViewState();
}

class _JailbreakViewState extends State<JailbreakView> {
  @override
  void initState() {
    super.initState();
    // The model is app-scoped, so it may already hold advice - or an install in
    // flight - from an earlier visit. Refreshing on arrival keeps what is drawn true
    // to the connected device without disturbing either.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<JailbreakViewModel>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final JailbreakViewModel vm = context.watch<JailbreakViewModel>();

    return SmoothScrollView(
      padding: Pad.page,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Sizes.contentMax),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Entrance(child: _Header()),
              const SizedBox(height: Space.s5),
              Entrance(index: 1, child: _CompatibilityCard(vm: vm)),
              if (vm.showStepper) ...<Widget>[
                const SizedBox(height: Space.s5),
                Entrance(index: 2, child: _RunCard(vm: vm)),
              ],
              const SizedBox(height: Space.s5),
              const Entrance(index: 3, child: _ExplainerCard()),
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
        children: <Widget>[
          Text('Jailbreak', style: context.t.display),
          const SizedBox(height: Space.s1),
          Text(
            'Check whether your iPhone can be jailbroken with Dopamine, and install it '
            'over USB.',
            style: context.t.bodyMuted,
          ),
        ],
      );
}

/// What the advisor concluded for the connected device, and the install button.
class _CompatibilityCard extends StatelessWidget {
  const _CompatibilityCard({required this.vm});

  final JailbreakViewModel vm;

  @override
  Widget build(BuildContext context) {
    if (vm.error != null) {
      // The compatibility list is fetched live and the device is read over USB; either
      // can fail transiently (no network, a locked phone), so the answer is a Retry
      // rather than a dead end - there is deliberately no stale bundled fallback.
      return Alert(
        kind: AlertKind.danger,
        title: "Couldn't check compatibility",
        message: vm.error!,
        trailing: AppButton(
          label: 'Retry',
          icon: Icons.refresh_rounded,
          compact: true,
          busy: vm.isLoading,
          onPressed: vm.isLoading ? null : vm.load,
        ),
      );
    }

    final bool checking = vm.isLoading && vm.advice == null;
    return StatusCard(
      label: 'COMPATIBILITY',
      footer: _Action(vm: vm),
      // Dopamine's own icon, a bundled asset with no dependency on the device, so it is
      // drawn from the first frame - during the check and whether or not the device is
      // supported. It is the same tool either way, and seeing what you are about to
      // install is most useful before you have it. Only the text beside it waits on the
      // phone. Mirrors how the LiveContainer screen shows its icon.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const AppIconImage.asset('assets/brand/dopamine.png'),
          const SizedBox(width: Space.s4),
          Expanded(
            child: checking
                ? const LoadingLine(label: 'Checking your iPhone\u2026')
                : _CompatibilityBody(vm: vm),
          ),
        ],
      ),
    );
  }
}

class _CompatibilityBody extends StatelessWidget {
  const _CompatibilityBody({required this.vm});

  final JailbreakViewModel vm;

  @override
  Widget build(BuildContext context) {
    final JailbreakAdvice? advice = vm.advice;
    if (advice == null) {
      return Text(
        'Connect an iPhone to check whether Dopamine supports it.',
        style: context.t.bodyMuted,
      );
    }

    final String device = advice.deviceName ?? advice.productType ?? 'This device';
    final String chip = advice.chip ?? 'unknown chip';
    final String ios = advice.iosVersion ?? '';
    final String subtitle = ios.isEmpty ? chip : '$chip \u00b7 iOS $ios';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            _OutcomePill(advice: advice),
            const SizedBox(width: Space.s3),
            Expanded(
              child: Text('$device \u00b7 $subtitle', style: context.t.bodyMuted),
            ),
          ],
        ),
        const SizedBox(height: Space.s3),
        Text(advice.summary ?? '', style: context.t.body),
      ],
    );
  }
}

class _OutcomePill extends StatelessWidget {
  const _OutcomePill({required this.advice});

  final JailbreakAdvice advice;

  @override
  Widget build(BuildContext context) {
    final (String label, PillKind kind) = switch (advice.outcome) {
      'supported' => ('Supported', PillKind.ok),
      'no_jailbreak' => ('No jailbreak', PillKind.danger),
      'unsupported_version' => ('Not on this iOS', PillKind.warn),
      _ => ('Check project page', PillKind.neutral),
    };
    return Pill(label: label, kind: kind);
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.vm});

  final JailbreakViewModel vm;

  @override
  Widget build(BuildContext context) {
    final String name = vm.tool?.name ?? 'Dopamine';
    // Install is offered only when the advisor is sure the device is supported;
    // otherwise it would sign and install something that cannot run. When it is not
    // installable, the project page is the primary action instead of a dead button, so
    // a tap always does something and the supported-device list is one click away.
    return Row(
      children: <Widget>[
        if (vm.canInstall) ...<Widget>[
          AppButton(
            label: 'Install $name',
            icon: Icons.download_rounded,
            tone: ButtonTone.primary,
            busy: vm.isRunning,
            onPressed: vm.isRunning ? null : vm.install,
          ),
          const SizedBox(width: Space.s3),
        ],
        AppButton(
          label: vm.canInstall ? 'Project page' : 'See supported devices',
          icon: Icons.open_in_new_rounded,
          tone: vm.canInstall ? ButtonTone.soft : ButtonTone.primary,
          onPressed: vm.openProjectPage,
        ),
      ],
    );
  }
}

/// The stepper, and whatever the finished install has to say.
class _RunCard extends StatelessWidget {
  const _RunCard({required this.vm});

  final JailbreakViewModel vm;

  @override
  Widget build(BuildContext context) {
    final String name = vm.tool?.name ?? 'Dopamine';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AppCard(
          child: SideloadStepper(
            steps: JailbreakViewModel.schedule.steps,
            activeIndex: vm.progress.activeIndex,
            stepText: vm.progress.stepText,
            percent: vm.progress.percent,
            isIndeterminate: vm.progress.isIndeterminate,
            isComplete: vm.isSucceeded,
            hasError: vm.isFailed,
          ),
        ),
        if (vm.isFailed) ...<Widget>[
          const SizedBox(height: Space.s4),
          Alert(
            kind: AlertKind.danger,
            title: "$name wasn't installed",
            message: vm.failureMessage!,
          ),
        ],
        if (vm.isSucceeded) ...<Widget>[
          const SizedBox(height: Space.s4),
          Alert(
            kind: AlertKind.success,
            title: 'Installed $name${_version(vm)}',
            message: 'Open $name on your iPhone to run the jailbreak. iPASide will '
                'refresh it before its 7-day profile expires, like any sideloaded app.',
          ),
        ],
      ],
    );
  }

  static String _version(JailbreakViewModel vm) {
    final String? version = vm.result?.version;
    return version == null || version.isEmpty ? '' : ' $version';
  }
}

/// What this screen is, in the terms someone new to jailbreaking would ask it.
class _ExplainerCard extends StatelessWidget {
  const _ExplainerCard();

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SectionLabel('How it works'),
            const SizedBox(height: Space.s3),
            const _Point(
              icon: Icons.download_outlined,
              title: 'iPASide installs it, your phone runs it',
              body: 'iPASide downloads Dopamine, signs it with your free Apple ID and '
                  'installs it over USB \u2014 the same as any sideload. The jailbreak '
                  'itself runs on your iPhone the first time you open Dopamine. iPASide '
                  'never runs an exploit.',
            ),
            const SizedBox(height: Space.s4),
            const _Point(
              icon: Icons.memory_outlined,
              title: 'It depends on your device and iOS build',
              body: 'Support can differ between devices with the same chip, and beta-only '
                  'support depends on the exact build. iPASide checks the live Dopamine '
                  'compatibility list before it enables Install.',
            ),
            const SizedBox(height: Space.s4),
            const _Point(
              icon: Icons.event_repeat_outlined,
              title: 'Refreshed like anything else',
              body: 'Dopamine is tracked in your Library and re-signed before its seven '
                  'days are up, so it keeps working without reinstalling.',
            ),
          ],
        ),
      );
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: Sizes.iconLarge, color: p.accent),
        const SizedBox(width: Space.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: context.t.semi(FontSizes.body)),
              const SizedBox(height: Space.s1),
              Text(body, style: context.t.bodyMuted),
            ],
          ),
        ),
      ],
    );
  }
}
