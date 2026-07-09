import 'dart:convert';
import 'package:ui/storage/calf_ui_storage.dart';

class SidebarPreferences {
  static const bool defaultCollapsed = false;

  static Future<bool> loadCollapsed() async {
    try {
      final file = await CalfUiStorage.file('sidebar.json');
      if (!file.existsSync()) {
        return defaultCollapsed;
      }

      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        return defaultCollapsed;
      }

      return raw['collapsed'] == true;
    } catch (_) {
      return defaultCollapsed;
    }
  }

  static Future<void> saveCollapsed(bool collapsed) async {
    try {
      final file = await CalfUiStorage.file('sidebar.json');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode({'collapsed': collapsed}));
    } catch (_) {}
  }
}
