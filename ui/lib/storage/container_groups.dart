import 'dart:convert';

import 'package:ui/storage/calf_ui_storage.dart';

class ContainerGroupPreferences {
  static Future<Map<String, bool>> loadExpanded() async {
    try {
      final file = CalfUiStorage.file('container_groups.json');
      if (!file.existsSync()) {
        return {};
      }

      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        return {};
      }

      return raw.map((key, value) => MapEntry(key, value == true));
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveExpanded(Map<String, bool> expanded) async {
    try {
      final file = CalfUiStorage.file('container_groups.json');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(expanded));
    } catch (_) {}
  }
}
