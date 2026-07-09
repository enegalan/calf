import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:ui/widgets/about_dialog.dart';

bool get supportsNativeMacosMenu =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

PlatformMenuItem? _platformMenu(PlatformProvidedMenuItemType type) {
  if (!PlatformProvidedMenuItem.hasMenu(type)) {
    return null;
  }
  return PlatformProvidedMenuItem(type: type);
}

/// Wraps [child] with a native macOS menu bar. Returns [child] unchanged on other platforms.
class MacosMenuScope extends StatelessWidget {
  const MacosMenuScope({
    super.key,
    required this.child,
    required this.appVersion,
    required this.loggedIn,
    required this.signInPending,
    required this.onOpenSettings,
    required this.onCheckForUpdates,
    required this.onOpenWhatsNew,
    required this.onSignIn,
    required this.onSignOut,
    required this.onOpenAccountSettings,
    required this.onNavigateToSection,
    required this.onToggleSidebar,
    required this.onReportIssue,
    required this.onOpenRepository,
  });

  final Widget child;
  final String appVersion;
  final bool loggedIn;
  final bool signInPending;
  final VoidCallback onOpenSettings;
  final VoidCallback onCheckForUpdates;
  final VoidCallback onOpenWhatsNew;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;
  final VoidCallback onOpenAccountSettings;
  final ValueChanged<int> onNavigateToSection;
  final VoidCallback onToggleSidebar;
  final VoidCallback onReportIssue;
  final VoidCallback onOpenRepository;

  static const _sectionLabels = [
    'Containers',
    'Images',
    'Volumes',
    'Networks',
    'Builds',
  ];

  List<PlatformMenuItem> _buildMenus(BuildContext context) {
    final appMenuItems = <PlatformMenuItem>[
      PlatformMenuItem(
        label: 'About Calf',
        onSelected: () => showAboutCalfDialog(context, appVersion: appVersion),
      ),
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'Preferences…',
            shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
            onSelected: onOpenSettings,
          ),
          PlatformMenuItem(
            label: 'Check for Updates…',
            onSelected: onCheckForUpdates,
          ),
          PlatformMenuItem(
            label: "What's New…",
            onSelected: onOpenWhatsNew,
          ),
        ],
      ),
      ?_platformMenu(PlatformProvidedMenuItemType.servicesSubmenu),
      PlatformMenuItemGroup(
        members: [
          ?_platformMenu(PlatformProvidedMenuItemType.hide),
          ?_platformMenu(PlatformProvidedMenuItemType.hideOtherApplications),
          ?_platformMenu(PlatformProvidedMenuItemType.showAllApplications),
        ],
      ),
      ?_platformMenu(PlatformProvidedMenuItemType.quit),
    ];

    final viewMenuItems = <PlatformMenuItem>[
      for (var index = 0; index < _sectionLabels.length; index++)
        PlatformMenuItem(
          label: _sectionLabels[index],
          shortcut: SingleActivator(
            LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + index),
            meta: true,
          ),
          onSelected: () => onNavigateToSection(index),
        ),
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'Toggle Sidebar',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyS,
              meta: true,
              shift: true,
            ),
            onSelected: onToggleSidebar,
          ),
          ?_platformMenu(PlatformProvidedMenuItemType.toggleFullScreen),
        ],
      ),
    ];

    final windowMenuItems = <PlatformMenuItem>[
      ?_platformMenu(PlatformProvidedMenuItemType.minimizeWindow),
      ?_platformMenu(PlatformProvidedMenuItemType.zoomWindow),
      PlatformMenuItemGroup(
        members: [
          ?_platformMenu(PlatformProvidedMenuItemType.arrangeWindowsInFront),
        ],
      ),
    ];

    return [
      PlatformMenu(label: 'Calf', menus: appMenuItems),
      PlatformMenu(label: 'Navigate', menus: viewMenuItems),
      PlatformMenu(
        label: 'Account',
        menus: [
          PlatformMenuItem(
            label: 'Sign in to Docker Hub…',
            onSelected: signInPending || loggedIn ? null : onSignIn,
          ),
          PlatformMenuItem(
            label: 'Account Settings',
            onSelected: loggedIn ? onOpenAccountSettings : null,
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: 'Sign Out',
                onSelected: loggedIn ? onSignOut : null,
              ),
            ],
          ),
        ],
      ),
      PlatformMenu(label: 'Window', menus: windowMenuItems),
      PlatformMenu(
        label: 'Help',
        menus: [
          PlatformMenuItem(
            label: 'Report an Issue',
            onSelected: onReportIssue,
          ),
          PlatformMenuItem(
            label: 'GitHub Repository',
            onSelected: onOpenRepository,
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!supportsNativeMacosMenu) {
      return child;
    }

    return PlatformMenuBar(
      menus: _buildMenus(context),
      child: child,
    );
  }
}
