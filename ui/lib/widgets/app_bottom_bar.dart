import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/theme/calf_theme.dart';
import 'package:ui/utils/format.dart';
import 'package:ui/widgets/calf_popup_menu.dart';

/// Bottom status bar for engine state, resource usage, and app version.
class AppBottomBar extends StatelessWidget {
  /// Creates the engine status bottom bar.
  const AppBottomBar({
    super.key,
    required this.status,
    required this.appVersion,
    required this.busy,
    required this.pendingAction,
    required this.loggedIn,
    required this.signInPending,
    required this.updateAvailable,
    required this.onStart,
    required this.onStop,
    required this.onOpenSettings,
    required this.onOpenAbout,
    required this.onSignIn,
    required this.onSignOut,
    required this.onTroubleshoot,
    required this.onOpenDockerHub,
    required this.onDownloadUpdate,
    required this.onRestart,
    required this.onQuit,
  });

  final DaemonStatus? status;
  final String appVersion;
  final bool busy;

  /// Non-empty while Start/Stop is in flight (e.g. `Engine starting…`).
  final String pendingAction;
  final bool loggedIn;
  final bool signInPending;
  final bool updateAvailable;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenAbout;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;
  final VoidCallback onTroubleshoot;
  final VoidCallback onOpenDockerHub;
  final VoidCallback onDownloadUpdate;
  final VoidCallback onRestart;
  final VoidCallback onQuit;

  /// Builds the slim status strip with a corner-anchored engine block.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const barHeight = 32.0;
    final runtime = status?.runtime;
    final running = runtime?.isRunning == true;
    final resourceSaver = status?.resourceSaverActive == true;
    final resources = status?.resources ?? const EngineResources();
    final pending = pendingAction.isNotEmpty;
    final label = pending
        ? pendingAction
        : _engineLabel(runtime, resourceSaver: resourceSaver);
    final activeBadge = pending || running || resourceSaver;
    final badgeColor = activeBadge
        ? CalfColors.primary
        : theme.colorScheme.surfaceContainerHighest;
    final badgeForeground = activeBadge
        ? Colors.white
        : theme.colorScheme.onSurfaceVariant;

    return SizedBox(
      height: barHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            Material(
              animationDuration: CalfTheme.materialAnimationDuration,
              color: badgeColor,
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(6),
              ),
              child: SizedBox(
                height: barHeight,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (pending)
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: badgeForeground,
                          ),
                        )
                      else
                        Icon(
                          LucideIcons.container,
                          size: 14,
                          color: badgeForeground,
                        ),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: badgeForeground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 4),
                      if (running)
                        _EngineAction(
                          icon: LucideIcons.pause,
                          tooltip: 'Stop engine',
                          color: badgeForeground,
                          enabled: !busy,
                          onPressed: onStop,
                        )
                      else
                        _EngineAction(
                          icon: LucideIcons.play,
                          tooltip: 'Start engine',
                          color: badgeForeground,
                          enabled: !busy,
                          onPressed: onStart,
                        ),
                      CalfPopupMenuButton<String>(
                        tooltip: 'Engine menu',
                        enabled: !busy,
                        iconSize: 14,
                        iconColor: badgeForeground,
                        style: IconButton.styleFrom(
                          animationDuration:
                              CalfTheme.materialAnimationDuration,
                          foregroundColor: badgeForeground,
                          minimumSize: const Size(28, 28),
                          fixedSize: const Size(28, 28),
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onSelected: (value) => _handleMenu(value),
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            enabled: false,
                            height: 36,
                            child: Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: activeBadge
                                        ? CalfColors.success
                                        : theme.colorScheme.onSurfaceVariant,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _menuStatusLabel(
                                      runtime,
                                      resourceSaver: resourceSaver,
                                    ),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            value: loggedIn ? 'sign_out' : 'sign_in',
                            enabled: loggedIn || !signInPending,
                            child: CalfPopupMenuRow(
                              icon: LucideIcons.user,
                              label: loggedIn
                                  ? 'Sign out'
                                  : (signInPending
                                        ? 'Signing in…'
                                        : 'Sign in / Sign up'),
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'settings',
                            child: CalfPopupMenuRow(
                              icon: LucideIcons.settings,
                              label: 'Settings…',
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'troubleshoot',
                            child: CalfPopupMenuRow(
                              icon: LucideIcons.wrench,
                              label: 'Troubleshoot',
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'about',
                            child: CalfPopupMenuRow(
                              icon: LucideIcons.info,
                              label: 'About calf',
                            ),
                          ),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: 'docker_hub',
                            child: CalfPopupMenuRow(
                              icon: LucideIcons.box,
                              label: 'Docker Hub',
                            ),
                          ),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            value: 'download_update',
                            child: CalfPopupMenuRow(
                              icon: updateAvailable
                                  ? LucideIcons.circleAlert
                                  : LucideIcons.download,
                              label: updateAvailable
                                  ? 'Download update'
                                  : 'Check for updates',
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'restart',
                            child: CalfPopupMenuRow(
                              icon: LucideIcons.refreshCw,
                              label: 'Restart',
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'quit',
                            child: CalfPopupMenuRow(
                              icon: LucideIcons.power,
                              label: 'Quit calf',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Tooltip(
                    message: 'Open Settings',
                    child: InkWell(
                      onTap: onOpenSettings,
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        child: Text(
                          'RAM ${_formatPair(resources.memoryUsedBytes, resources.memoryReservedBytes)}'
                          '   '
                          'CPU ${_formatCpu(resources.cpuPercent)}'
                          '   '
                          'Disk ${_formatPair(resources.diskUsedBytes, resources.diskReservedBytes)}',
                          maxLines: 1,
                          softWrap: false,
                          style: CalfTheme.muted(theme).copyWith(fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Tooltip(
                message: 'About calf',
                child: InkWell(
                  onTap: onOpenAbout,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Text(
                      _versionLabel(appVersion),
                      textAlign: TextAlign.right,
                      style: CalfTheme.muted(theme).copyWith(fontSize: 12),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Dispatches a bottom-bar overflow menu selection.
  void _handleMenu(String value) {
    switch (value) {
      case 'sign_in':
        onSignIn();
      case 'sign_out':
        onSignOut();
      case 'settings':
        onOpenSettings();
      case 'troubleshoot':
        onTroubleshoot();
      case 'about':
        onOpenAbout();
      case 'docker_hub':
        onOpenDockerHub();
      case 'download_update':
        onDownloadUpdate();
      case 'restart':
        onRestart();
      case 'quit':
        onQuit();
    }
  }

  /// Returns the engine status label for the badge.
  static String _engineLabel(
    RuntimeStatus? runtime, {
    required bool resourceSaver,
  }) {
    if (resourceSaver) {
      return 'Resource Saver';
    }
    if (runtime == null) {
      return 'Engine unknown';
    }
    if (runtime.isRunning) {
      return 'Engine running';
    }
    if (runtime.state == 'stopped') {
      return 'Engine stopped';
    }
    return 'Engine ${runtime.state}';
  }

  /// Returns the overflow-menu status line.
  static String _menuStatusLabel(
    RuntimeStatus? runtime, {
    required bool resourceSaver,
  }) {
    if (resourceSaver) {
      return 'Running in Resource Saver mode';
    }
    if (runtime?.isRunning == true) {
      return 'Engine running';
    }
    if (runtime?.state == 'stopped') {
      return 'Engine stopped';
    }
    if (runtime == null) {
      return 'Engine unknown';
    }
    return 'Engine ${runtime.state}';
  }

  /// Returns a display version label, falling back to `dev` when empty.
  static String _versionLabel(String version) {
    final label = CalfVersion.displayLabel(version);
    if (label == 'dev' || label.startsWith('v') || label == 'unavailable') {
      return label;
    }
    return 'v$label';
  }

  /// Formats used/reserved bytes as `1.1 GB / 4.0 GB`.
  static String _formatPair(int usedBytes, int reservedBytes) {
    return '${formatFileSize(usedBytes)} / ${formatFileSize(reservedBytes)}';
  }

  /// Formats CPU percent as `4.96%`.
  static String _formatCpu(double percent) {
    if (percent <= 0) {
      return '0%';
    }
    if (percent < 10) {
      return '${percent.toStringAsFixed(2)}%';
    }
    return '${percent.toStringAsFixed(1)}%';
  }
}

/// Flat icon control for start/stop on the engine corner block.
class _EngineAction extends StatelessWidget {
  /// Creates a compact engine control icon button.
  const _EngineAction({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final bool enabled;
  final VoidCallback onPressed;

  /// Builds a borderless icon hit target matching the badge foreground.
  @override
  Widget build(BuildContext context) {
    final foreground = enabled ? color : color.withValues(alpha: 0.35);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 14, color: foreground),
        ),
      ),
    );
  }
}
