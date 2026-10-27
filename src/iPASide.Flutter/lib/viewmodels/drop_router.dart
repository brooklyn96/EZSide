import 'dart:async';

import 'package:flutter/foundation.dart';
import '../ui/shell/nav_destination.dart';
import 'navigation_state.dart';
import 'sideload_view_model.dart';

/// Routes files dropped anywhere on the window and owns the drop veil's state.
///
/// An `.ipa` wins over tweaks in a mixed drop, and tweaks are only accepted
/// once an app is selected — there is nothing to inject them into otherwise.
/// Rejections flash a reason on the veil rather than failing silently.
class DropRouter extends ChangeNotifier {
  DropRouter({required this._navigation, required this._target});

  static const String defaultCue = 'Drop an .ipa, or a .deb/.dylib tweak';
  static const String tweaksBeforeIpaCue = 'Choose an app first, then drop tweaks';
  static const String noLocalPathCue =
      "Those files aren't on disk - use Choose instead";
  static const String busyCue = 'Sideload in progress - wait for it to finish';

  /// How long a rejection stays on screen.
  static const Duration rejectDuration = Duration(milliseconds: 1500);

  static const Set<String> _ipaExtensions = {'.ipa'};
  static const Set<String> _tweakExtensions = {'.deb', '.dylib'};

  final NavigationState _navigation;
  final SideloadViewModel _target;

  Timer? _rejectTimer;
  bool _isVeilVisible = false;
  String _veilText = defaultCue;
  bool _isReject = false;

  bool get isVeilVisible => _isVeilVisible;
  String get veilText => _veilText;
  bool get isReject => _isReject;

  void onDragEnter() {
    _rejectTimer?.cancel();
    _isVeilVisible = true;
    _isReject = false;
    _veilText = defaultCue;
    notifyListeners();
  }

  void onDragLeave() {
    if (_isReject) return; // let a rejection finish showing
    _hide();
  }

  Future<void> onDrop(List<String> paths) async {
    // A run cannot be cancelled, so neither a new app nor extra tweaks can be
    // accepted while one is in flight - say so rather than dropping it silently.
    if (_target.isRunning) {
      _reject(busyCue);
      return;
    }

    final usable = [for (final p in paths) if (p.trim().isNotEmpty) p];
    if (usable.isEmpty) {
      _reject(noLocalPathCue);
      return;
    }

    final ipas = [for (final p in usable) if (_hasExtension(p, _ipaExtensions)) p];
    if (ipas.isNotEmpty) {
      _hide();
      _goToSideload();
      await _target.loadIpa(ipas.first); // first IPA wins
      return;
    }

    final tweaks = [for (final p in usable) if (_hasExtension(p, _tweakExtensions)) p];
    if (tweaks.isNotEmpty) {
      if (!_target.hasIpa) {
        _reject(tweaksBeforeIpaCue);
        return;
      }
      _hide();
      _goToSideload();
      _target.openAdvanced();
      await _target.addTweaks(tweaks);
      return;
    }

    _reject(defaultCue);
  }

  void _goToSideload() {
    if (_navigation.current != NavKey.sideload) {
      _navigation.navigateTo(NavKey.sideload);
    }
  }

  void _reject(String cue) {
    _rejectTimer?.cancel();
    _isVeilVisible = true;
    _isReject = true;
    _veilText = cue;
    notifyListeners();
    _rejectTimer = Timer(rejectDuration, _hide);
  }

  void _hide() {
    _rejectTimer?.cancel();
    _rejectTimer = null;
    if (!_isVeilVisible && !_isReject) return;
    _isVeilVisible = false;
    _isReject = false;
    _veilText = defaultCue;
    notifyListeners();
  }

  static bool _hasExtension(String path, Set<String> extensions) {
    final lower = path.toLowerCase();
    return extensions.any(lower.endsWith);
  }

  @override
  void dispose() {
    _rejectTimer?.cancel();
    super.dispose();
  }
}
