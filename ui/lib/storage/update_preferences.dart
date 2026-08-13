import 'package:ui/constants/calf_constants.dart';
import 'package:ui/storage/calf_ui_storage.dart';
import 'package:ui/updates/update_info.dart';

class UpdatePreferencesData {
  /// Creates cached update-check preference data.
  const UpdatePreferencesData({
    this.lastCheckAt,
    this.cachedUpdate,
    this.whatsNewVersion = '',
    this.whatsNewNotes = '',
  });

  final DateTime? lastCheckAt;
  final UpdateInfo? cachedUpdate;

  /// App version whose What's New notes are stored in [whatsNewNotes].
  final String whatsNewVersion;

  /// Cached GitHub release-notes body for [whatsNewVersion].
  final String whatsNewNotes;
}

class UpdatePreferences {
  /// Loads update-check cache and What's New preferences from disk.
  static Future<UpdatePreferencesData> load() async {
    final raw = await CalfUiStorage.readMap(CalfStorageFiles.updates);
    if (raw == null) {
      return const UpdatePreferencesData();
    }

    DateTime? lastCheckAt;
    final lastCheckRaw = raw['last_check_at'];
    if (lastCheckRaw is String && lastCheckRaw.isNotEmpty) {
      lastCheckAt = DateTime.tryParse(lastCheckRaw);
    }

    final cachedUpdateRaw = raw['cached_update'];
    UpdateInfo? cachedUpdate;
    if (cachedUpdateRaw is Map<String, dynamic>) {
      cachedUpdate = _parseCachedUpdate(cachedUpdateRaw);
    }

    final whatsNewVersion = raw['whats_new_version'];
    final whatsNewNotes = raw['whats_new_notes'];

    return UpdatePreferencesData(
      lastCheckAt: lastCheckAt,
      cachedUpdate: cachedUpdate,
      whatsNewVersion: whatsNewVersion is String ? whatsNewVersion : '',
      whatsNewNotes: whatsNewNotes is String ? whatsNewNotes : '',
    );
  }

  /// Persists the result of an update check at [checkedAt].
  static Future<void> saveCheckResult({
    required DateTime checkedAt,
    required UpdateInfo? latest,
  }) async {
    final current = await load();
    await _save(
      UpdatePreferencesData(
        lastCheckAt: checkedAt,
        cachedUpdate: latest,
        whatsNewVersion: current.whatsNewVersion,
        whatsNewNotes: current.whatsNewNotes,
      ),
    );
  }

  /// Caches What's New release notes for [version].
  static Future<void> saveWhatsNewNotes({
    required String version,
    required String notes,
  }) async {
    final current = await load();
    await _save(
      UpdatePreferencesData(
        lastCheckAt: current.lastCheckAt,
        cachedUpdate: current.cachedUpdate,
        whatsNewVersion: version,
        whatsNewNotes: notes,
      ),
    );
  }

  /// Writes [data] to the updates preference file.
  static Future<void> _save(UpdatePreferencesData data) async {
    await CalfUiStorage.writeMap(CalfStorageFiles.updates, {
      if (data.lastCheckAt != null)
        'last_check_at': data.lastCheckAt!.toIso8601String(),
      if (data.cachedUpdate != null)
        'cached_update': {
          'version': data.cachedUpdate!.version,
          'release_notes': data.cachedUpdate!.releaseNotes,
          'download_url': data.cachedUpdate!.downloadUrl,
          'release_page_url': data.cachedUpdate!.releasePageUrl,
        },
      if (data.whatsNewVersion.isNotEmpty)
        'whats_new_version': data.whatsNewVersion,
      if (data.whatsNewNotes.isNotEmpty) 'whats_new_notes': data.whatsNewNotes,
    });
  }

  /// Parses a cached [UpdateInfo] from stored JSON, or null when invalid.
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
