import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/ui/widgets/motion.dart';
import 'package:ipaside/ui/widgets/smooth_scroll.dart';

/// Taller than the 800x600 test viewport, so there is room to scroll.
const double _contentHeight = 4000;

/// One wheel notch, in the logical pixels a [PointerScrollEvent] carries.
const double _notch = 300;

/// Pumps a [SmoothScrollView] under the reduced-motion flag a real run carries,
/// optionally driven by a controller the caller owns.
Future<void> _pumpScrollView(
  WidgetTester tester, {
  bool reducedMotion = false,
  SmoothScrollController? controller,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: UiOptions(
        reducedMotion: reducedMotion,
        child: SmoothScrollView(
          controller: controller,
          child: const SizedBox(height: _contentHeight, width: 400),
        ),
      ),
    ),
  );
}

/// A controller disposed when the running test ends.
SmoothScrollController _controller({bool reducedMotion = false}) {
  final controller = SmoothScrollController(reducedMotion: reducedMotion);
  addTearDown(controller.dispose);
  return controller;
}

/// The live position, whichever controller ended up owning it.
ScrollPosition _positionOf(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable)).position;

/// A mouse parked over the scroll view, ready to send wheel notches.
TestPointer _wheelOver(WidgetTester tester) {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  pointer.hover(tester.getCenter(find.byType(SmoothScrollView)));
  return pointer;
}

void main() {
  group('wheel smoothing', () {
    testWidgets('a notch glides to the new offset instead of jumping', (tester) async {
      final controller = _controller();
      await _pumpScrollView(tester, controller: controller);
      final pointer = _wheelOver(tester);

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, _notch)));
      // The framework would have moved the whole way inside the event itself.
      expect(controller.offset, 0);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(controller.offset, greaterThan(0));
      expect(controller.offset, lessThan(_notch));

      await tester.pumpAndSettle();
      expect(controller.offset, _notch);
    });

    testWidgets('consecutive notches extend the target, not restart it', (tester) async {
      final controller = _controller();
      await _pumpScrollView(tester, controller: controller);
      final pointer = _wheelOver(tester);

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, _notch)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final double midway = controller.offset;
      expect(midway, greaterThan(0));
      expect(midway, lessThan(_notch));

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, _notch)));
      await tester.pumpAndSettle();
      // Measuring the second notch from the offset it was passing through would
      // have landed short of two full notches.
      expect(controller.offset, _notch * 2);
    });

    testWidgets('a notch mid-glide still travels through the frames', (tester) async {
      final controller = _controller();
      await _pumpScrollView(tester, controller: controller);
      final pointer = _wheelOver(tester);

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, _notch)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, _notch)));
      // The frame that starts a ticker only establishes its zero point, so the
      // travel shows up on the frame after it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      expect(controller.offset, greaterThan(_notch));
      expect(controller.offset, lessThan(_notch * 2));
    });

    testWidgets('the accumulated target clamps at the bottom extent', (tester) async {
      final controller = _controller();
      await _pumpScrollView(tester, controller: controller);
      final pointer = _wheelOver(tester);
      final double bottom = _positionOf(tester).maxScrollExtent;

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 2500)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 2500)));
      await tester.pumpAndSettle();

      expect(controller.offset, bottom);
    });

    testWidgets('the accumulated target clamps at the top extent', (tester) async {
      final controller = _controller();
      await _pumpScrollView(tester, controller: controller);
      final pointer = _wheelOver(tester);
      controller.jumpTo(_positionOf(tester).maxScrollExtent);

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -2500)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -2500)));
      await tester.pumpAndSettle();

      expect(controller.offset, 0);
    });

    testWidgets('a drag takes the position over from a glide', (tester) async {
      final controller = _controller();
      await _pumpScrollView(tester, controller: controller);
      final pointer = _wheelOver(tester);

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, _notch)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.drag(find.byType(SmoothScrollView), const Offset(0, -1000));
      await tester.pumpAndSettle();
      final double afterDrag = controller.offset;
      expect(afterDrag, greaterThan(_notch));

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, _notch)));
      await tester.pumpAndSettle();
      // A target left over from before the drag would have dragged the position
      // backwards to where the wheel had been heading.
      expect(controller.offset, afterDrag + _notch);
    });

    testWidgets('trackpad panning moves the position directly', (tester) async {
      await _pumpScrollView(tester);
      final position = _positionOf(tester);
      final Offset centre = tester.getCenter(find.byType(SmoothScrollView));
      final pointer = TestPointer(1, PointerDeviceKind.trackpad);

      await tester.sendEventToBinding(pointer.panZoomStart(centre));
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(centre, pan: const Offset(0, -_notch)),
      );
      // Panning is a drag, so it lands within the event rather than easing in.
      expect(position.pixels, _notch);

      await tester.sendEventToBinding(pointer.panZoomEnd());
      await tester.pumpAndSettle();
      expect(position.pixels, _notch);
    });
  });

  group('reduced motion', () {
    testWidgets('keeps the wheel instant', (tester) async {
      await _pumpScrollView(tester, reducedMotion: true);
      final position = _positionOf(tester);
      final pointer = _wheelOver(tester);

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, _notch)));
      expect(position.pixels, _notch);

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, _notch)));
      expect(position.pixels, _notch * 2);
    });

    testWidgets('is read from the tree for a controller of our own', (tester) async {
      await _pumpScrollView(tester);
      final position = _positionOf(tester);
      final pointer = _wheelOver(tester);

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, _notch)));
      expect(position.pixels, 0);

      await tester.pumpAndSettle();
      expect(position.pixels, _notch);
    });
  });

  group('SmoothScrollView', () {
    testWidgets('builds its own controller when none is supplied', (tester) async {
      await _pumpScrollView(tester);

      final scrollable = tester.widget<Scrollable>(find.byType(Scrollable));
      expect(scrollable.controller, isA<SmoothScrollController>());
    });

    testWidgets('leaves a supplied controller animatable', (tester) async {
      final controller = _controller();
      await _pumpScrollView(tester, controller: controller);

      // The sideload screen reveals its progress stepper this way while the
      // same controller is smoothing the wheel.
      controller.animateTo(
        _positionOf(tester).maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.offset, greaterThan(0));

      await tester.pumpAndSettle();
      expect(controller.offset, _positionOf(tester).maxScrollExtent);
    });

    testWidgets('passes its padding through to the scroll view', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: UiOptions(
            reducedMotion: false,
            child: SmoothScrollView(
              padding: EdgeInsets.all(24),
              child: SizedBox(height: _contentHeight, width: 400),
            ),
          ),
        ),
      );

      expect(
        tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView)).padding,
        const EdgeInsets.all(24),
      );
    });
  });
}
