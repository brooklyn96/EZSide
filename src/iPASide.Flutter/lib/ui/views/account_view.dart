import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../engine/engine.dart';
import '../../services/file_picker.dart';
import '../../viewmodels/account_selection.dart';
import '../../viewmodels/account_view_model.dart';
import '../../viewmodels/device_selection.dart';
import '../shell/app_dialogs.dart';
import '../theme/app_theme.dart';
import '../widgets/buttons.dart';
import '../widgets/inputs.dart';
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
          picker: ctx.read<FilePickerService>(),
          devices: ctx.read<DeviceSelection>(),
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
              // Outside the overview: an imported certificate needs no Apple ID, so it
              // stays reachable when the account cannot be read.
              const SizedBox(height: Space.s5),
              Entrance(index: 5, child: _ImportedCertificate(vm: vm)),
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
          onPressed:
              vm.isLoading || vm.isBusy || vm.isCertificateBusy ? null : vm.refresh,
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

/// The certificate bought from a seller: import it, see what it covers, re-sign with
/// a replacement, or remove it.
class _ImportedCertificate extends StatelessWidget {
  const _ImportedCertificate({required this.vm});

  final AccountViewModel vm;

  @override
  Widget build(BuildContext context) {
    final ImportedCertificate? certificate = vm.certificate;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionLabel('IMPORTED CERTIFICATE'),
          const SizedBox(height: Space.s2),
          if (certificate == null)
            Text(
              'Bought a certificate? Import its .p12 file, password and '
              '.mobileprovision, and new sideloads are signed with it instead of '
              'your Apple ID. Apps then last until it expires, with no weekly refresh.',
              style: context.t.bodyMuted,
            )
          else
            _CertificateDetails(certificate: certificate),
          if (vm.certificateError != null) ...<Widget>[
            const SizedBox(height: Space.s4),
            Alert(kind: AlertKind.danger, message: vm.certificateError!),
          ],
          if (vm.certificateNotice != null) ...<Widget>[
            const SizedBox(height: Space.s4),
            Alert(
              kind: vm.resignHasFailures ? AlertKind.warning : AlertKind.success,
              message: vm.certificateNotice!,
              trailing: AppButton(
                label: 'Dismiss',
                compact: true,
                onPressed: vm.dismissCertificateNotice,
              ),
            ),
          ],
          for (final CertificateResignResult result
              in vm.resignResults ?? const <CertificateResignResult>[]) ...<Widget>[
            const SizedBox(height: Space.s3),
            _ResignResultRow(result: result),
          ],
          const SizedBox(height: Space.s4),
          if (!vm.hasReadCertificate)
            const LoadingLine(label: 'Reading the imported certificate…')
          else if (vm.isImportOpen)
            _ImportForm(vm: vm)
          else if (certificate == null)
            AppButton(
              label: 'Import certificate',
              icon: Icons.upload_file_rounded,
              onPressed: vm.isCertificateBusy ? null : vm.openImport,
            )
          else
            _CertificateActions(vm: vm),
        ],
      ),
    );
  }
}

class _CertificateDetails extends StatelessWidget {
  const _CertificateDetails({required this.certificate});

  final ImportedCertificate certificate;

  @override
  Widget build(BuildContext context) {
    final DateTime? expires = certificate.expires;
    final int? daysLeft = expires?.difference(DateTime.now()).inDays;
    final bool expired = expires != null && !expires.isAfter(DateTime.now());
    final bool? deviceOk = certificate.deviceOk;

    final String team = certificate.teamName == null
        ? certificate.teamId ?? ''
        : '${certificate.teamName} (${certificate.teamId ?? ''})';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    certificate.name ?? 'Imported certificate',
                    style: context.t.semi(FontSizes.body),
                  ),
                  const SizedBox(height: Space.s1),
                  Text(team, style: context.t.bodyMuted),
                ],
              ),
            ),
            const SizedBox(width: Space.s4),
            Pill(
              label: expired
                  ? 'Expired'
                  : daysLeft != null && daysLeft <= 14
                      ? 'Expires soon'
                      : 'Active',
              kind: expired
                  ? PillKind.danger
                  : daysLeft != null && daysLeft <= 14
                      ? PillKind.warn
                      : PillKind.ok,
            ),
          ],
        ),
        const SizedBox(height: Space.s3),
        KeyValueRow(
          expired ? 'Expired' : 'Expires',
          expires == null
              ? 'Unknown'
              : expired
                  ? _shortDate(expires)
                  : '${_shortDate(expires)} · '
                      '$daysLeft day${daysLeft == 1 ? '' : 's'} left',
        ),
        KeyValueRow('App ID', certificate.appId ?? 'Unknown', mono: true),
        KeyValueRow(
          'This iPhone is in the profile',
          switch (deviceOk) {
            true => 'Yes',
            false => 'No',
            null => 'No iPhone selected',
          },
        ),
        if (deviceOk == false) ...<Widget>[
          const SizedBox(height: Space.s3),
          const Alert(
            kind: AlertKind.warning,
            message: 'This iPhone is not in the provisioning profile, so apps signed '
                'with this certificate will not install on it and new sideloads to '
                'this iPhone use your Apple ID. Ask the seller to add it, then '
                'import the new profile.',
          ),
        ],
        // Only while it is what signs: expired, or a phone outside the profile, and
        // new sideloads fall back to the Apple ID.
        if (!expired && deviceOk != false) ...<Widget>[
          const SizedBox(height: Space.s3),
          Text(
            'New sideloads are signed with this certificate. LiveContainer keeps '
            'using your Apple ID.',
            style: context.t.bodyMuted,
          ),
        ] else if (expired) ...<Widget>[
          const SizedBox(height: Space.s3),
          Text(
            'It has expired, so new sideloads use your Apple ID.',
            style: context.t.bodyMuted,
          ),
        ],
      ],
    );
  }
}

class _CertificateActions extends StatelessWidget {
  const _CertificateActions({required this.vm});

  final AccountViewModel vm;

  @override
  Widget build(BuildContext context) {
    final bool busy = vm.isCertificateBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: Space.s3,
          runSpacing: Space.s2,
          children: <Widget>[
            AppButton(
              label: 'Re-sign all apps with this certificate',
              icon: Icons.refresh_rounded,
              tone: ButtonTone.primary,
              busy: vm.isResigning,
              onPressed: busy ? null : vm.resignAll,
              tooltip: 'Re-signs and reinstalls every app EZSide installed with an '
                  'imported certificate, from the copy it kept',
            ),
            AppButton(
              label: 'Replace',
              icon: Icons.swap_horiz_rounded,
              onPressed: busy ? null : vm.openImport,
            ),
            AppButton(
              label: 'Remove',
              tone: ButtonTone.danger,
              busy: vm.isRemovingCertificate,
              onPressed: busy ? null : vm.removeCertificate,
            ),
          ],
        ),
        if (vm.isResigning) ...<Widget>[
          const SizedBox(height: Space.s3),
          LoadingLine(label: vm.resignStep ?? 'Re-signing…'),
        ],
      ],
    );
  }
}

class _ImportForm extends StatelessWidget {
  const _ImportForm({required this.vm});

  final AccountViewModel vm;

  @override
  Widget build(BuildContext context) {
    final bool busy = vm.isImporting;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _FileChoice(
          label: 'Certificate (.p12)',
          path: vm.certificatePath,
          onChoose: busy ? null : vm.chooseCertificateFile,
        ),
        const SizedBox(height: Space.s4),
        AppTextField(
          label: 'Certificate password',
          controller: vm.certificatePassword,
          obscure: true,
          onSubmitted: (_) => vm.importCertificate(),
        ),
        const SizedBox(height: Space.s4),
        _FileChoice(
          label: 'Provisioning profile (.mobileprovision)',
          path: vm.profilePath,
          onChoose: busy ? null : vm.chooseProfileFile,
        ),
        const SizedBox(height: Space.s5),
        Row(
          children: <Widget>[
            AppButton(
              label: 'Import',
              icon: Icons.upload_file_rounded,
              tone: ButtonTone.primary,
              busy: busy,
              onPressed: busy ? null : vm.importCertificate,
            ),
            const SizedBox(width: Space.s3),
            AppButton(
              label: 'Cancel',
              onPressed: busy ? null : vm.cancelImport,
            ),
          ],
        ),
      ],
    );
  }
}

/// One file the import needs: what it is, which file was chosen, and a way to choose.
class _FileChoice extends StatelessWidget {
  const _FileChoice({required this.label, required this.path, required this.onChoose});

  final String label;
  final String? path;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    final String? chosen = path;

    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label, style: context.t.smallMuted),
              const SizedBox(height: Space.s1),
              Text(
                chosen == null ? 'Not chosen' : chosen.split(RegExp(r'[\\/]')).last,
                style: chosen == null ? context.t.bodyMuted : context.t.mono,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: Space.s4),
        AppButton(
          label: chosen == null ? 'Choose…' : 'Change…',
          icon: Icons.folder_open_rounded,
          compact: true,
          onPressed: onChoose,
        ),
      ],
    );
  }
}

class _ResignResultRow extends StatelessWidget {
  const _ResignResultRow({required this.result});

  final CertificateResignResult result;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Pill(
          label: result.ok ? 'Re-signed' : 'Failed',
          kind: result.ok ? PillKind.ok : PillKind.danger,
        ),
        const SizedBox(width: Space.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                result.name ?? result.bundleId ?? 'Unknown app',
                style: context.t.semi(FontSizes.body),
              ),
              if (!result.ok && result.error != null) ...<Widget>[
                const SizedBox(height: Space.s1),
                Text(result.error!, style: context.t.bodyMuted),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
