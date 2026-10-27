import 'package:flutter/foundation.dart';
import '../ui/shell/nav_destination.dart';

/// Which screen is showing, and a token that forces a screen to be rebuilt.
///
/// The Avalonia build resolved a fresh (transient) view model on every
/// navigation, so re-navigating to the screen you are already on re-ran its
/// loads — sign-out relies on that to refresh Home. [epoch] reproduces it:
/// pages are keyed by `(destination, epoch)`, so any navigate call remounts
/// the screen. The Sideload view model is long-lived and keeps its session
/// regardless.
class NavigationState extends ChangeNotifier {
  NavKey _current = NavKey.home;
  int _epoch = 0;

  NavKey get current => _current;

  /// Bumped on every navigation, including to the current destination.
  int get epoch => _epoch;

  /// The sidebar entry to highlight; null on screens absent from the sidebar
  /// (sign-in), which clears the selection.
  NavKey? get sidebarSelection =>
      NavDestination.sidebar.any((d) => d.key == _current) ? _current : null;

  void navigateTo(NavKey key) {
    _current = key;
    _epoch++;
    notifyListeners();
  }
}
