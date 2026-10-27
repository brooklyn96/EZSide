import 'package:flutter/material.dart';

/// The app's screens. [wireName] matches the navigation keys used by the
/// previous build, so `IPASIDE_STARTUP_QUERY=view=sideload` keeps working.
enum NavKey {
  home('home'),
  signIn('signin'),
  sideload('sideload'),
  library('library'),
  apps('apps'),
  liveContainer('livecontainer'),
  account('account'),
  diagnostics('diagnostics'),
  settings('settings');

  const NavKey(this.wireName);

  final String wireName;

  static NavKey? fromWireName(String? name) {
    if (name == null) return null;
    for (final key in values) {
      if (key.wireName == name) return key;
    }
    return null;
  }
}

/// A sidebar entry. Sign-in is deliberately absent — it is reached only by
/// navigating from Home, Settings, or a sideload pre-flight check.
class NavDestination {
  const NavDestination(this.key, this.label, this.icon);

  final NavKey key;
  final String label;
  final IconData icon;

  static const sidebar = <NavDestination>[
    NavDestination(NavKey.home, 'Home', Icons.home_outlined),
    NavDestination(NavKey.sideload, 'Sideload', Icons.inventory_2_outlined),
    NavDestination(NavKey.library, 'Library', Icons.collections_bookmark_outlined),
    NavDestination(NavKey.apps, 'Apps', Icons.grid_view_rounded),
    NavDestination(NavKey.liveContainer, 'LiveContainer', Icons.layers_outlined),
    NavDestination(NavKey.account, 'Account', Icons.badge_outlined),
    NavDestination(NavKey.diagnostics, 'Diagnostics', Icons.monitor_heart_outlined),
    NavDestination(NavKey.settings, 'Settings', Icons.settings_outlined),
  ];
}
