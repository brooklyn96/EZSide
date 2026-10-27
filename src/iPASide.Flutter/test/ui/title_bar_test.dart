import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/ui/shell/title_bar.dart';
import 'package:ipaside/ui/theme/app_theme.dart';
import 'package:ipaside/ui/widgets/buttons.dart';
import 'package:window_manager/window_manager.dart';

/// The plugin's method channel, stubbed so the bar can be built off Windows.
const MethodChannel _windowManager = MethodChannel('window_manager');

/// Pumps the bar and returns the window_manager calls it makes.
Future<List<String>> _pumpTitleBar(WidgetTester tester) async {
  final List<String> calls = <String>[];
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_windowManager, (MethodCall call) async {
    calls.add(call.method);
    return call.method == 'isMaximized' ? false : null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_windowManager, null));

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: TitleBar(isDark: true, onToggleTheme: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
  calls.clear();
  return calls;
}

Finder _captionButton(String tooltip) => find.ancestor(
      of: find.byTooltip(tooltip),
      matching: find.byType(GhostIconButton),
    );

void main() {
  group('TitleBar caption buttons', () {
    // A double-tap recogniser holds the gesture arena open for
    // kDoubleTapTimeout, so a button underneath DragToMoveArea does not fire
    // until 300ms after the click. That was the whole of the minimise delay.
    for (final String tooltip in <String>['Minimize', 'Maximize', 'Close']) {
      testWidgets('$tooltip is outside the drag area', (tester) async {
        await _pumpTitleBar(tester);

        expect(
          find.ancestor(
            of: _captionButton(tooltip),
            matching: find.byType(DragToMoveArea),
          ),
          findsNothing,
        );
      });
    }

    testWidgets('no caption button sits under a double-tap recogniser',
        (tester) async {
      await _pumpTitleBar(tester);

      for (final String tooltip in <String>['Minimize', 'Maximize', 'Close']) {
        final Iterable<GestureDetector> above = tester.widgetList<GestureDetector>(
          find.ancestor(
            of: _captionButton(tooltip),
            matching: find.byType(GestureDetector),
          ),
        );
        expect(
          above.where((GestureDetector d) => d.onDoubleTap != null),
          isEmpty,
          reason: '$tooltip would be delayed by kDoubleTapTimeout',
        );
      }
    });

    testWidgets('minimising reaches the plugin on the first frame after the tap',
        (tester) async {
      final List<String> calls = await _pumpTitleBar(tester);

      await tester.tap(_captionButton('Minimize'));
      await tester.pump();

      expect(calls, contains('minimize'));
    });

    testWidgets('closing reaches the plugin on the first frame after the tap',
        (tester) async {
      final List<String> calls = await _pumpTitleBar(tester);

      await tester.tap(_captionButton('Close'));
      await tester.pump();

      expect(calls, contains('close'));
    });
  });

  group('TitleBar drag area', () {
    testWidgets('still covers the brand strip', (tester) async {
      await _pumpTitleBar(tester);

      expect(find.byType(DragToMoveArea), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(DragToMoveArea),
          matching: find.text('iPASide'),
        ),
        findsOneWidget,
      );
    });
  });
}
