/// Formats a millisecond duration as `1.2s` or `2m 3s`.
///
/// When [emptyIfZero] is true and [durationMs] is <= 0, returns an empty
/// string (list rows). Otherwise returns `0.0s`.
String formatDurationMs(int durationMs, {bool emptyIfZero = false}) {
  if (durationMs <= 0) {
    return emptyIfZero ? '' : '0.0s';
  }

  final seconds = durationMs / 1000;
  if (seconds < 60) {
    return '${seconds.toStringAsFixed(1)}s';
  }

  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  return '${minutes}m ${remainder.toStringAsFixed(0)}s';
}

/// Formats a byte count as a human-readable size (`1.5 kB`, `2.0 MB`).
String formatFileSize(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} kB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Formats a byte count for compact chart axis labels (`1.5KB`, `2.0MB`).
String formatFileSizeCompact(double value) {
  if (value >= 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }
  if (value >= 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
  if (value >= 1024) {
    return '${(value / 1024).toStringAsFixed(1)}KB';
  }
  return '${value.toStringAsFixed(0)}B';
}
