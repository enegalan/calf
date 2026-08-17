import 'package:ui/storage/calf_ui_storage.dart';
import 'package:ui/constants/calf_constants.dart';

/// Persists whether the main window should open when calf launches.
class WindowPreferences {
  /// Loads the open-window-on-launch preference (default true).
  static Future<bool> loadOpenOnLaunch() async {
    final data = await CalfUiStorage.readMap(CalfStorageFiles.window);
    if (data == null) {
      return true;
    }
    return data['open_on_launch'] as bool? ?? true;
  }

  /// Saves the open-window-on-launch preference.
  static Future<void> saveOpenOnLaunch(bool value) async {
    await CalfUiStorage.writeMap(CalfStorageFiles.window, {
      'open_on_launch': value,
    });
  }
}
