import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';

/// Whether the current platform supports a background tray / menu-bar status icon.
bool get supportsTrayStatusIcon =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows);

/// Shows or hides the Calf tray icon on macOS (menu bar) and Windows (system tray).
class CalfTrayStatus {
  CalfTrayStatus._();

  static bool _initialized = false;
  static bool _visible = false;

  /// Installs the tray icon when supported. Safe to call more than once.
  static Future<void> show() async {
    if (!supportsTrayStatusIcon || _visible) {
      return;
    }

    if (!_initialized) {
      await trayManager.setToolTip('Calf');
      _initialized = true;
    }

    final iconPath = await _resolveTrayIconPath();
    if (Platform.isMacOS) {
      await trayManager.setIcon(iconPath, isTemplate: true);
    } else {
      await trayManager.setIcon(iconPath);
    }
    _visible = true;
  }

  /// Removes the tray icon. Called on app quit.
  static Future<void> hide() async {
    if (!_visible) {
      return;
    }

    await trayManager.destroy();
    _visible = false;
    _initialized = false;
  }

  /// Writes the bundled tray asset to a temp file path the native plugin can load.
  static Future<String> _resolveTrayIconPath() async {
    final assetPath = Platform.isWindows
        ? 'assets/tray/calf_tray.ico'
        : 'assets/tray/calf_tray.png';
    final bytes = await rootBundle.load(assetPath);
    final tempDir = await getTemporaryDirectory();
    final fileName = Platform.isWindows ? 'calf_tray.ico' : 'calf_tray.png';
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
    return file.path;
  }
}
