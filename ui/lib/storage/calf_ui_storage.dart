import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class CalfUiStorage {
  static Future<File> file(String name) async {
    final home = _homeDirectory();
    if (home.isNotEmpty) {
      return File(p.join(home, '.config', 'calf', 'ui', name));
    }

    final supportDir = await getApplicationSupportDirectory();
    return File(p.join(supportDir.path, 'calf', 'ui', name));
  }

  static Future<Map<String, dynamic>?> readMap(String name) async {
    try {
      final file = await CalfUiStorage.file(name);
      if (!file.existsSync()) {
        return null;
      }

      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        return null;
      }

      return raw;
    } on FileSystemException catch (error) {
      debugPrint('Failed to read $name: $error');
      return null;
    } on FormatException catch (error) {
      debugPrint('Failed to parse $name: $error');
      return null;
    }
  }

  static Future<void> writeMap(String name, Map<String, dynamic> data) async {
    try {
      final file = await CalfUiStorage.file(name);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(data));
    } on FileSystemException catch (error) {
      debugPrint('Failed to write $name: $error');
    }
  }

  static String _homeDirectory() {
    if (Platform.isWindows) {
      return Platform.environment['USERPROFILE'] ?? '';
    }

    return Platform.environment['HOME'] ?? '';
  }
}
