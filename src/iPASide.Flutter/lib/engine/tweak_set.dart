// Ported from iPASide.App/Engine/TweakSet.cs.

import 'models.dart';

/// De-duplication for resolved tweak dylibs, verbatim from the web UI: a dylib
/// is added only when no existing entry shares its [TweakDylib.path]. Incoming
/// duplicates are collapsed too, and order is preserved.
abstract final class TweakSet {
  /// Returns [existing] followed by every dylib in [incoming] whose path is not
  /// already present, keeping the first occurrence of each path.
  ///
  /// Entries with a null path are always dropped from [incoming] (there is
  /// nothing to inject and nothing to compare), while existing entries are kept
  /// exactly as they are.
  static List<TweakDylib> mergeDistinctByPath(
    Iterable<TweakDylib> existing,
    Iterable<TweakDylib> incoming,
  ) {
    final List<TweakDylib> result = <TweakDylib>[];
    final Set<String> seen = <String>{};

    for (final TweakDylib dylib in existing) {
      result.add(dylib);
      final String? path = dylib.path;
      if (path != null) {
        seen.add(path);
      }
    }

    for (final TweakDylib dylib in incoming) {
      final String? path = dylib.path;
      if (path != null && seen.add(path)) {
        result.add(dylib);
      }
    }

    return result;
  }
}
