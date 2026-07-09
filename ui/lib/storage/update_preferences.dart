import 'dart:convert';

import 'package:ui/storage/calf_ui_storage.dart';
import 'package:ui/updates/update_info.dart';

class UpdatePreferencesData {
  const UpdatePreferencesData({
    this.lastCheckAt,
    this.skippedVersion = '',
    this.cachedUpdate,
  });

  final DateTime? lastCheckAt;
  final String skippedVersion;
  final UpdateInfo? cachedUpdate;
}

class UpdatePreferences {
  static Future<UpdatePreferencesData> load() async {
    try {
      final file = await CalfUiStorage.file('updates.json');
      if (!file.existsSync()) {
        return const UpdatePreferencesData();
      }

      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        return const UpdatePreferencesData();
      }

      DateTime? lastCheckAt;
      final lastCheckRaw = raw['last_check_at'];
      if (lastCheckRaw is String && lastCheckRaw.isNotEmpty) {
        lastCheckAt = DateTime.tryParse(lastCheckRaw);
      }

      final skippedVersion = raw['skipped_version'];
      final cachedUpdateRaw = raw['cached_update'];
      UpdateInfo? cachedUpdate;
      if (cachedUpdateRaw is Map<String, dynamic>) {
        cachedUpdate = _parseCachedUpdate(cachedUpdateRaw);
      }

      return UpdatePreferencesData(
        lastCheckAt: lastCheckAt,
        skippedVersion: skippedVersion is String ? skippedVersion : '',
        cachedUpdate: cachedUpdate,
      );
    } catch (_) {
      return const UpdatePreferencesData();
    }
  }

  static Future<void> saveCheckResult({
    required DateTime checkedAt,
    required UpdateInfo? latest,
    String skippedVersion = '',
  }) async {
    await _save(
      UpdatePreferencesData(
        lastCheckAt: checkedAt,
        skippedVersion: skippedVersion,
        cachedUpdate: latest,
      ),
    );
  }

  static Future<void> saveSkippedVersion(String version) async {
    final current = await load();
    await _save(
      UpdatePreferencesData(
        lastCheckAt: current.lastCheckAt,
        skippedVersion: version,
        cachedUpdate: current.cachedUpdate,
      ),
    );
  }

  static Future<void> _save(UpdatePreferencesData data) async {
    try {
      final file = await CalfUiStorage.file('updates.json');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          if (data.lastCheckAt != null) 'last_check_at': data.lastCheckAt!.toIso8601String(),
          if (data.skippedVersion.isNotEmpty) 'skipped_version': data.skippedVersion,
          if (data.cachedUpdate != null)
            'cached_update': {
              'version': data.cachedUpdate!.version,
              'release_notes': data.cachedUpdate!.releaseNotes,
              'download_url': data.cachedUpdate!.downloadUrl,
              'release_page_url': data.cachedUpdate!.releasePageUrl,
            },
        }),
      );
    } catch (_) {}
  }

  static UpdateInfo? _parseCachedUpdate(Map<String, dynamic> raw) {
    final version = raw['version'];
    final downloadUrl = raw['download_url'];
    final releasePageUrl = raw['release_page_url'];
    if (version is! String ||
        version.isEmpty ||
        downloadUrl is! String ||
        downloadUrl.isEmpty ||
        releasePageUrl is! String ||
        releasePageUrl.isEmpty) {
      return null;
    }

    final releaseNotes = raw['release_notes'];
    return UpdateInfo(
      version: version,
      releaseNotes: releaseNotes is String ? releaseNotes : '',
      downloadUrl: downloadUrl,
      releasePageUrl: releasePageUrl,
    );
  }
}
