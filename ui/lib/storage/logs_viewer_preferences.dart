import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'package:ui/storage/calf_ui_storage.dart';

class LogViewerPreferences {
  const LogViewerPreferences({
    required this.showTimestamp,
    required this.wrapLines,
  });

  final bool showTimestamp;
  final bool wrapLines;

  static const LogViewerPreferences defaults = LogViewerPreferences(
    showTimestamp: false,
    wrapLines: true,
  );

  static Future<LogViewerPreferences> load() async {
    try {
      final file = await CalfUiStorage.file('logs_viewer.json');
      if (!file.existsSync()) {
        return defaults;
      }

      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        return defaults;
      }

      return LogViewerPreferences(
        showTimestamp: raw['show_timestamp'] == true,
        wrapLines: raw['wrap_lines'] != false,
      );
    } catch (_) {
      return defaults;
    }
  }

  static Future<void> save({
    required bool showTimestamp,
    required bool wrapLines,
  }) async {
    try {
      final file = await CalfUiStorage.file('logs_viewer.json');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode({
        'show_timestamp': showTimestamp,
        'wrap_lines': wrapLines,
      }));
    } catch (_) {}
  }
}

mixin LogViewerPreferencesMixin<T extends StatefulWidget> on State<T> {
  bool showTimestamp = LogViewerPreferences.defaults.showTimestamp;
  bool wrapLines = LogViewerPreferences.defaults.wrapLines;

  @mustCallSuper
  void initLogViewerPreferences() {
    loadLogViewerPreferences();
  }

  Future<void> loadLogViewerPreferences() async {
    final preferences = await LogViewerPreferences.load();
    if (!mounted) {
      return;
    }

    setState(() {
      showTimestamp = preferences.showTimestamp;
      wrapLines = preferences.wrapLines;
    });
  }

  void setLogViewerShowTimestamp(bool value) {
    setState(() => showTimestamp = value);
    LogViewerPreferences.save(showTimestamp: value, wrapLines: wrapLines);
  }

  void setLogViewerWrapLines(bool value) {
    setState(() => wrapLines = value);
    LogViewerPreferences.save(showTimestamp: showTimestamp, wrapLines: value);
  }
}
