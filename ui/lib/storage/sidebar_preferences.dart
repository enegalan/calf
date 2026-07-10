import 'package:ui/constants/calf_constants.dart';
import 'package:ui/storage/calf_ui_storage.dart';

class SidebarPreferences {
  static const bool defaultCollapsed = false;

  static Future<bool> loadCollapsed() async {
    final raw = await CalfUiStorage.readMap(CalfStorageFiles.sidebar);
    if (raw == null) {
      return defaultCollapsed;
    }

    return raw['collapsed'] == true;
  }

  static Future<void> saveCollapsed(bool collapsed) async {
    await CalfUiStorage.writeMap(CalfStorageFiles.sidebar, {'collapsed': collapsed});
  }
}
