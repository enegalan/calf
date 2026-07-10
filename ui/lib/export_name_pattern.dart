String defaultExportFileNamePattern() => '{volume}-{timestamp}.tar.gz';

String defaultExportImageRefPattern() => '{volume}-backup:{timestamp}';

bool exportNamePatternHasUniqueToken(String pattern) {
  final normalized = pattern.trim().toLowerCase();
  if (normalized.contains('{timestamp}') || normalized.contains('{datetime}')) {
    return true;
  }

  return normalized.contains('{date}') && normalized.contains('{time}');
}

String sanitizeVolumeNameToken(String value) {
  return value.trim().replaceAll('/', '_').replaceAll('\\', '_');
}

String sanitizeExportFileName(String value) {
  return value
      .trim()
      .replaceAll('/', '_')
      .replaceAll('\\', '_')
      .replaceAll(':', '-');
}

String expandExportFileNamePattern(
  String pattern,
  String volumeName,
  DateTime runTime,
) {
  return _expandNamePattern(
    pattern: pattern,
    volumeName: volumeName,
    runTime: runTime,
    defaultPattern: defaultExportFileNamePattern(),
    forFileExport: true,
  );
}

String expandExportImageRefPattern(
  String pattern,
  String volumeName,
  DateTime runTime,
) {
  return _expandNamePattern(
    pattern: pattern,
    volumeName: volumeName,
    runTime: runTime,
    defaultPattern: defaultExportImageRefPattern(),
    forFileExport: false,
  );
}

String _expandNamePattern({
  required String pattern,
  required String volumeName,
  required DateTime runTime,
  required String defaultPattern,
  required bool forFileExport,
}) {
  final resolvedPattern = pattern.trim().isEmpty
      ? defaultPattern
      : pattern.trim();

  final timestamp = _formatPatternTimestamp(runTime);
  final date =
      '${runTime.year.toString().padLeft(4, '0')}-'
      '${runTime.month.toString().padLeft(2, '0')}-'
      '${runTime.day.toString().padLeft(2, '0')}';
  final time =
      '${runTime.hour.toString().padLeft(2, '0')}-'
      '${runTime.minute.toString().padLeft(2, '0')}-'
      '${runTime.second.toString().padLeft(2, '0')}';

  final expanded = resolvedPattern
      .replaceAll('{volume}', sanitizeVolumeNameToken(volumeName))
      .replaceAll('{timestamp}', timestamp)
      .replaceAll('{datetime}', timestamp)
      .replaceAll('{date}', date)
      .replaceAll('{time}', time);

  if (forFileExport) {
    return sanitizeExportFileName(expanded);
  }

  return expanded.trim();
}

String _formatPatternTimestamp(DateTime runTime) {
  return '${runTime.year.toString().padLeft(4, '0')}'
      '${runTime.month.toString().padLeft(2, '0')}'
      '${runTime.day.toString().padLeft(2, '0')}-'
      '${runTime.hour.toString().padLeft(2, '0')}'
      '${runTime.minute.toString().padLeft(2, '0')}'
      '${runTime.second.toString().padLeft(2, '0')}';
}
