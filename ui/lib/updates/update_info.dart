class UpdateInfo {
  /// Holds metadata for a GitHub release that can be downloaded.
  const UpdateInfo({
    required this.version,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.releasePageUrl,
  });

  final String version;
  final String releaseNotes;
  final String downloadUrl;
  final String releasePageUrl;
}

class UpdateCheckResult {
  /// Reports that the running version is current or was skipped.
  const UpdateCheckResult.upToDate({
    required this.currentVersion,
    this.checkedAt,
  }) : latest = null,
       error = null;

  /// Reports that a newer release is available for download.
  const UpdateCheckResult.available({
    required this.currentVersion,
    required this.latest,
    this.checkedAt,
  }) : error = null;

  /// Reports that the update check failed with an error message.
  const UpdateCheckResult.failed({
    required this.currentVersion,
    required this.error,
    this.checkedAt,
  }) : latest = null;

  final String currentVersion;
  final UpdateInfo? latest;
  final String? error;
  final DateTime? checkedAt;

  /// Whether a newer release is available.
  bool get hasUpdate => latest != null;
}
