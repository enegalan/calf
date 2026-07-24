import 'package:flutter/widgets.dart';

abstract final class CalfColors {
  static const Color primary = Color(0xFF2496ED);
  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF0A500);
}

abstract final class CalfDefaults {
  static const String defaultBaseUrl = 'http://127.0.0.1:8765';
  static const int defaultPollIntervalMs = 3000;
  static const Duration defaultRequestTimeout = Duration(seconds: 5);
  static const Duration runtimeActionTimeout = Duration(minutes: 3);
  static const Duration imageActionTimeout = Duration(minutes: 10);
  static const Duration volumeActionTimeout = Duration(seconds: 30);
  static const Duration volumeExportTimeout = Duration(minutes: 30);
  static const Duration troubleshootActionTimeout = Duration(minutes: 5);
}

abstract final class CalfStorageFiles {
  static const String sidebar = 'sidebar.json';
  static const String containerGroups = 'container_groups.json';
  static const String logsViewer = 'logs_viewer.json';
  static const String updates = 'updates.json';
}

abstract final class CalfGitHub {
  static const String repo = 'enegalan/calf';
}

abstract final class CalfVersion {
  /// Returns a user-facing version label; empty versions show as `dev`.
  static String displayLabel(String version) =>
      version.trim().isEmpty ? 'dev' : version.trim();
}

/// Discrete Resource Saver idle timeouts (seconds): 30s, then every 5 minutes to 60m.
abstract final class CalfResourceSaver {
  static const List<int> timeoutSeconds = [
    30,
    300,
    600,
    900,
    1200,
    1500,
    1800,
    2100,
    2400,
    2700,
    3000,
    3300,
    3600,
  ];

  /// Returns the nearest discrete timeout index for [seconds].
  static int indexForSeconds(int seconds) {
    var best = 0;
    var bestDelta = (timeoutSeconds[0] - seconds).abs();
    for (var i = 1; i < timeoutSeconds.length; i++) {
      final delta = (timeoutSeconds[i] - seconds).abs();
      if (delta < bestDelta) {
        best = i;
        bestDelta = delta;
      }
    }
    return best;
  }

  /// Formats a timeout for slider labels (`30 sec`, `5 min`, …).
  static String labelForSeconds(int seconds) {
    if (seconds < 60) {
      return '$seconds sec';
    }
    return '${seconds ~/ 60} min';
  }

  /// Whether the axis under the slider should show a tick label for [seconds].
  static bool showTickLabel(int seconds) {
    if (seconds < 60) {
      return true;
    }
    final minutes = seconds ~/ 60;
    return minutes == 5 || minutes % 10 == 0;
  }
}
