import 'dart:io';

class CalfUiStorage {
  static File file(String name) {
    final home = Platform.environment['HOME'] ?? '';
    return File('$home/.config/calf/ui/$name');
  }
}
