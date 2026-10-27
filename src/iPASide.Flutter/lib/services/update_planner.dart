import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Why an update check ended the way it did. Every branch is explicit so the UI
/// can say something true rather than "something went wrong".
enum UpdateOutcome {
  /// No release info, or the latest release is not newer than what is running.
  upToDate,

  /// A newer release exists but nothing has been downloaded yet. The startup
  /// check stops here: pulling ~100 MB unasked would be rude.
  updateAvailable,

  /// The release has no installer asset.
  noSetupAsset,

  /// The release publishes no `SHA256SUMS.txt` — refused. Fail-closed: nothing
  /// unverifiable is ever handed to the user as an installer.
  noChecksums,

  /// The download's SHA-256 did not match the published checksum for its name.
  checksumMismatch,

  /// Verified and staged on disk, waiting for the user to install it.
  readyToInstall,

  /// Network or IO trouble. Never fatal; the app keeps working and retries later.
  error,
}

/// A parsed GitHub "latest release": the tag plus the two assets that matter.
@immutable
class ReleaseInfo {
  const ReleaseInfo({
    this.tag,
    this.htmlUrl,
    this.setupUrl,
    this.setupName,
    this.sumsUrl,
  });

  final String? tag;

  /// The release's own GitHub page (`html_url`), for a "See Changes" link.
  final String? htmlUrl;

  final String? setupUrl;
  final String? setupName;
  final String? sumsUrl;
}

/// A verified installer sitting on disk, waiting for one click.
@immutable
class PendingUpdate {
  const PendingUpdate({
    required this.version,
    required this.setupPath,
    required this.sizeBytes,
  });

  final String version;
  final String setupPath;
  final int sizeBytes;
}

/// A three-part version, tolerant of `v` prefixes and pre-release suffixes.
@immutable
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  /// Parses `1.2.3`, `v1.2.3`, `1.2.3-rc1`, `1.2.3+5`.
  ///
  /// At least a major and minor part are required, matching .NET's
  /// `Version.TryParse`, so a bare `v1` is rejected rather than silently
  /// becoming 1.0.0 and comparing wrong.
  static AppVersion? tryParse(String? raw) {
    if (raw == null) return null;
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);
    text = text.split(RegExp(r'[-+]')).first;

    final parts = text.split('.');
    if (parts.length < 2) return null;

    final numbers = <int>[];
    for (var i = 0; i < 3; i++) {
      if (i >= parts.length) {
        numbers.add(0);
        continue;
      }
      final value = int.tryParse(parts[i]);
      if (value == null) return null;
      numbers.add(value < 0 ? 0 : value);
    }
    return AppVersion(numbers[0], numbers[1], numbers[2]);
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;
  bool operator >=(AppVersion other) => compareTo(other) >= 0;
  bool operator <(AppVersion other) => compareTo(other) < 0;
  bool operator <=(AppVersion other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// The side-effect-free half of the updater: parse a release, pick assets, and
/// verify a checksum. Kept separate from the service that does network and
/// process IO so every refusal path is unit-testable.
abstract final class UpdatePlanner {
  /// Pulls the tag and the installer / checksum asset URLs out of GitHub's
  /// "latest release" JSON, preferring the asset that matches [arch].
  ///
  /// A release may eventually carry both an x64 and an arm64 installer; an ARM
  /// machine prefers the arm64 asset, everything else the plain one.
  static ReleaseInfo parseRelease(String json, {String arch = 'x64'}) {
    final Object? decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return const ReleaseInfo();

    final tag = decoded['tag_name'] is String ? decoded['tag_name'] as String : null;
    final htmlUrl =
        decoded['html_url'] is String ? decoded['html_url'] as String : null;
    final setups = <({String name, String url})>[];
    String? sumsUrl;

    final assets = decoded['assets'];
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map<String, dynamic>) continue;
        final name = asset['name'];
        final url = asset['browser_download_url'];
        if (name is! String || url is! String) continue;

        final lower = name.toLowerCase();
        if (lower.endsWith('.exe') && lower.contains('setup')) {
          setups.add((name: name, url: url));
        } else if (lower == 'sha256sums.txt') {
          sumsUrl = url;
        }
      }
    }

    final chosen = _pickSetup(setups, arch);
    return ReleaseInfo(
      tag: tag,
      htmlUrl: htmlUrl,
      setupUrl: chosen?.url,
      setupName: chosen?.name,
      sumsUrl: sumsUrl,
    );
  }

  static ({String name, String url})? _pickSetup(
    List<({String name, String url})> setups,
    String arch,
  ) {
    if (setups.isEmpty) return null;
    bool isArm(String name) => name.toLowerCase().contains('arm64');

    if (arch.toLowerCase() == 'arm64') {
      for (final setup in setups) {
        if (isArm(setup.name)) return setup;
      }
    }
    for (final setup in setups) {
      if (!isArm(setup.name)) return setup;
    }
    return setups.first;
  }

  /// Whether [sumsText] vouches for [fileName] with [actualHashHex].
  ///
  /// Matching is by FILENAME, never "some line has this hash": a checksum list
  /// has to vouch for *this* file by name, so a hash that happens to sit next
  /// to a different filename never counts. Accepts both the `<hex>  name` and
  /// binary-mode `<hex> *name` shapes.
  static bool checksumMatches(String sumsText, String fileName, String actualHashHex) {
    if (sumsText.trim().isEmpty ||
        fileName.trim().isEmpty ||
        actualHashHex.trim().isEmpty) {
      return false;
    }

    final target = _baseName(fileName).toLowerCase();
    for (final rawLine in sumsText.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final parts = line.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
      if (parts.length < 2) continue;

      final hash = parts.first;
      var name = parts.sublist(1).join(' ');
      if (name.startsWith('*')) name = name.substring(1);
      name = _baseName(name).toLowerCase();

      if (name == target && hash.toLowerCase() == actualHashHex.toLowerCase()) {
        return true;
      }
    }
    return false;
  }

  static String _baseName(String path) {
    final index = path.lastIndexOf(RegExp(r'[\\/]'));
    return index < 0 ? path : path.substring(index + 1);
  }
}
