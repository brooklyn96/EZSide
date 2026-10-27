import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/surfaces.dart';

/// Full-window overlay shown while files are dragged over the app.
///
/// Accepting shows the box glyph; rejecting swaps to an alert glyph and the
/// danger tint, and the caller clears it after a moment.
class DropVeil extends StatelessWidget {
  const DropVeil({
    super.key,
    required this.visible,
    required this.text,
    required this.isReject,
  });

  final bool visible;
  final String text;
  final bool isReject;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final tint = isReject ? p.danger : p.accent;

    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: Motion.base,
        curve: Motion.curve,
        child: Container(
          color: p.scrim,
          alignment: Alignment.center,
          child: AnimatedScale(
            scale: visible ? 1 : 0.97,
            duration: Motion.base,
            curve: Motion.curve,
            child: Container(
              margin: const EdgeInsets.all(Space.s8),
              decoration: BoxDecoration(
                gradient: p.cardGradient,
                borderRadius: Radii.rLarge,
                boxShadow: p.liftShadow,
              ),
              // The dashed outline has to wrap the padding, not sit inside it:
              // as a child of the padded box it was drawn around the content
              // itself and cut straight through the icon and the label.
              child: CustomPaint(
                painter: DashedBorderPainter(color: tint, radius: Radii.large - 4, inset: 10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.s8 + Space.s6,
                    vertical: Space.s8,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isReject
                            ? Icons.error_outline_rounded
                            : Icons.inventory_2_outlined,
                        size: Sizes.iconXl,
                        color: tint,
                      ),
                      const SizedBox(height: Space.s4),
                      Text(
                        text,
                        textAlign: TextAlign.center,
                        style: context.t.semi(FontSizes.body + 0.5),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
