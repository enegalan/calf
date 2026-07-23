import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:ui/constants/calf_constants.dart';
import 'package:ui/storage/update_preferences.dart';
import 'package:ui/updates/update_info.dart';

const _checkInterval = Duration(hours: 24);
const _requestTimeout = Duration(seconds: 15);

class UpdateChecker {
  /// Creates a checker that queries GitHub for the latest Calf release.
  UpdateChecker({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// In-memory What's New notes keyed by normalized version.
  static final Map<String, String> _whatsNewMemoryCache = {};

  /// Compares two semantic version strings; returns negative if [left] is older.
  static int compareVersions(String left, String right) {
    final leftParts = _parseVersionParts(left);
    final rightParts = _parseVersionParts(right);

    for (var index = 0; index < 3; index++) {
      final leftValue = index < leftParts.length ? leftParts[index] : 0;
      final rightValue = index < rightParts.length ? rightParts[index] : 0;
      if (leftValue != rightValue) {
        return leftValue.compareTo(rightValue);
      }
    }

    return 0;
  }

  /// Fetches GitHub release notes for [version] (tag `vX.Y.Z`).
  ///
  /// Returns cached notes for that version when available (memory, then disk).
  Future<String?> fetchReleaseNotes(String version) async {
    final normalized = normalizeTagName(version);
    if (normalized.isEmpty ||
        normalized == 'dev' ||
        normalized == 'unavailable') {
      return null;
    }

    final memory = _whatsNewMemoryCache[normalized];
    if (memory != null && memory.isNotEmpty) {
      return memory;
    }

    final preferences = await UpdatePreferences.load();
    if (preferences.whatsNewVersion == normalized &&
        preferences.whatsNewNotes.isNotEmpty) {
      _whatsNewMemoryCache[normalized] = preferences.whatsNewNotes;
      return preferences.whatsNewNotes;
    }

    try {
      final response = await _client
          .get(
            Uri.parse(
              'https://api.github.com/repos/${CalfGitHub.repo}/releases/tags/v$normalized',
            ),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'Calf',
            },
          )
          .timeout(_requestTimeout);

      if (response.statusCode != 200) {
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final body = decoded['body'];
      if (body is! String) {
        return null;
      }
      final trimmed = body.trim();
      if (trimmed.isEmpty) {
        return null;
      }

      _whatsNewMemoryCache[normalized] = trimmed;
      await UpdatePreferences.saveWhatsNewNotes(
        version: normalized,
        notes: trimmed,
      );
      return trimmed;
    } on TimeoutException {
      return null;
    } on FormatException {
      return null;
    } on http.ClientException {
      return null;
    } on SocketException {
      return null;
    } on HandshakeException {
      return null;
    } on OSError {
      return null;
    }
  }

  /// Strips a leading "v" from a Git tag name.
  static String normalizeTagName(String tagName) {
    final trimmed = tagName.trim();
    if (trimmed.startsWith('v') || trimmed.startsWith('V')) {
      return trimmed.substring(1);
    }
    return trimmed;
  }

  /// Returns platform-specific installer asset filenames for [version].
  static List<String> preferredAssetNames(String version) {
    if (Platform.isMacOS) {
      return ['Calf-$version.dmg', 'Calf-$version.pkg'];
    }

    if (Platform.isWindows) {
      return ['Calf-$version.exe'];
    }

    if (Platform.isLinux) {
      return [
        'Calf-$version-x86_64.AppImage',
        'calf_${version}_amd64.deb',
        'calf-$version-1.x86_64.rpm',
      ];
    }

    return const [];
  }

  /// Parses a GitHub release JSON object into [UpdateInfo], or null if invalid.
  static UpdateInfo? parseReleaseJson(Map<String, dynamic> json) {
    final tagName = json['tag_name'];
    if (tagName is! String || tagName.isEmpty) {
      return null;
    }

    final version = normalizeTagName(tagName);
    final releasePageUrl = json['html_url'];
    if (releasePageUrl is! String || releasePageUrl.isEmpty) {
      return null;
    }

    final assets = json['assets'];
    if (assets is! List) {
      return null;
    }

    final downloadUrl = _selectDownloadUrl(version, assets);
    if (downloadUrl == null) {
      return null;
    }

    final body = json['body'];
    return UpdateInfo(
      version: version,
      releaseNotes: body is String ? body.trim() : '',
      downloadUrl: downloadUrl,
      releasePageUrl: releasePageUrl,
    );
  }

  /// Checks GitHub for a newer release, using cached results when recent.
  Future<UpdateCheckResult> check({
    required String currentVersion,
    bool force = false,
  }) async {
    final normalizedCurrent = normalizeTagName(currentVersion);
    final preferences = await UpdatePreferences.load();

    if (!force &&
        preferences.lastCheckAt != null &&
        DateTime.now().difference(preferences.lastCheckAt!) < _checkInterval &&
        preferences.cachedUpdate != null) {
      return _resultFromCache(
        currentVersion: normalizedCurrent,
        latest: preferences.cachedUpdate!,
        checkedAt: preferences.lastCheckAt!,
        skippedVersion: preferences.skippedVersion,
      );
    }

    try {
      final response = await _client
          .get(
            Uri.parse(
              'https://api.github.com/repos/${CalfGitHub.repo}/releases/latest',
            ),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'Calf',
            },
          )
          .timeout(_requestTimeout);

      if (response.statusCode != 200) {
        return UpdateCheckResult.failed(
          currentVersion: normalizedCurrent,
          error: 'Could not reach GitHub (HTTP ${response.statusCode}).',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return UpdateCheckResult.failed(
          currentVersion: normalizedCurrent,
          error: 'Unexpected response from GitHub.',
        );
      }

      final latest = parseReleaseJson(decoded);
      final checkedAt = DateTime.now();

      if (latest == null) {
        return UpdateCheckResult.failed(
          currentVersion: normalizedCurrent,
          error: 'Latest release is missing download assets for this platform.',
          checkedAt: checkedAt,
        );
      }

      await UpdatePreferences.saveCheckResult(
        checkedAt: checkedAt,
        latest: latest,
        skippedVersion: preferences.skippedVersion,
      );

      return _resultFromCache(
        currentVersion: normalizedCurrent,
        latest: latest,
        checkedAt: checkedAt,
        skippedVersion: preferences.skippedVersion,
      );
    } on TimeoutException {
      return UpdateCheckResult.failed(
        currentVersion: normalizedCurrent,
        error: 'Update check timed out.',
      );
    } on SocketException {
      return UpdateCheckResult.failed(
        currentVersion: normalizedCurrent,
        error: 'No network connection.',
      );
    } on http.ClientException {
      return UpdateCheckResult.failed(
        currentVersion: normalizedCurrent,
        error: 'Could not reach GitHub.',
      );
    } on FormatException {
      return UpdateCheckResult.failed(
        currentVersion: normalizedCurrent,
        error: 'Unexpected response from GitHub.',
      );
    }
  }

  /// Closes the underlying HTTP client.
  void close() {
    _client.close();
  }

  static final RegExp _versionPrefixPattern = RegExp(r'^\d+');

  /// Splits [version] into up to three numeric parts for comparison.
  static List<int> _parseVersionParts(String version) {
    final normalized = normalizeTagName(version);
    final parts = normalized.split('.');
    final values = <int>[];

    for (var index = 0; index < parts.length && values.length < 3; index++) {
      final match = _versionPrefixPattern.firstMatch(parts[index]);
      if (match == null) {
        break;
      }
      values.add(int.parse(match.group(0)!));
    }

    while (values.length < 3) {
      values.add(0);
    }

    return values;
  }

  /// Builds an [UpdateCheckResult] from cached release data and skip state.
  static UpdateCheckResult _resultFromCache({
    required String currentVersion,
    required UpdateInfo latest,
    required DateTime checkedAt,
    required String skippedVersion,
  }) {
    if (skippedVersion == latest.version) {
      return UpdateCheckResult.upToDate(
        currentVersion: currentVersion,
        checkedAt: checkedAt,
      );
    }

    if (compareVersions(currentVersion, latest.version) >= 0) {
      return UpdateCheckResult.upToDate(
        currentVersion: currentVersion,
        checkedAt: checkedAt,
      );
    }

    return UpdateCheckResult.available(
      currentVersion: currentVersion,
      latest: latest,
      checkedAt: checkedAt,
    );
  }

  /// Picks the first matching platform installer URL from [assets].
  static String? _selectDownloadUrl(String version, List<dynamic> assets) {
    final preferredNames = preferredAssetNames(version);
    final assetByName = <String, String>{};

    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) {
        continue;
      }

      final name = asset['name'];
      final url = asset['browser_download_url'];
      if (name is String &&
          url is String &&
          name.isNotEmpty &&
          url.isNotEmpty) {
        assetByName[name] = url;
      }
    }

    for (final name in preferredNames) {
      final url = assetByName[name];
      if (url != null) {
        return url;
      }
    }

    return null;
  }
}
