import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../engine/engine.dart';
import '../../platform/background_refresh_scheduler.dart';
import '../../platform/tray_service.dart';
import '../../services/file_picker.dart';
import '../../services/settings_store.dart';
import '../../viewmodels/account_selection.dart';
import '../../viewmodels/device_selection.dart';
import '../../viewmodels/navigation_state.dart';
import '../../viewmodels/settings_view_model.dart';
import '../../viewmodels/theme_controller.dart';
import '../../viewmodels/update_view_model.dart';
import '../shell/app_dialogs.dart';
import '../theme/app_theme.dart';
import '../widgets/buttons.dart';
import '../widgets/inputs.dart';
import '../widgets/motion.dart';
import '../widgets/progress.dart';
import '../widgets/settings_layout.dart';
import '../widgets/smooth_scroll.dart';

/// Settings: appearance, device, pairing file, auto-refresh, background,
/// signed IPAs, account, anisette, updates and about.
///
/// One column of full-width grouped sections rather than a grid of cards. The
/// sections carry wildly different amounts of content — three lines of prose and
/// a toggle in one, a single button in another — and in a two-column grid the
/// shorter of each pair ends early and leaves a hole beside the taller one.
/// Stacked, height stops mattering: every row has the same rhythm and every
/// control lands on the same right edge.
class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (ctx) {
          final SettingsViewModel model = SettingsViewModel(
            engine: ctx.read<EngineApi>(),
            navigation: ctx.read<NavigationState>(),
            scheduler: ctx.read<BackgroundRefreshScheduler>(),
            settings: ctx.read<SettingsStore>(),
            picker: ctx.read<FilePickerService>(),
            dialogs: ctx.read<DialogService>(),
            devices: ctx.read<DeviceSelection>(),
          );
          // The tray can change "Start with Windows" while this page is open.
          ctx.read<StartupStateSignal>().listen(model.refreshStartup);
          return model;
        },
        child: const _SettingsBody(),
      );
}

class _SettingsBody extends StatelessWidget {
  const _SettingsBody();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SettingsViewModel>();

    // Built as a list so the entrance stagger stays contiguous whichever
    // sections this platform has.
    final sections = <Widget>[
      const _AppearanceSection(),
      const _DeviceSection(),
      _PairingSection(vm: vm),
      if (vm.autoRefreshSupported) _AutoRefreshSection(vm: vm),
      if (vm.startupSupported) _BackgroundSection(vm: vm),
      _SignedIpaSection(vm: vm),
      _AccountSection(vm: vm),
      _AnisetteSection(vm: vm),
      const _UpdatesSection(),
      _AboutSection(vm: vm),
    ];

    return SmoothScrollView(
      padding: const EdgeInsets.fromLTRB(Space.s6, Space.s5, Space.s6, Space.s7),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Sizes.contentMax),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Entrance(child: _PageHeading()),
              for (int i = 0; i < sections.length; i++) ...[
                SizedBox(height: i == 0 ? Space.s6 : Space.s4),
                Entrance(index: i + 1, child: sections[i]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PageHeading extends StatelessWidget {
  const _PageHeading();

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Settings', style: context.t.display),
          const SizedBox(height: Space.s1),
          // Deliberately not a list of the sections: there are seven of them, and
          // a subtitle enumerating them is a table of contents for something
          // already visible — and one more thing to forget to update.
          Text('How EZSide behaves on this PC.', style: context.t.bodyMuted),
        ],
      );
}

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    // The label follows what is actually on screen, so "system" resolves the
    // same way the rest of the app resolves it.
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final isDark = theme.isDark(platformBrightness);

    return SettingsSection(
      label: 'APPEARANCE',
      children: [
        SettingsRow(
          title: 'Theme',
          description: 'Follows your system by default.',
          control: AppButton(
            label: isDark ? 'Switch to light' : 'Switch to dark',
            onPressed: () => theme.toggle(platformBrightness),
          ),
        ),
      ],
    );
  }
}

/// How iPASide reaches the phone. *Which* phone is chosen in the sidebar, where
/// the answer changes as devices come and go; this is a standing preference, so it
/// belongs with the other ones.
class _DeviceSection extends StatelessWidget {
  const _DeviceSection();

  @override
  Widget build(BuildContext context) {
    final DeviceSelection devices = context.watch<DeviceSelection>();
    final DeviceTarget? target = devices.selected;

    return SettingsSection(
      label: 'DEVICE',
      children: [
        SettingsRow(
          title: 'Connection',
          description: devices.connection.description,
          control: AppChoiceChips<DeviceConnection>(
            choices: DeviceConnection.values,
            selected: devices.connection,
            labelOf: (DeviceConnection choice) => choice.label,
            onSelect: devices.setConnection,
            groupLabel: 'Connection',
          ),
        ),
        if (target != null)
          SettingsRow(
            title: 'Reachable over',
            // What the phone actually offers, as against what we are asking for:
            // choosing USB only while it says Wi-Fi is the state that explains an
            // otherwise baffling "not reachable" error.
            description: target.name ?? target.shortUdid,
            control: Text(
              target.transportText.isEmpty ? '\u2014' : target.transportText,
              style: context.t.small,
            ),
          ),
      ],
    );
  }
}

/// This PC's pairing file for the selected iPhone: create, import, export.
class _PairingSection extends StatelessWidget {
  const _PairingSection({required this.vm});

  final SettingsViewModel vm;

  @override
  Widget build(BuildContext context) {
    return SettingsSection(
      label: 'PAIRING FILE',
      children: [
        if (vm.isPairingLoading)
          const SettingsBlock(
            child: SettingsLoadingLine(label: 'Reading pairing file\u2026'),
          )
        else if (vm.hasPairingError)
          SettingsBlock(
            child: Text(vm.pairingError!, style: context.t.bodyMuted),
          )
        else ...[
          SettingsRow(
            title: 'USB pairing',
            description: 'Created when you tap Trust on the iPhone.',
            control: SettingsValue(vm.pairingUsbText),
          ),
          SettingsRow(
            title: 'Remote Pairing',
            description:
                'Created over USB by EZSide, same as iLoader. Needed for iOS 26.4+ tunnels; the USB-trust half is enough before that.',
            control: SettingsValue(vm.pairingRemoteText),
          ),
          SettingsRow(
            title: 'This PC\u2019s file',
            description: vm.pairing?.note ??
                'Connect an iPhone over USB and trust this PC, then create keys.',
            control: Wrap(
              spacing: Space.s2,
              runSpacing: Space.s2,
              children: [
                AppButton(
                  label: 'Create keys',
                  compact: true,
                  busy: vm.isPairingBusy,
                  onPressed: vm.canCreatePairing ? vm.createPairing : null,
                ),
                AppButton(
                  label: 'Import\u2026',
                  compact: true,
                  busy: vm.isPairingBusy,
                  onPressed: vm.canImportPairing ? vm.importPairing : null,
                ),
                AppButton(
                  label: 'Export\u2026',
                  compact: true,
                  busy: vm.isPairingBusy,
                  onPressed: vm.canExportPairing ? vm.exportPairing : null,
                ),
              ],
            ),
            detail: vm.hasPairingMessage
                ? SettingsStatusLine(
                    text: vm.pairingMessage,
                    isError: vm.isPairingMessageError,
                  )
                : vm.pairingStatusError != null
                    ? SettingsStatusLine(
                        text: vm.pairingStatusError!,
                        isError: true,
                      )
                    : null,
          ),
          if (vm.pairing == null)
            SettingsBlock(
              child: Text('No iPhone selected.', style: context.t.smallMuted),
            ),
        ],
      ],
    );
  }
}

class _AutoRefreshSection extends StatelessWidget {
  const _AutoRefreshSection({required this.vm});

  final SettingsViewModel vm;

  @override
  Widget build(BuildContext context) => SettingsSection(
        label: 'AUTO-REFRESH',
        children: [
          SettingsRow(
            title: 'Enable background auto-refresh',
            description:
                'Re-sign your sideloaded apps before their 7-day free signature '
                'expires. Windows checks every hour and refreshes the apps that '
                'are close to expiry, and EZSide does not need to be open. Your '
                'iPhone must be reachable \u2014 plugged in, or on the same Wi-Fi '
                'as this PC with Wi-Fi sync turned on (a cable is the most '
                'reliable) \u2014 and you must still be signed in to your Apple '
                'ID. If the iPhone is not reachable, it is tried again the next '
                'hour.',
            control: AppToggle(
              value: vm.autoRefreshEnabled,
              onChanged: vm.autoRefreshBusy ? null : vm.setAutoRefreshEnabled,
              // The row's title is drawn to the left of the switch, not inside
              // it, so the switch needs the name passed explicitly.
              semanticsLabel: 'Enable background auto-refresh',
            ),
            detail: vm.hasAutoRefreshMessage
                ? SettingsStatusLine(
                    text: vm.autoRefreshMessage,
                    isError: vm.isAutoRefreshMessageError,
                  )
                : null,
          ),
        ],
      );
}

/// Background: whether EZSide starts hidden in the tray at sign-in.
class _BackgroundSection extends StatelessWidget {
  const _BackgroundSection({required this.vm});

  final SettingsViewModel vm;

  @override
  Widget build(BuildContext context) => SettingsSection(
        label: 'BACKGROUND',
        children: [
          SettingsRow(
            title: 'Start EZSide with Windows (in the tray)',
            description:
                'EZSide starts hidden in the tray when you sign in, so it can '
                'remember your iPhone when you plug it in. Closing the window '
                'keeps it in the tray either way; use Quit EZSide in the tray '
                'menu to stop it.',
            control: AppToggle(
              value: vm.startupEnabled,
              onChanged: vm.startupBusy ? null : vm.setStartupEnabled,
              semanticsLabel: 'Start EZSide with Windows (in the tray)',
            ),
            detail: vm.hasStartupMessage
                ? SettingsStatusLine(
                    text: vm.startupMessage,
                    isError: vm.isStartupMessageError,
                  )
                : null,
          ),
        ],
      );
}

/// Signed IPAs: whether the signed file survives an install, where it goes, and
/// what has piled up there.
class _SignedIpaSection extends StatelessWidget {
  const _SignedIpaSection({required this.vm});

  final SettingsViewModel vm;

  @override
  Widget build(BuildContext context) => SettingsSection(
        label: 'SIGNED IPAS',
        children: [
          SettingsRow(
            title: 'Keep the signed IPA after installing',
            description:
                'Keeping it lets you install or inspect the signed app again '
                'without signing it a second time. Each one is roughly the size '
                'of the app \u2014 a 233 MB app leaves a 233 MB file behind.',
            control: AppToggle(
              value: vm.keepSignedIpa,
              onChanged: vm.setKeepSignedIpa,
              semanticsLabel: 'Keep the signed IPA after installing',
            ),
          ),
          SettingsRow(
            // No description: the path is right there under it, and the presence
            // of "Use default" already says whether it is the engine's folder or
            // one the user picked.
            title: 'Folder',
            control: Wrap(
              spacing: Space.s2,
              runSpacing: Space.s2,
              children: [
                AppButton(
                  label: 'Change\u2026',
                  compact: true,
                  onPressed: vm.chooseSignedDirectory,
                ),
                if (!vm.usesDefaultSignedDirectory)
                  AppButton(
                    label: 'Use default',
                    compact: true,
                    onPressed: vm.resetSignedDirectory,
                  ),
              ],
            ),
            detail: Text(vm.signedDirectoryText, style: context.t.mono),
          ),
          SettingsRow(
            title: 'Stored',
            description: vm.signedUsageText,
            control: AppButton(
              label: 'Delete all',
              tone: ButtonTone.danger,
              compact: true,
              busy: vm.signedBusy,
              onPressed: vm.canDeleteSignedIpas ? vm.deleteSignedIpas : null,
            ),
            detail: vm.hasSignedMessage
                ? SettingsStatusLine(
                    text: vm.signedMessage,
                    isError: vm.isSignedMessageError,
                  )
                : null,
          ),
        ],
      );
}

/// APPLE IDS: every account signed in, and which one signs new sideloads.
///
/// More than one is genuinely useful, because a free account may only register ten
/// App IDs per week. When that runs out, a second Apple ID is the way to keep
/// going — so the list has to be manageable, not just visible.
class _AccountSection extends StatelessWidget {
  const _AccountSection({required this.vm});

  final SettingsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final AccountSelection accounts = context.watch<AccountSelection>();

    return SettingsSection(
      label: accounts.hasChoice ? 'APPLE IDS' : 'ACCOUNT',
      children: [
        if (vm.isAccountLoading && !accounts.hasLoaded)
          const SettingsBlock(
            child: SettingsLoadingLine(label: 'Checking session\u2026'),
          )
        else if (vm.hasAccountError)
          SettingsBlock(
            child: Text(vm.accountError!, style: context.t.bodyMuted),
          )
        else if (accounts.accounts.isEmpty)
          SettingsRow(
            title: 'Apple ID',
            description: 'Not signed in.',
            control: AppButton(
              label: 'Sign in',
              tone: ButtonTone.primary,
              onPressed: vm.signIn,
            ),
          )
        else ...[
          for (final AppleAccount account in accounts.accounts)
            SettingsRow(
              title: account.email,
              description: _describe(account, accounts),
              control: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!account.active)
                    AppButton(
                      label: 'Use',
                      onPressed: accounts.busyEmail != null
                          ? null
                          : () => accounts.use(account.email),
                    ),
                  if (!account.active) const SizedBox(width: Space.s2),
                  AppButton(
                    label: 'Sign out',
                    onPressed: accounts.busyEmail != null
                        ? null
                        : () => accounts.signOut(account.email),
                  ),
                ],
              ),
            ),
          SettingsRow(
            title: 'Add another Apple ID',
            description: 'Sign in again to keep both. Useful when one account has '
                'used up its ten App IDs for the week.',
            control: AppButton(
              label: 'Add',
              tone: ButtonTone.primary,
              onPressed: vm.signIn,
            ),
          ),
        ],
        if (accounts.hasError)
          SettingsBlock(
            child: Text(accounts.error!, style: context.t.bodyMuted),
          ),
      ],
    );
  }

  /// What to say under an address: its role, and its team once it has one.
  String _describe(AppleAccount account, AccountSelection accounts) {
    final String role = account.active
        ? 'Signs new sideloads'
        : 'Signed in, not in use';
    final String team = account.teamId == null ? '' : ' \u00b7 team ${account.teamId}';
    if (accounts.busyEmail == account.email) return 'Working\u2026';
    return '$role$team';
  }
}

/// Anisette: what makes the sign-in headers, and which services to try, in order.
///
/// The list is editable because a server you host yourself belongs in front of the public
/// ones: while it is up it is the only one that sees your requests, and when it is asleep
/// the public services behind it still answer. The engine validates and stores the
/// addresses, so what the card shows afterwards is what it accepted, not what was typed.
class _AnisetteSection extends StatefulWidget {
  const _AnisetteSection({required this.vm});

  final SettingsViewModel vm;

  @override
  State<_AnisetteSection> createState() => _AnisetteSectionState();
}

class _AnisetteSectionState extends State<_AnisetteSection> {
  final TextEditingController _controller = TextEditingController();

  SettingsViewModel get _vm => widget.vm;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final String address = _controller.text.trim();
    if (address.isEmpty) return;
    await _vm.addAnisetteServer(address);
    if (mounted && _vm.anisetteSaveError == null) _controller.clear();
  }

  /// A service on this PC: the only kind that keeps the requests off the network entirely.
  static bool _isLocalAddress(String url) {
    final String host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }

  Widget _serverLine(String address, int index, int count) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.s1),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 20,
            child: Text(
              '${index + 1}.',
              style: context.t.mono.copyWith(color: palette.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              address,
              style: context.t.mono.copyWith(fontSize: FontSizes.small),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (index == 0) ...<Widget>[
            const SizedBox(width: Space.s2),
            Text(
              'PRIMARY',
              style: context.t.caption.copyWith(color: palette.accent, letterSpacing: 0.6),
            ),
          ],
          GhostIconButton(
            icon: Icons.arrow_upward,
            tooltip: 'Try this one earlier',
            onPressed: index == 0 ? null : () => _vm.moveAnisetteServer(index, -1),
          ),
          GhostIconButton(
            icon: Icons.arrow_downward,
            tooltip: 'Try this one later',
            onPressed: index == count - 1 ? null : () => _vm.moveAnisetteServer(index, 1),
          ),
          GhostIconButton(
            icon: Icons.close,
            tooltip: 'Remove',
            danger: true,
            onPressed: () => _vm.removeAnisetteServerAt(index),
          ),
        ],
      ),
    );
  }

  Widget get _editor {
    final List<String> servers = _vm.anisetteServerList;
    return SettingsRow(
      title: 'Services',
      description: 'Tried in order: the first that answers is the one used, so a server that '
          'is asleep costs one timeout instead of the whole sign-in. Use https://, or http:// '
          'to this PC only.',
      control: SettingsValue(servers.isEmpty ? 'built-in' : '${servers.length}'),
      detail: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (servers.isEmpty)
            Text(
              "The engine's built-in Mac services are used. Add one to put your own first.",
              style: context.t.smallMuted,
            ),
          for (int i = 0; i < servers.length; i++)
            _serverLine(servers[i], i, servers.length),
          if (servers.isNotEmpty && !_isLocalAddress(servers.first)) ...<Widget>[
            const SizedBox(height: Space.s2),
            Text(
              'The first service is a public host: whoever runs it can see your IP address and '
              'the one-time passwords it hands out. Put a server you host yourself first if you '
              'have one.',
              style: context.t.smallMuted,
            ),
          ],
          const SizedBox(height: Space.s3),
          Row(
            children: <Widget>[
              Expanded(
                child: AppTextField(
                  controller: _controller,
                  hint: 'https://ani.example.com, or http://127.0.0.1:6969',
                  mono: true,
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: Space.s2),
              AppButton(
                label: 'Add',
                icon: Icons.add,
                compact: true,
                busy: _vm.isAnisetteSaving,
                onPressed: _add,
              ),
            ],
          ),
          const SizedBox(height: Space.s2),
          Wrap(
            spacing: Space.s2,
            runSpacing: Space.s2,
            children: <Widget>[
              AppButton(
                label: 'Use this PC',
                icon: Icons.computer,
                compact: true,
                onPressed: _vm.isAnisetteSaving
                    ? null
                    : () => _vm.addAnisetteServer('http://127.0.0.1:6969'),
              ),
              AppButton(
                label: 'Reset to built-in',
                icon: Icons.restart_alt,
                compact: true,
                busy: _vm.isAnisetteSaving,
                onPressed: _vm.isAnisetteSaving ? null : _vm.resetAnisetteServers,
              ),
            ],
          ),
          if (_vm.anisetteSaveError case final String message) ...<Widget>[
            const SizedBox(height: Space.s2),
            SettingsStatusLine(text: message, isError: true),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final SettingsViewModel vm = _vm;
    return SettingsSection(
      label: 'ANISETTE',
      children: <Widget>[
        if (vm.isAnisetteLoading)
          const SettingsBlock(child: SettingsLoadingLine(label: '\u2026'))
        else if (vm.hasAnisetteError)
          SettingsBlock(
            child: Text(vm.anisetteError!, style: context.t.bodyMuted),
          )
        else ...<Widget>[
          SettingsRow(
            title: 'Provider',
            control: SettingsValue(vm.anisetteProvider),
          ),
          _editor,
          SettingsRow(
            title: 'State',
            control: SettingsValue(vm.anisetteState),
          ),
          if (vm.anisetteIsRemote)
            SettingsBlock(
              child: Text(
                'Apple only accepts anisette made by its own macOS libraries, so EZSide '
                'gets it from a Mac service, as iloader, SideStore and xtool do. '
                'The service never receives your Apple ID, password, codes or tokens; it '
                'can see your IP address.',
                style: context.t.bodyMuted,
              ),
            ),
        ],
      ],
    );
  }
}

/// Updates: check, download-and-verify, then install on the user's click.
///
/// The install is never automatic. iPASide's releases are not code-signed, and a
/// checksum published in the same release as the installer proves integrity but
/// not authenticity — so the user always consents to running it.
class _UpdatesSection extends StatelessWidget {
  const _UpdatesSection();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<UpdateViewModel>();
    final pending = vm.pending;

    return SettingsSection(
      label: 'UPDATES',
      children: [
        SettingsRow(
          title: 'Installed',
          control: SettingsValue(vm.currentVersion),
        ),
        if (pending != null)
          SettingsRow(
            title: 'Downloaded',
            control: SettingsValue(
              '${pending.version}  \u00b7  '
              '${(pending.sizeBytes / (1 << 20)).round()} MB',
            ),
          ),
        SettingsBlock(child: _UpdateStatus(vm: vm)),
      ],
    );
  }
}

class _UpdateStatus extends StatelessWidget {
  const _UpdateStatus({required this.vm});

  final UpdateViewModel vm;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final message = vm.message;
    final lastChecked = vm.lastCheckedLabel;
    final hasStatus = message != null || lastChecked != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (vm.isDownloading) ...[
          AppProgressBar(value: vm.progress * 100),
          const SizedBox(height: Space.s3),
        ],
        if (message != null)
          Text(
            message,
            style: vm.isProblem
                ? context.t.small.copyWith(color: p.danger)
                : context.t.smallMuted,
          ),
        if (lastChecked != null)
          Padding(
            // Hangs off the status line above rather than floating free.
            padding: EdgeInsets.only(top: message == null ? 0 : Space.s1),
            child: Text(lastChecked, style: context.t.faint),
          ),
        if (!vm.hasLaunchedInstaller) ...[
          if (hasStatus) const SizedBox(height: Space.s3),
          Wrap(
            spacing: Space.s2,
            runSpacing: Space.s2,
            children: [
              if (vm.canInstall)
                AppButton(
                  label: 'Install now',
                  icon: Icons.download_rounded,
                  tone: ButtonTone.primary,
                  compact: true,
                  onPressed: vm.install,
                )
              else if (vm.canDownload)
                AppButton(
                  label: 'Download ${vm.latestVersion}',
                  icon: Icons.download_rounded,
                  tone: ButtonTone.primary,
                  compact: true,
                  onPressed: vm.download,
                ),
              if (vm.canDownload || vm.canInstall)
                AppButton(
                  label: 'See Changes',
                  compact: true,
                  onPressed: vm.seeChanges,
                ),
              AppButton(
                label: 'Check now',
                compact: true,
                busy: vm.isBusy,
                onPressed: vm.isBusy ? null : vm.check,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection({required this.vm});

  final SettingsViewModel vm;

  @override
  Widget build(BuildContext context) => SettingsSection(
        label: 'ABOUT',
        children: [
          const SettingsRow(title: 'App', control: SettingsValue('EZSide')),
          SettingsRow(
            title: 'Engine',
            control: SettingsValue(vm.engineVersionText),
          ),
          SettingsBlock(
            child: Text(
              'Free, open-source iOS sideloading.',
              style: context.t.smallMuted,
            ),
          ),
        ],
      );
}
