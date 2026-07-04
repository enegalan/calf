import 'dart:convert';
import 'dart:io';

class ContainerGroupPreferences {
  static Future<Map<String, bool>> loadExpanded() async {
    try {
      final file = _file();
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
      final file = _file();
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(expanded));
    } catch (_) {}
  }

  static File _file() {
    final home = Platform.environment['HOME'] ?? '';
    return File('$home/.config/calf/container_groups.json');
  }
}
