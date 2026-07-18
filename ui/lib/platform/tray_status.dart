import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
typedef CalfTrayUrlCallback = Future<void> Function(String url);
typedef CalfTrayMenuSnapshotCallback = Future<CalfTrayMenuSnapshot> Function();

/// Live data used to render the tray context menu.
class CalfTrayMenuSnapshot {
  /// Creates a [CalfTrayMenuSnapshot] instance.
  const CalfTrayMenuSnapshot({
    this.runningContainerCount = 0,
    this.containersLoadFailed = false,
    this.registryLoggedIn = false,
    this.signInPending = false,
  });

  final int runningContainerCount;
  final bool containersLoadFailed;
  final bool registryLoggedIn;
  final bool signInPending;
}

/// App-level tray actions registered by [AppShell] when the UI is ready.
class CalfTrayAppActions {
  /// Creates a [CalfTrayAppActions] instance.
  const CalfTrayAppActions({
    required this.onOpenSettings,
    required this.onSignIn,
    required this.onSignOut,
    required this.onCheckForUpdates,
    required this.snapshot,
  });

  final void Function() onOpenSettings;
  final Future<void> Function() onSignIn;
  final Future<void> Function() onSignOut;
  final Future<void> Function() onCheckForUpdates;
  final CalfTrayMenuSnapshotCallback snapshot;
}

/// Shows or hides the Calf tray icon on macOS (menu bar) and Windows (system tray).
class CalfTrayStatus {
  CalfTrayStatus._();

  static bool _installed = false;
  static bool _visible = false;
  static CalfTrayOpenCallback? _onOpen;
  static CalfTrayQuitCallback? _onQuit;
  static CalfTrayOpenCallback? _onRestartEngine;
  static CalfTrayUrlCallback? _onOpenUrl;
  static CalfTrayAppActions? _appActions;
  static final _TrayHandler _handler = _TrayHandler();

  /// Registers tray menu callbacks. Call once before [show].
  static void install({
    required CalfTrayOpenCallback onOpen,
    required CalfTrayQuitCallback onQuit,
    CalfTrayOpenCallback? onRestartEngine,
    CalfTrayUrlCallback? onOpenUrl,
  }) {
    _onOpen = onOpen;
    _onQuit = onQuit;
    _onRestartEngine = onRestartEngine;
    _onOpenUrl = onOpenUrl;
    if (!_installed) {
      trayManager.addListener(_handler);
      _installed = true;
    }
  }

  /// Registers UI actions from [AppShell] for settings, registry, and updates.
  static void registerAppActions(CalfTrayAppActions actions) {
    _appActions = actions;
  }

  /// Clears UI actions when [AppShell] is disposed.
  static void unregisterAppActions() {
    _appActions = null;
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
        iconSize: 28,
      );
      await trayManager.setToolTip('Calf');
      await _applyContextMenu(const CalfTrayMenuSnapshot());
      _visible = true;
    } on PlatformException catch (e, stack) {
      stderr.writeln('failed to show tray icon: $e');
      stderr.writeln(stack);
    } on MissingPluginException catch (e, stack) {
      stderr.writeln('failed to show tray icon: $e');
      stderr.writeln(stack);
    }
  }

  /// Refreshes menu labels and opens the context menu.
  static Future<void> popupContextMenu() async {
    if (!_visible) {
      return;
    }

    final snapshot = await _loadSnapshot();
    await _applyContextMenu(snapshot);
    await trayManager.popUpContextMenu();
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
    _onRestartEngine = null;
    _onOpenUrl = null;
    _appActions = null;
  }

  /// Loads live menu data from registered app actions, if any.
  static Future<CalfTrayMenuSnapshot> _loadSnapshot() async {
    final snapshot = _appActions?.snapshot;
    if (snapshot == null) {
      return const CalfTrayMenuSnapshot();
    }

    try {
      return await snapshot();
    } on PlatformException catch (e, stack) {
      stderr.writeln('failed to load tray menu snapshot: $e');
      stderr.writeln(stack);
      return const CalfTrayMenuSnapshot(containersLoadFailed: true);
    } on MissingPluginException catch (e, stack) {
      stderr.writeln('failed to load tray menu snapshot: $e');
      stderr.writeln(stack);
      return const CalfTrayMenuSnapshot(containersLoadFailed: true);
    }
  }

  /// Applies the context menu for the given snapshot.
  static Future<void> _applyContextMenu(CalfTrayMenuSnapshot snapshot) async {
    await trayManager.setContextMenu(Menu(items: _buildMenuItems(snapshot)));
  }

  /// Builds tray menu items from the current snapshot.
  static List<MenuItem> _buildMenuItems(CalfTrayMenuSnapshot snapshot) {
    final containersStatus = _containersStatusLabel(snapshot);
    final loggedIn = snapshot.registryLoggedIn;
    final signInPending = snapshot.signInPending;

    return [
      MenuItem(key: 'open_calf', label: 'Open Calf'),
      MenuItem.separator(),
      MenuItem(key: 'containers_header', label: 'Containers', disabled: true),
      MenuItem(
        key: 'containers_status',
        label: containersStatus,
        disabled: true,
      ),
      MenuItem.separator(),
      MenuItem.submenu(
        key: 'help',
        label: 'Help',
        submenu: Menu(
          items: [
            MenuItem(key: 'help_repository', label: 'GitHub Repository'),
            MenuItem.separator(),
            MenuItem(key: 'help_report', label: 'Report an Issue'),
            MenuItem.separator(),
            MenuItem(key: 'help_restart', label: 'Restart Engine'),
            MenuItem(
              key: 'help_sign_out',
              label: 'Sign Out',
              disabled: !loggedIn,
            ),
            MenuItem.separator(),
            MenuItem(key: 'help_updates', label: 'Check for Updates...'),
          ],
        ),
      ),
      MenuItem(
        key: 'sign_in',
        label: 'Sign In...',
        disabled: loggedIn || signInPending,
      ),
      MenuItem(key: 'settings', label: 'Settings...'),
      MenuItem.separator(),
      MenuItem(key: 'quit_calf', label: 'Quit'),
    ];
  }

  /// Returns the Containers status label for the tray menu.
  static String _containersStatusLabel(CalfTrayMenuSnapshot snapshot) {
    if (snapshot.containersLoadFailed) {
      return 'Unavailable';
    }

    final count = snapshot.runningContainerCount;
    if (count == 0) {
      return 'None running';
    }
    if (count == 1) {
      return '1 running';
    }
    return '$count running';
  }

  /// Opens the main window, then runs an optional async action.
  static Future<void> _openWindowAnd(Future<void> Function()? action) async {
    final open = _onOpen;
    if (open != null) {
      await open();
    }
    if (action != null) {
      await action();
    }
  }

  /// Opens the main window, then runs an optional sync action.
  static Future<void> _openWindowAndSync(void Function()? action) async {
    final open = _onOpen;
    if (open != null) {
      await open();
    }
    action?.call();
  }

  /// Dispatches a tray menu item click by key.
  static Future<void> _handleMenuClick(String key) async {
    final app = _appActions;

    switch (key) {
      case 'open_calf':
        await _onOpen?.call();
        break;
      case 'help_repository':
        await _onOpenUrl?.call('https://github.com/enegalan/calf');
        break;
      case 'help_report':
        await _onOpenUrl?.call('https://github.com/enegalan/calf/issues/new');
        break;
      case 'help_restart':
        await _onRestartEngine?.call();
        break;
      case 'help_sign_out':
        if (app != null) {
          await _openWindowAnd(app.onSignOut);
        }
        break;
      case 'help_updates':
        if (app != null) {
          await _openWindowAnd(app.onCheckForUpdates);
        }
        break;
      case 'sign_in':
        if (app != null) {
          await _openWindowAnd(app.onSignIn);
        }
        break;
      case 'settings':
        if (app != null) {
          await _openWindowAndSync(app.onOpenSettings);
        } else {
          await _onOpen?.call();
        }
        break;
      case 'quit_calf':
        await _onQuit?.call();
        break;
    }
  }
}

/// Forwards tray events to [CalfTrayStatus] callbacks.
class _TrayHandler with TrayListener {
  /// Refreshes and opens the context menu when the tray icon is clicked.
  @override
  void onTrayIconMouseDown() {
    if (Platform.isMacOS || Platform.isWindows) {
      unawaited(CalfTrayStatus.popupContextMenu());
    }
  }

  /// Opens the context menu on right-click (Windows).
  @override
  void onTrayIconRightMouseDown() {
    if (Platform.isWindows) {
      unawaited(CalfTrayStatus.popupContextMenu());
    }
  }

  /// Handles context menu item selection.
  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key;
    if (key == null || key.isEmpty) {
      return;
    }
    unawaited(CalfTrayStatus._handleMenuClick(key));
  }
}
