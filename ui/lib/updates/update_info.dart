class UpdateInfo {
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
  const UpdateCheckResult.upToDate({
    required this.currentVersion,
    this.checkedAt,
  })  : latest = null,
        error = null;

  const UpdateCheckResult.available({
    required this.currentVersion,
    required this.latest,
    this.checkedAt,
  })  : error = null;

  const UpdateCheckResult.failed({
    required this.currentVersion,
    required this.error,
    this.checkedAt,
  })  : latest = null;

  final String currentVersion;
  final UpdateInfo? latest;
  final String? error;
  final DateTime? checkedAt;

  bool get hasUpdate => latest != null;
}
