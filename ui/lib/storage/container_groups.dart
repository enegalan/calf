import 'package:ui/constants/calf_constants.dart';
import 'package:ui/storage/calf_ui_storage.dart';

class ContainerGroupPreferences {
  static Future<Map<String, bool>> loadExpanded() async {
    final raw = await CalfUiStorage.readMap(CalfStorageFiles.containerGroups);
    if (raw == null) {
      return {};
    }

    return raw.map((key, value) => MapEntry(key, value == true));
  }

  static Future<void> saveExpanded(Map<String, bool> expanded) async {
    await CalfUiStorage.writeMap(CalfStorageFiles.containerGroups, expanded);
  }
}
