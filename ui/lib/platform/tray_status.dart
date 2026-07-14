import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

/// Whether the current platform supports a background tray / menu-bar status icon.
bool get supportsTrayStatusIcon =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows);

const _trayIconAsset = 'assets/tray/calf_tray_white.png';

/// Callbacks invoked from the tray context menu.
typedef CalfTrayOpenCallback = Future<void> Function();
typedef CalfTrayQuitCallback = Future<void> Function();

/// Shows or hides the Calf tray icon on macOS (menu bar) and Windows (system tray).
class CalfTrayStatus {
  CalfTrayStatus._();

  static bool _installed = false;
  static bool _visible = false;
  static CalfTrayOpenCallback? _onOpen;
  static CalfTrayQuitCallback? _onQuit;
  static final _TrayHandler _handler = _TrayHandler();

  /// Registers tray menu callbacks. Call once before [show].
  static void install({
    required CalfTrayOpenCallback onOpen,
    required CalfTrayQuitCallback onQuit,
  }) {
    _onOpen = onOpen;
    _onQuit = onQuit;
    if (!_installed) {
      trayManager.addListener(_handler);
      _installed = true;
    }
  }

  /// Installs the tray icon when supported. Safe to call more than once.
  static Future<void> show() async {
    if (!supportsTrayStatusIcon || _visible) {
      return;
    }

    try {
      await trayManager.setIcon(
        _trayIconAsset,
        isTemplate: false,
        iconSize: 18,
      );
      await trayManager.setToolTip('Calf');

      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'open_calf', label: 'Open Calf'),
            MenuItem.separator(),
            MenuItem(key: 'quit_calf', label: 'Quit Calf'),
          ],
        ),
      );

      _visible = true;
    } on Object catch (e, stack) {
      stderr.writeln('failed to show tray icon: $e');
      stderr.writeln(stack);
    }
  }

  /// Removes the tray icon. Called on app quit.
  static Future<void> hide() async {
    if (!_visible) {
      return;
    }

    await trayManager.destroy();
    _visible = false;
  }

  /// Releases the tray listener. Called on app shutdown.
  static void dispose() {
    if (_installed) {
      trayManager.removeListener(_handler);
      _installed = false;
    }
    _onOpen = null;
    _onQuit = null;
  }
}

/// Forwards tray events to [CalfTrayStatus] callbacks.
class _TrayHandler with TrayListener {
  /// Opens the context menu when the tray icon is clicked.
  @override
  void onTrayIconMouseDown() {
    if (Platform.isMacOS || Platform.isWindows) {
      trayManager.popUpContextMenu();
    }
  }

  /// Opens the context menu on right-click (Windows).
  @override
  void onTrayIconRightMouseDown() {
    if (Platform.isWindows) {
      trayManager.popUpContextMenu();
    }
  }

  /// Handles context menu item selection.
  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open_calf':
        final open = CalfTrayStatus._onOpen;
        if (open != null) {
          open();
        }
        break;
      case 'quit_calf':
        final quit = CalfTrayStatus._onQuit;
        if (quit != null) {
          quit();
        }
        break;
    }
  }
}
