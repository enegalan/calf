import 'dart:io';

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

  static String _homeDirectory() {
    if (Platform.isWindows) {
      return Platform.environment['USERPROFILE'] ?? '';
    }

    return Platform.environment['HOME'] ?? '';
  }
}
