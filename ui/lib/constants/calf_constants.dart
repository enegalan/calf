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
