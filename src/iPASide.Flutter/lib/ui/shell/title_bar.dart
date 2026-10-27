import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/buttons.dart';
import 'logo_mark.dart';

/// Chromeless title bar: brand on the left, theme toggle and window controls
/// on the right. The brand strip drags the window; double-clicking it maximises.
class TitleBar extends StatefulWidget {
  const TitleBar({super.key, required this.isDark, required this.onToggleTheme});

  final bool isDark;
  final VoidCallback onToggleTheme;

  @override
  State<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<TitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximized() async {
    final value = await windowManager.isMaximized();
    if (mounted && value != _maximized) setState(() => _maximized = value);
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return SizedBox(
      height: Sizes.titleBar,
      child: Row(
        children: [
          // The drag area stops short of the caption buttons on purpose.
          // DragToMoveArea listens for a double-tap, and a double-tap
          // recogniser holds the gesture arena open for kDoubleTapTimeout, so
          // any button underneath it does not fire until 300ms after the
          // click. Windows itself does not let you drag a window by its
          // caption buttons either.
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: Pad.titleBarBrand,
                child: Row(
                  children: [
                    const LogoMark(size: Sizes.logoMark),
                    const SizedBox(width: Space.s3 - 2),
                    Text('iPASide', style: context.t.wordmark),
                    const SizedBox(width: Space.s3 - 2),
                    Container(
                      padding: Pad.chip,
                      decoration: BoxDecoration(
                        color: p.bg2,
                        borderRadius: Radii.rFull,
                        border: Border.all(color: p.hairline),
                      ),
                      child: Text('free & open-source', style: context.t.smallMuted),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: Pad.titleBarActions,
            child: Row(
              children: [
                GhostIconButton(
                  icon: widget.isDark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  tooltip: 'Toggle theme',
                  onPressed: widget.onToggleTheme,
                ),
                const SizedBox(width: Space.s2),
                GhostIconButton(
                  icon: Icons.remove,
                  tooltip: 'Minimize',
                  width: Sizes.captionButtonWidth,
                  height: Sizes.captionButtonHeight,
                  onPressed: windowManager.minimize,
                ),
                GhostIconButton(
                  icon: _maximized
                      ? Icons.filter_none_rounded
                      : Icons.crop_square_rounded,
                  tooltip: _maximized ? 'Restore' : 'Maximize',
                  width: Sizes.captionButtonWidth,
                  height: Sizes.captionButtonHeight,
                  onPressed: _toggleMaximize,
                ),
                GhostIconButton(
                  icon: Icons.close_rounded,
                  tooltip: 'Close',
                  danger: true,
                  width: Sizes.captionButtonWidth,
                  height: Sizes.captionButtonHeight,
                  onPressed: windowManager.close,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
