import 'package:flutter/widgets.dart';

import 'package:ui/constants/calf_constants.dart';
import 'package:ui/storage/calf_ui_storage.dart';

class LogViewerPreferences {
  /// Creates log viewer display preferences.
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

  /// Loads log viewer preferences from disk, falling back to [defaults].
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

  /// Persists timestamp and wrap-line preferences to disk.
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

  /// Loads preferences during [State.initState]; call from a subclass initState.
  @mustCallSuper
  void initLogViewerPreferences() {
    loadLogViewerPreferences();
  }

  /// Fetches preferences from disk and updates mixin state when mounted.
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

  /// Toggles timestamp display and persists the new value.
  void setLogViewerShowTimestamp(bool value) {
    setState(() => showTimestamp = value);
    LogViewerPreferences.save(showTimestamp: value, wrapLines: wrapLines);
  }

  /// Toggles line wrapping and persists the new value.
  void setLogViewerWrapLines(bool value) {
    setState(() => wrapLines = value);
    LogViewerPreferences.save(showTimestamp: showTimestamp, wrapLines: value);
  }
}

/// A named Logs search plus container filter snapshot.
class SavedLogFilter {
  /// Creates a saved Logs filter.
  const SavedLogFilter({
    required this.name,
    required this.query,
    required this.matchCase,
    required this.containerNames,
  });

  final String name;
  final String query;
  final bool matchCase;
  final List<String> containerNames;

  /// Decodes a saved filter from JSON, or null when [name] is missing.
  static SavedLogFilter? fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String? ?? '';
    if (name.isEmpty) {
      return null;
    }

    final names = <String>[];
    final rawNames = json['container_names'];
    if (rawNames is List) {
      for (final value in rawNames) {
        if (value is String && value.isNotEmpty) {
          names.add(value);
        }
      }
    }

    return SavedLogFilter(
      name: name,
      query: json['query'] as String? ?? '',
      matchCase: json['match_case'] == true,
      containerNames: names,
    );
  }

  /// Encodes this filter for disk storage.
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'query': query,
      'match_case': matchCase,
      'container_names': containerNames,
    };
  }
}

/// Loads and saves named Logs filters.
class SavedLogFilters {
  /// Loads saved Logs filters from disk.
  static Future<List<SavedLogFilter>> load() async {
    final raw = await CalfUiStorage.readMap(CalfStorageFiles.logsSavedFilters);
    if (raw == null) {
      return const [];
    }

    final items = raw['filters'];
    if (items is! List) {
      return const [];
    }

    final filters = <SavedLogFilter>[];
    for (final item in items) {
      if (item is! Map) {
        continue;
      }
      final filter = SavedLogFilter.fromJson(Map<String, dynamic>.from(item));
      if (filter != null) {
        filters.add(filter);
      }
    }
    return filters;
  }

  /// Persists [filters] to disk.
  static Future<void> save(List<SavedLogFilter> filters) async {
    await CalfUiStorage.writeMap(CalfStorageFiles.logsSavedFilters, {
      'filters': [for (final filter in filters) filter.toJson()],
    });
  }
}
