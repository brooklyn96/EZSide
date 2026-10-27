import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../engine/engine.dart';
import '../../viewmodels/account_selection.dart';
import '../../viewmodels/account_view_model.dart';
import '../shell/app_dialogs.dart';
import '../theme/app_theme.dart';
import '../widgets/buttons.dart';
import '../widgets/motion.dart';
import '../widgets/progress.dart';
import '../widgets/smooth_scroll.dart';
import '../widgets/surfaces.dart';

/// `26 Jul 2027`.
///
/// A day, a short month name and a year read the same everywhere, which is what lets one
/// date be rendered without a localisation package - the same reasoning as
/// `UpdateViewModel.describeLastChecked`.
String _shortDate(DateTime when) {
  const List<String> months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final DateTime local = when.toLocal();
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

/// Account: what your Apple ID's developer account holds, and how to tidy it.
class AccountView extends StatelessWidget {
  const AccountView({super.key});

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (ctx) => AccountViewModel(
          engine: ctx.read<EngineApi>(),
          dialogs: ctx.read<DialogService>(),
          accounts: ctx.read<AccountSelection>(),
        ),
        child: const _AccountBody(),
      );
}

class _AccountBody extends StatelessWidget {
  const _AccountBody();

  @override
  Widget build(BuildContext context) {
    final AccountViewModel vm = context.watch<AccountViewModel>();

    return SmoothScrollView(
      padding: Pad.page,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Sizes.contentMax),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Entrance(child: _Header(vm: vm)),
              if (vm.error != null) ...<Widget>[
                const SizedBox(height: Space.s5),
                Entrance(
                  index: 1,
                  child: Alert(
                    kind: AlertKind.danger,
                    title: "Couldn't read your account",
                    message: vm.error!,
                  ),
                ),
              ],
              if (vm.notice != null) ...<Widget>[
                const SizedBox(height: Space.s5),
                Entrance(
                  index: 1,
                  child: Alert(
                    kind: AlertKind.info,
                    message: vm.notice!,
                    trailing: AppButton(
                      label: 'Dismiss',
                      compact: true,
                      onPressed: vm.dismissNotice,
                    ),
                  ),
                ),
              ],
              if (vm.isLoading && vm.overview == null) ...<Widget>[
                const SizedBox(height: Space.s5),
                const Entrance(
                  index: 2,
                  child: LoadingLine(label: 'Asking Apple\u2026'),
                ),
              ],
              if (vm.overview != null) ...<Widget>[
                const SizedBox(height: Space.s5),
                Entrance(index: 2, child: _Certificates(vm: vm)),
                const SizedBox(height: Space.s5),
                Entrance(index: 3, child: _AppIds(vm: vm)),
                const SizedBox(height: Space.s5),
                Entrance(index: 4, child: _Devices(vm: vm)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.vm});

  final AccountViewModel vm;

  @override
  Widget build(BuildContext context) {
    final AccountOverview? overview = vm.overview;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Account', style: context.t.display),
              const SizedBox(height: Space.s1),
              Text(
                overview == null
                    ? 'What your Apple ID lets you sign, and what it has used up.'
                    : '${vm.email ?? ''} \u00b7 ${overview.teamName ?? ''} '
                        '(${overview.teamId ?? ''})',
                style: context.t.bodyMuted,
              ),
            ],
          ),
        ),
        AppButton(
          label: 'Refresh',
          icon: Icons.sync_rounded,
          compact: true,
          busy: vm.isLoading,
          onPressed: vm.isLoading || vm.isBusy ? null : vm.load,
        ),
      ],
    );
  }
}

/// The part that matters most: which certificate belongs to which tool.
class _Certificates extends StatelessWidget {
  const _Certificates({required this.vm});

  final AccountViewModel vm;

  @override
  Widget build(BuildContext context) {
    final List<AccountCertificate> certificates =
        vm.overview?.certificates ?? const <AccountCertificate>[];

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionLabel('SIGNING CERTIFICATES'),
          const SizedBox(height: Space.s2),
          Text(
            certificates.length > 1
                // Said plainly, because the obvious assumption - that a free account gets
                // one - is what makes several look like a problem to clear up.
                ? 'Apple counts these per machine, not per account, so more than one is '
                    'normal. Revoking one stops the apps it signed from opening.'
                : 'Apple counts these per machine, so other tools can hold their own '
                    'without affecting this one.',
            style: context.t.bodyMuted,
          ),
          if (certificates.isEmpty) ...<Widget>[
            const SizedBox(height: Space.s4),
            Text('None yet.', style: context.t.bodyMuted),
          ],
          for (final AccountCertificate certificate in certificates) ...<Widget>[
            const SizedBox(height: Space.s4),
            _CertificateRow(vm: vm, certificate: certificate),
          ],
        ],
      ),
    );
  }
}

class _CertificateRow extends StatelessWidget {
  const _CertificateRow({required this.vm, required this.certificate});

  final AccountViewModel vm;
  final AccountCertificate certificate;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Pill(
                    label: certificate.owner,
                    kind: certificate.inUseHere ? PillKind.ok : PillKind.neutral,
                  ),
                  if (certificate.type != null) ...<Widget>[
                    const SizedBox(width: Space.s3),
                    Text(certificate.type!, style: context.t.bodyMuted),
                  ],
                ],
              ),
              const SizedBox(height: Space.s2),
              Text(
                certificate.serial ?? '',
                style: context.t.mono,
              ),
              if (certificate.expires != null) ...<Widget>[
                const SizedBox(height: Space.s1),
                Text(
                  'Expires ${_shortDate(certificate.expires!)}',
                  style: context.t.bodyMuted,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: Space.s4),
        AppButton(
          label: 'Revoke',
          tone: ButtonTone.danger,
          compact: true,
          busy: vm.isRevoking(certificate.serial),
          onPressed: vm.isBusy ? null : () => vm.revoke(certificate),
        ),
      ],
    );
  }
}

class _AppIds extends StatelessWidget {
  const _AppIds({required this.vm});

  final AccountViewModel vm;

  @override
  Widget build(BuildContext context) {
    final AccountOverview overview = vm.overview!;
    final List<AccountAppId> appIds = overview.appIds;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionLabel('APP IDS'),
          const SizedBox(height: Space.s2),
          // Two numbers, never one fraction: the weekly figure counts registrations over
          // a rolling week while the list is what exists, and as "N of 10" it reads as
          // spare capacity that may already be spent.
          Text(
            '${overview.registeredAppIds} registered. Apple also allows about '
            '${overview.weeklyAppIdLimit} new identifiers per 7 days, counted separately '
            '\u2014 deleting one below frees the name, not the week\u2019s allowance.',
            style: context.t.bodyMuted,
          ),
          if (appIds.isEmpty) ...<Widget>[
            const SizedBox(height: Space.s4),
            Text('None registered.', style: context.t.bodyMuted),
          ],
          for (final AccountAppId appId in appIds) ...<Widget>[
            const SizedBox(height: Space.s4),
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        appId.identifier ?? '',
                        style: context.t.semi(FontSizes.body),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (appId.name != null) ...<Widget>[
                        const SizedBox(height: Space.s1),
                        Text(appId.name!, style: context.t.bodyMuted),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: Space.s4),
                AppButton(
                  label: 'Delete',
                  tone: ButtonTone.danger,
                  compact: true,
                  busy: vm.isDeleting(appId.id),
                  onPressed: vm.isBusy ? null : () => vm.deleteAppId(appId),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Devices extends StatelessWidget {
  const _Devices({required this.vm});

  final AccountViewModel vm;

  @override
  Widget build(BuildContext context) {
    final List<AccountDevice> devices = vm.overview?.devices ?? const <AccountDevice>[];
    final p = context.palette;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionLabel('DEVICES'),
          const SizedBox(height: Space.s2),
          Text(
            'Registered to this team. Apple does not let a free account remove these, '
            'so they are shown for what they are rather than to be managed.',
            style: context.t.bodyMuted,
          ),
          if (devices.isEmpty) ...<Widget>[
            const SizedBox(height: Space.s4),
            Text('None registered.', style: context.t.bodyMuted),
          ],
          for (final AccountDevice device in devices) ...<Widget>[
            const SizedBox(height: Space.s3),
            Row(
              children: <Widget>[
                Icon(Icons.smartphone_outlined, size: Sizes.icon, color: p.textMuted),
                const SizedBox(width: Space.s3),
                Expanded(
                  child: Text(
                    device.name ?? 'Unnamed device',
                    style: context.t.semi(FontSizes.body),
                  ),
                ),
                Text(
                  device.udid ?? '',
                  style: context.t.mono,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
