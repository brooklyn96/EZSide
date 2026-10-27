import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'progress.dart';
import 'surfaces.dart';

/// A full-width group of settings rows under one heading.
///
/// The Settings screen is one column of these rather than a grid of cards, for
/// the reason every desktop settings UI is: rows stacked in a column never have
/// to agree about their height, so a setting carrying three lines of explanation
/// can sit above one carrying a bare toggle without either leaving a hole.
///
/// The header and every child are separated by a full-bleed rule, so the
/// vertical rhythm belongs to the section rather than to each child.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.label,
    required this.children,
  });

  /// Uppercase group heading, e.g. `APPEARANCE`.
  final String label;

  /// The rows, normally [SettingsRow]s and [SettingsBlock]s. Read-only.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => AppCard(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: Pad.settingsHeader, child: SectionLabel(label)),
            for (final Widget child in children) ...[
              const SettingsDivider(),
              child,
            ],
          ],
        ),
      );
}

/// The full-bleed rule between a section's rows.
class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key});

  @override
  Widget build(BuildContext context) =>
      Container(height: Sizes.hairline, color: context.palette.hairline);
}

/// One setting: what it is on the left, the control that changes it on the
/// right.
///
/// [control] is top-aligned with [title] rather than centred on the whole left
/// column, so a row that explains itself over three lines puts its control in
/// the same place as a row that needs no explanation at all — which is what
/// keeps a column of these reading straight down the right edge whatever is in
/// them.
///
/// [detail] carries what belongs to the row but not beside it: a confirmation
/// line, a progress bar, a path too long to sit in a control.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.description,
    this.control,
    this.detail,
  });

  final String title;

  /// The honest explanation, including what the choice costs where it costs
  /// something. Wraps freely; nothing here has to fit on one line.
  final String? description;

  /// The control that changes this setting, at the row's right edge.
  final Widget? control;

  /// Full-width content below the label and control.
  final Widget? detail;

  @override
  Widget build(BuildContext context) => Padding(
        padding: Pad.settingsRow,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: context.t.semi(FontSizes.body)),
                      if (description case final String text) ...[
                        const SizedBox(height: Space.s1),
                        Text(text, style: context.t.smallMuted),
                      ],
                    ],
                  ),
                ),
                if (control case final Widget widget) ...[
                  const SizedBox(width: Space.s5),
                  widget,
                ],
              ],
            ),
            if (detail case final Widget widget) ...[
              const SizedBox(height: Space.s3),
              widget,
            ],
          ],
        ),
      );
}

/// A settings row that is not a label/control pair: a loading line, a failure, a
/// group of buttons, a paragraph.
///
/// Carries the same padding as a [SettingsRow], so mixing the two never breaks
/// the section's rhythm.
class SettingsBlock extends StatelessWidget {
  const SettingsBlock({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: Pad.settingsRow, child: child);
}

/// A read-only value sitting where a [SettingsRow]'s control would be.
class SettingsValue extends StatelessWidget {
  const SettingsValue(this.text, {super.key, this.mono = false});

  final String text;

  /// Renders in the monospaced face, for a path or an identifier.
  final bool mono;

  @override
  Widget build(BuildContext context) => Text(
        text,
        textAlign: TextAlign.right,
        style: mono ? context.t.mono : context.t.small,
      );
}

/// A one-line outcome under a settings row: what a change did, or why it did
/// not happen.
class SettingsStatusLine extends StatelessWidget {
  const SettingsStatusLine({
    super.key,
    required this.text,
    this.isError = false,
  });

  final String text;

  /// Colours the line as a failure rather than a confirmation.
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Text(
      text,
      style: context.t.body.copyWith(color: isError ? p.danger : p.success),
    );
  }
}

/// Spinner plus label, for a section still waiting on the engine.
///
/// Kept as its own name because that is what a section reads as at the call site,
/// but the treatment is the app-wide [LoadingLine] so every wait looks the same.
class SettingsLoadingLine extends StatelessWidget {
  const SettingsLoadingLine({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => LoadingLine(label: label);
}
