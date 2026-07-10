import 'package:flutter/widgets.dart';

import 'package:ui/constants/calf_constants.dart';
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
    final raw = await CalfUiStorage.readMap(CalfStorageFiles.logsViewer);
    if (raw == null) {
      return defaults;
    }

    return LogViewerPreferences(
      showTimestamp: raw['show_timestamp'] == true,
      wrapLines: raw['wrap_lines'] != false,
    );
  }

  static Future<void> save({
    required bool showTimestamp,
    required bool wrapLines,
  }) async {
    await CalfUiStorage.writeMap(CalfStorageFiles.logsViewer, {
      'show_timestamp': showTimestamp,
      'wrap_lines': wrapLines,
    });
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
