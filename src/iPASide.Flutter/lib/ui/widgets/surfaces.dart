import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'motion.dart';

/// Floating gradient surface — the app's primary container.
///
/// Pass [onTap] (or set [interactive]) to get the hover lift used by tiles and
/// list rows.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = Pad.cardLarge,
    this.gradient,
    this.borderColor,
    this.interactive = false,
    this.onTap,
    this.shadow = true,
  });

  final Widget child;
  final EdgeInsets padding;
  final Gradient? gradient;
  final Color? borderColor;
  final bool interactive;
  final VoidCallback? onTap;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    if (!interactive && onTap == null) return _surface(context, false);
    return Hoverable(
      onTap: onTap,
      builder: (hovered, _) => _surface(context, hovered),
    );
  }

  Widget _surface(BuildContext context, bool hovered) {
    final p = context.palette;
    return AnimatedContainer(
      duration: Motion.base,
      curve: Motion.curve,
      transform: Matrix4.translationValues(0, hovered ? -3 : 0, 0),
      padding: padding,
      decoration: BoxDecoration(
        gradient: gradient ?? (hovered ? p.cardHoverGradient : p.cardGradient),
        borderRadius: Radii.rLarge,
        border: Border.all(color: borderColor ?? (hovered ? p.cardBorderHover : p.cardBorder)),
        boxShadow: !shadow
            ? const []
            : (hovered ? p.liftShadow : p.cardShadow),
      ),
      child: child,
    );
  }
}

/// Uppercase section label (`STATUS`, `QUICK ACTIONS`, …).
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: context.t.caption);
}

/// One card in a row of peers: heading at the top, substance under it, and the
/// card's action or verdict pinned to the bottom.
///
/// A row of these is laid out with `IntrinsicHeight` and
/// [CrossAxisAlignment.stretch], so all of them are as tall as the tallest — and
/// that is the point of the [footer]. Equal height is right for peers, but it
/// means every card except the tall one has spare room; left to themselves they
/// all pin their content to the top and the spare room becomes a hole under it.
/// Sending the footer to the bottom instead gives that room a purpose: the
/// actions line up with each other along the bottom edge of the row, which is
/// what makes three cards read as one row rather than three unrelated boxes.
///
/// [MainAxisAlignment.spaceBetween] does the pinning rather than a [Spacer],
/// because a Spacer has flex and throws when the height is unbounded — this way
/// the same card is safe on its own, where it simply sizes to its content.
class StatusCard extends StatelessWidget {
  const StatusCard({
    super.key,
    required this.label,
    required this.child,
    this.footer,
  });

  /// Uppercase heading, e.g. `DEVICE`.
  final String label;

  /// The card's substance, directly under the heading.
  final Widget child;

  /// What the card lets you do about it, or its verdict — held at the bottom.
  ///
  /// Null for a card that has neither, which is then simply top-aligned; the
  /// tallest card in a row is usually that one, because it is tall precisely
  /// because it is all substance.
  final Widget? footer;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionLabel(label),
                const SizedBox(height: Space.s3),
                child,
              ],
            ),
            if (footer case final Widget widget)
              Padding(
                padding: const EdgeInsets.only(top: Space.s4),
                child: widget,
              ),
          ],
        ),
      );
}

enum AlertKind { success, warning, danger, info }

/// Inline status banner with an icon, optional bold title, and body content.
class Alert extends StatelessWidget {
  const Alert({
    super.key,
    required this.kind,
    this.title,
    this.message,
    this.body,
    this.trailing,
  }) : assert(message == null || body == null, 'provide either message or body');

  final AlertKind kind;
  final String? title;
  final String? message;

  /// Rich alternative to [message], for text with emphasised runs.
  final Widget? body;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (Color fg, Color bg, IconData icon) = switch (kind) {
      AlertKind.success => (p.success, p.successBg, Icons.check_circle_rounded),
      AlertKind.warning => (p.warning, p.warningBg, Icons.warning_amber_rounded),
      AlertKind.danger => (p.danger, p.dangerBg, Icons.error_outline_rounded),
      AlertKind.info => (p.accent, p.accentSubtle, Icons.info_outline_rounded),
    };

    return Container(
      padding: Pad.alert,
      decoration: BoxDecoration(color: bg, borderRadius: Radii.rMedium),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: Sizes.icon, color: fg),
          ),
          const SizedBox(width: Space.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Text(title!, style: context.t.semi(FontSizes.body).copyWith(color: fg)),
                if (title != null && (message != null || body != null))
                  const SizedBox(height: Space.s1),
                if (message != null) Text(message!, style: context.t.small),
                ?body,
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: Space.s3),
            trailing!,
          ],
        ],
      ),
    );
  }
}

enum PillKind { ok, warn, danger, neutral }

/// Small status capsule (expiry countdown, "connected", …).
class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, this.kind = PillKind.neutral, this.icon});

  final String label;
  final PillKind kind;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (Color fg, Color bg) = switch (kind) {
      PillKind.ok => (p.success, p.successBg),
      PillKind.warn => (p.warning, p.warningBg),
      PillKind.danger => (p.danger, p.dangerBg),
      PillKind.neutral => (p.textSecondary, p.bg2),
    };

    return Container(
      padding: Pad.chip,
      decoration: BoxDecoration(color: bg, borderRadius: Radii.rFull),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: Space.s1 + 1),
          ],
          Text(
            label,
            style: context.t.small.copyWith(color: fg, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Neutral outlined chip used for IPA metadata.
class MetaChip extends StatelessWidget {
  const MetaChip(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: Pad.chip,
      decoration: BoxDecoration(
        color: p.bg2,
        borderRadius: Radii.rFull,
        border: Border.all(color: p.hairline),
      ),
      child: Text(label, style: context.t.smallMuted),
    );
  }
}

/// Small filled circle used for the engine status in the sidebar footer.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = Sizes.statusDot});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

/// Label/value row used inside the status cards.
///
/// The VALUE gets the leftover width, not the label. The label is one short fixed
/// word (`Name`, `iOS`) that says nothing the reader does not already expect; the
/// value is the fact they came for. Giving the label the flexible half instead
/// meant a device called `iOS_hAT's iPhone` was shown as `iOS_hAT's iP…` beside
/// four columns of unused space — so the row spent its width on the constant and
/// truncated the variable.
class KeyValueRow extends StatelessWidget {
  const KeyValueRow(this.label, this.value, {super.key, this.mono = false});

  final String label;

  /// The fact this row exists to show. Ellipsised only if it genuinely will not
  /// fit once it has the whole row minus the label.
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) => Padding(
        padding: Pad.statusRow,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: context.t.smallMuted),
            const SizedBox(width: Space.s3),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: mono ? context.t.mono : context.t.small,
              ),
            ),
          ],
        ),
      );
}

/// Centred icon + title + subtitle for empty lists.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.s8),
        child: Column(
          children: [
            Icon(icon, size: Sizes.iconXl, color: context.palette.textMuted),
            const SizedBox(height: Space.s4),
            Text(title, style: context.t.semi(FontSizes.body)),
            const SizedBox(height: Space.s1 + 2),
            Text(subtitle, style: context.t.smallMuted, textAlign: TextAlign.center),
          ],
        ),
      );
}

/// Dashed drop target for choosing an `.ipa`.
class Dropzone extends StatelessWidget {
  const Dropzone({
    super.key,
    required this.child,
    this.onTap,
    this.minHeight = 150,
    this.active = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double minHeight;

  /// Highlighted while a compatible file is being dragged over the window.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Hoverable(
      onTap: onTap,
      pressScale: 0.995,
      builder: (hovered, _) {
        final lit = hovered || active;
        return AnimatedContainer(
          duration: Motion.base,
          curve: Motion.curve,
          constraints: BoxConstraints(minHeight: minHeight),
          decoration: BoxDecoration(
            gradient: lit ? p.cardHoverGradient : p.cardGradient,
            borderRadius: Radii.rLarge,
            boxShadow: lit ? p.liftShadow : p.cardShadow,
          ),
          child: CustomPaint(
            painter: DashedBorderPainter(
              color: lit ? p.accent : p.hairlineStrong,
              radius: Radii.large - 3,
              inset: 10,
            ),
            child: Padding(padding: Pad.dropzone, child: Center(child: child)),
          ),
        );
      },
    );
  }
}

/// Rounded dashed outline, inset from the surface edge.
class DashedBorderPainter extends CustomPainter {
  const DashedBorderPainter({
    required this.color,
    this.radius = 11,
    this.inset = 10,
    this.dash = 7,
    this.gap = 5,
    this.strokeWidth = 1.3,
  });

  final Color color;
  final double radius;
  final double inset;
  final double dash;
  final double gap;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= inset * 2 || size.height <= inset * 2) return;

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(inset, inset, size.width - inset * 2, size.height - inset * 2),
      Radius.circular(radius),
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    for (final metric in (Path()..addRRect(rect)).computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant DashedBorderPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.inset != inset ||
      old.dash != dash ||
      old.gap != gap ||
      old.strokeWidth != strokeWidth;
}
