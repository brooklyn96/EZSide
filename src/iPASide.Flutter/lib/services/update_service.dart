import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../platform/app_paths.dart';
import 'update_planner.dart';

/// Starts a detached OS process. Returns once the launch has been accepted.
typedef DetachedLauncher = Future<void> Function(
  String executable,
  List<String> arguments,
);

/// The result of one update check.
@immutable
class UpdateCheck {
  const UpdateCheck(
    this.outcome, {
    this.latestVersion,
    this.releasePageUrl,
    this.pending,
    this.detail,
  });

  final UpdateOutcome outcome;

  /// The newest published version, when one was found.
  final String? latestVersion;

  /// That release's GitHub page, when the API returned one.
  final String? releasePageUrl;

  /// The verified installer waiting on disk, when [outcome] is
  /// [UpdateOutcome.readyToInstall].
  final PendingUpdate? pending;

  /// Extra context for the UI or the log (an error message, usually).
  final String? detail;
}

/// Checks GitHub for a newer iPASide, downloads it, and verifies it before
/// offering it to the user.
///
/// Deliberately fail-closed, in the same order as every step below:
///   1. the release must advertise a newer version and an installer asset;
///   2. it must publish `SHA256SUMS.txt` — absent means refuse, never "assume good";
///   3. the download's SHA-256 must match the published checksum *for its filename*.
///
/// The verified installer is then **staged for a one-click install**, never run
/// automatically. A checksum published in the same release as the installer
/// proves integrity, not authenticity: whoever could swap the installer could
/// swap the sums too. Only a code signature would settle that, and iPASide's
/// releases are not signed, so the user always consents to the install. If
/// signing is added later, an Authenticode check is the missing gate that would
/// make an unattended install defensible.
class UpdateService {
  UpdateService({
    required this.currentVersion,
    AppPaths? paths,
    this.owner = 'pwnapplehat',
    this.repo = 'iPASide',
    HttpClient? httpClient,
    void Function(String message)? log,
    DetachedLauncher? launchDetached,
  })  : _paths = paths ?? AppPaths.instance,
        _http = httpClient ?? HttpClient(),
        _log = log ?? _defaultLog,
        _launchDetached = launchDetached ?? _defaultLaunchDetached;

  final String currentVersion;
  final String owner;
  final String repo;

  final AppPaths _paths;
  final HttpClient _http;
  final void Function(String) _log;
  final DetachedLauncher _launchDetached;

  static void _defaultLog(String message) => debugPrint('[update] $message');

  static Future<void> _defaultLaunchDetached(
    String executable,
    List<String> arguments,
  ) async {
    await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.detached,
    );
  }

  Uri get _latestReleaseApi =>
      Uri.https('api.github.com', '/repos/$owner/$repo/releases/latest');

  /// Where the app's own release page lives, for a "see what's new" link.
  Uri get releasesPage => Uri.https('github.com', '/$owner/$repo/releases');

  String get _stagingDir => '${_paths.root}${Platform.pathSeparator}updates';

  /// Opens [url] (or [releasesPage] when null / unsafe) in the default browser.
  ///
  /// Only `http`/`https` targets are accepted from the release payload; anything
  /// else falls back to the releases index so a compromised API reply cannot
  /// steer `cmd /c start` at an arbitrary scheme.
  Future<bool> openReleaseNotes([String? url]) async {
    final Uri target = resolveReleaseNotesUri(url);
    try {
      await _launchDetached(
        'cmd',
        <String>['/c', 'start', '', target.toString()],
      );
      return true;
    } on Object catch (error) {
      _log('failed to open release notes: $error');
      return false;
    }
  }

  /// Picks a browser URL for "See Changes". Visible for tests.
  @visibleForTesting
  Uri resolveReleaseNotesUri(String? url) {
    final String? raw = url?.trim();
    if (raw != null && raw.isNotEmpty) {
      final Uri? parsed = Uri.tryParse(raw);
      if (parsed != null &&
          parsed.hasScheme &&
          (parsed.isScheme('https') || parsed.isScheme('http'))) {
        return parsed;
      }
    }
    return releasesPage;
  }

  /// Compares versions only — no download.
  ///
  /// This is what runs at startup: one small API call, so a new release is
  /// noticed without spending ~100 MB of someone's connection uninvited.
  Future<UpdateCheck> peekLatest() async {
    final running = AppVersion.tryParse(currentVersion);
    if (running == null) {
      return const UpdateCheck(
        UpdateOutcome.error,
        detail: 'The running version could not be read.',
      );
    }

    try {
      final json = await _getString(_latestReleaseApi);
      if (json == null) {
        return const UpdateCheck(
          UpdateOutcome.error,
          detail: 'Could not reach GitHub to check for updates.',
        );
      }

      final release = UpdatePlanner.parseRelease(json, arch: _architecture);
      final latest = AppVersion.tryParse(release.tag);
      final releasePage = release.htmlUrl ?? releasesPage.toString();
      if (latest == null || latest <= running) {
        _clearStaged();
        return UpdateCheck(
          UpdateOutcome.upToDate,
          latestVersion: latest?.toString(),
          releasePageUrl: releasePage,
        );
      }
      return UpdateCheck(
        UpdateOutcome.updateAvailable,
        latestVersion: latest.toString(),
        releasePageUrl: releasePage,
      );
    } on Object catch (error) {
      _log('peek failed: $error');
      return const UpdateCheck(
        UpdateOutcome.error,
        detail: 'The update check could not finish.',
      );
    }
  }

  /// Downloads the newest release, verifies it, and stages it for installation.
  Future<UpdateCheck> downloadUpdate({void Function(double progress)? onProgress}) async {
    final running = AppVersion.tryParse(currentVersion);
    if (running == null) {
      return const UpdateCheck(
        UpdateOutcome.error,
        detail: 'The running version could not be read.',
      );
    }

    try {
      final json = await _getString(_latestReleaseApi);
      if (json == null) {
        return const UpdateCheck(
          UpdateOutcome.error,
          detail: 'Could not reach GitHub to check for updates.',
        );
      }

      final release = UpdatePlanner.parseRelease(json, arch: _architecture);
      final latest = AppVersion.tryParse(release.tag);
      final releasePage = release.htmlUrl ?? releasesPage.toString();

      if (latest == null || latest <= running) {
        // A previous run may have staged a build for a release that has since
        // been pulled; drop it so the app cannot keep offering a ghost update.
        _clearStaged();
        return UpdateCheck(
          UpdateOutcome.upToDate,
          latestVersion: latest?.toString(),
          releasePageUrl: releasePage,
        );
      }

      _log('update available: $latest (running $running)');

      if (release.setupUrl == null || release.setupName == null) {
        return UpdateCheck(
          UpdateOutcome.noSetupAsset,
          latestVersion: latest.toString(),
          releasePageUrl: releasePage,
          detail: 'That release has no installer to download.',
        );
      }
      if (release.sumsUrl == null) {
        _log('refused: release publishes no SHA256SUMS.txt');
        return UpdateCheck(
          UpdateOutcome.noChecksums,
          latestVersion: latest.toString(),
          releasePageUrl: releasePage,
          detail: 'That release publishes no checksums, so it cannot be verified.',
        );
      }

      final directory = Directory(_stagingDir);
      await directory.create(recursive: true);
      final setupPath =
          '$_stagingDir${Platform.pathSeparator}${release.setupName}';

      await _download(Uri.parse(release.setupUrl!), setupPath, onProgress: onProgress);

      final sums = await _getString(Uri.parse(release.sumsUrl!));
      final actual = await _sha256Hex(setupPath);
      if (sums == null ||
          !UpdatePlanner.checksumMatches(sums, release.setupName!, actual)) {
        _log('refused: checksum mismatch for ${release.setupName}');
        await _tryDelete(setupPath);
        return UpdateCheck(
          UpdateOutcome.checksumMismatch,
          latestVersion: latest.toString(),
          releasePageUrl: releasePage,
          detail: 'The download did not match its published checksum, so it was discarded.',
        );
      }

      await _clearStagedExcept(setupPath);
      final size = await File(setupPath).length();
      _log('staged ${release.setupName} (verified) for one-click install');

      return UpdateCheck(
        UpdateOutcome.readyToInstall,
        latestVersion: latest.toString(),
        releasePageUrl: releasePage,
        pending: PendingUpdate(
          version: latest.toString(),
          setupPath: setupPath,
          sizeBytes: size,
        ),
      );
    } on Object catch (error) {
      _log('check failed: $error');
      return UpdateCheck(
        UpdateOutcome.error,
        detail: 'The update check could not finish.',
      );
    }
  }

  /// Flags passed to a staged Inno Setup when applying an in-app update.
  ///
  /// `/SILENT` (not `/VERYSILENT`): Inno still shows its own progress window and
  /// any error dialog, so a mid-install failure is never hidden. `/NORESTART`
  /// keeps Windows from rebooting. `/CLOSEAPPLICATIONS` / `/RESTARTAPPLICATIONS`
  /// are belt-and-braces for stray iPASide processes; the running GUI exits
  /// itself right after launch so `AppMutex` releases and Setup can replace
  /// binaries. The installer's postinstall `[Run]` entry then opens the new
  /// build (it must not use `skipifsilent`).
  static const List<String> silentInstallArgs = <String>[
    '/SILENT',
    '/NORESTART',
    '/CLOSEAPPLICATIONS',
    '/RESTARTAPPLICATIONS',
  ];

  /// Starts the staged installer in silent upgrade mode.
  ///
  /// The caller must exit the running app immediately after this returns true
  /// so Setup can replace locked binaries; the installer relaunches iPASide
  /// when it finishes.
  Future<bool> installStaged(PendingUpdate update) async {
    if (!File(update.setupPath).existsSync()) return false;
    try {
      await _launchDetached(update.setupPath, silentInstallArgs);
      return true;
    } on Object catch (error) {
      _log('failed to launch the installer: $error');
      return false;
    }
  }

  String get _architecture {
    final arch = Platform.environment['PROCESSOR_ARCHITECTURE']?.toLowerCase();
    return arch != null && arch.contains('arm') ? 'arm64' : 'x64';
  }

  Future<String?> _getString(Uri uri) async {
    final request = await _http.getUrl(uri);
    _applyHeaders(request);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      _log('GET $uri -> ${response.statusCode}');
      await response.drain<void>();
      return null;
    }
    return response.transform(utf8.decoder).join();
  }

  Future<void> _download(
    Uri uri,
    String destination, {
    void Function(double progress)? onProgress,
  }) async {
    final request = await _http.getUrl(uri);
    _applyHeaders(request);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('download failed (${response.statusCode})', uri: uri);
    }

    final total = response.contentLength;
    final sink = File(destination).openWrite();
    var received = 0;
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  void _applyHeaders(HttpClientRequest request) {
    // GitHub's API rejects requests without a User-Agent.
    request.headers.set(HttpHeaders.userAgentHeader,
        'iPASide/$currentVersion (+https://github.com/$owner/$repo)');
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
  }

  /// Streams the file through SHA-256 rather than reading ~100 MB into memory.
  Future<String> _sha256Hex(String path) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    await for (final chunk in File(path).openRead()) {
      input.add(chunk);
    }
    input.close();
    return sink.value.toString();
  }

  void _clearStaged() {
    final directory = Directory(_stagingDir);
    if (!directory.existsSync()) return;
    for (final entry in directory.listSync()) {
      if (entry is File) {
        try {
          entry.deleteSync();
        } on Object {
          // Best effort; a locked file just gets replaced next time.
        }
      }
    }
  }

  Future<void> _clearStagedExcept(String keepPath) async {
    final directory = Directory(_stagingDir);
    if (!directory.existsSync()) return;
    for (final entry in directory.listSync()) {
      if (entry is File && entry.path != keepPath) {
        await _tryDelete(entry.path);
      }
    }
  }

  Future<void> _tryDelete(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } on Object {
      // Best effort.
    }
  }
}

/// Collects the single digest that `startChunkedConversion` emits, so hashing can
/// stream without pulling in `package:convert` for its AccumulatorSink.
class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
