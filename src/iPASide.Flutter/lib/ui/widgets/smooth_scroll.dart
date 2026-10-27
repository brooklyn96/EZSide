import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../theme/app_theme.dart';
import 'motion.dart';

/// Drives a wheel notch to its target offset without freezing the pointer.
///
/// [DrivenScrollActivity] ignores pointer events for as long as it runs, which
/// would cost the app hover state and clicks for a moment after every notch.
/// The framework moves the offset with no activity at all here, so staying out
/// of the pointer's way is what preserves the behaviour being replaced.
class _WheelScrollActivity extends DrivenScrollActivity {
  _WheelScrollActivity(
    super.delegate, {
    required super.from,
    required super.to,
    required super.duration,
    required super.curve,
    required super.vsync,
  });

  @override
  bool get shouldIgnorePointer => false;
}

/// A scroll position that glides to the new offset on mouse-wheel input.
///
/// [ScrollPositionWithSingleContext.pointerScroll] assigns the target offset
/// with `forcePixels`, so every notch teleports. Drag, fling, keyboard,
/// scrollbar and trackpad panning all run through other paths that already
/// animate, and are left untouched.
class SmoothScrollPosition extends ScrollPositionWithSingleContext {
  /// Creates a position that smooths wheel input unless [reducedMotion] is set.
  SmoothScrollPosition({
    required super.physics,
    required super.context,
    required this.reducedMotion,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  /// When set, wheel input keeps the framework's instant behaviour.
  final bool reducedMotion;

  /// Where the running wheel animation is headed, or null when none is.
  double? _target;

  /// The activity moving towards [_target]; any other activity supersedes it.
  ScrollActivity? _wheelActivity;

  @override
  void pointerScroll(double delta) {
    // A zero delta is how trackpad inertia is cancelled, not a scroll; the
    // framework settles the position for it, which is right either way.
    if (reducedMotion || delta == 0.0) {
      super.pointerScroll(delta);
      return;
    }

    // Consecutive notches extend the target the animation is already heading
    // for. Measuring from `pixels` instead would let each notch swallow the
    // travel the previous one had not covered yet, so a fast scroll would both
    // lag the wheel and stutter.
    final double from = _target ?? pixels;
    final double target = math.min(
      math.max(from + delta, minScrollExtent),
      maxScrollExtent,
    );
    // No travel left: either pinned at an extent, or already heading here.
    if (target == from) return;

    updateUserScrollDirection(
      -delta > 0.0 ? ScrollDirection.forward : ScrollDirection.reverse,
    );

    final activity = _WheelScrollActivity(
      this,
      from: pixels,
      to: target,
      duration: Motion.wheel,
      curve: Motion.curve,
      vsync: context.vsync,
    );
    _target = target;
    _wheelActivity = activity;
    beginActivity(activity);
  }

  @override
  void beginActivity(ScrollActivity? newActivity) {
    // Anything other than the activity just started owns the position from here
    // — a drag the user began, a fling, an `animateTo`, or the idle activity
    // that follows the target being reached — so the accumulated target goes.
    // A null activity is documented as a no-op and must not clear it.
    if (newActivity != null && newActivity != _wheelActivity) {
      _wheelActivity = null;
      _target = null;
    }
    super.beginActivity(newActivity);
  }
}

/// A [ScrollController] whose positions glide on mouse-wheel input.
///
/// [reducedMotion] is supplied here rather than read from the tree because a
/// [ScrollPosition] has no [BuildContext] to reach [UiOptions] through.
class SmoothScrollController extends ScrollController {
  /// Creates a controller; pass `UiOptions.reducedMotionOf(context)`.
  SmoothScrollController({
    required this.reducedMotion,
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
    super.onAttach,
    super.onDetach,
  });

  /// When set, wheel input keeps the framework's instant behaviour.
  final bool reducedMotion;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return SmoothScrollPosition(
      physics: physics,
      context: context,
      reducedMotion: reducedMotion,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

/// A [SingleChildScrollView] driven by a [SmoothScrollController], so that the
/// mouse wheel glides to the new offset instead of jumping to it.
class SmoothScrollView extends StatefulWidget {
  const SmoothScrollView({
    super.key,
    required this.child,
    this.padding,
    this.controller,
  });

  final Widget child;

  /// Inset around [child], as [SingleChildScrollView.padding].
  final EdgeInsetsGeometry? padding;

  /// A controller to use in place of the one this widget would create, for
  /// screens that also scroll programmatically. It stays its owner's to
  /// dispose.
  final SmoothScrollController? controller;

  @override
  State<SmoothScrollView> createState() => _SmoothScrollViewState();
}

class _SmoothScrollViewState extends State<SmoothScrollView> {
  /// Created only when the caller supplied no controller of its own.
  SmoothScrollController? _internal;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureController();
  }

  @override
  void didUpdateWidget(SmoothScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureController();
  }

  @override
  void dispose() {
    _internal?.dispose();
    super.dispose();
  }

  /// Reduced motion is read from the OS once at startup, so the flag is sampled
  /// on the first dependency pass and the controller is never rebuilt — the
  /// same trade [Entrance] makes.
  void _ensureController() {
    if (widget.controller != null || _internal != null) return;
    _internal = SmoothScrollController(
      reducedMotion: UiOptions.reducedMotionOf(context),
    );
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        controller: widget.controller ?? _internal,
        padding: widget.padding,
        child: widget.child,
      );
}
