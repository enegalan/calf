import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/theme/calf_theme.dart';
import 'package:ui/widgets/files_panel.dart';

/// Bottom status bar for engine state, resource usage, and app version.
class AppBottomBar extends StatelessWidget {
  /// Creates the engine status bottom bar.
  const AppBottomBar({
    super.key,
    required this.status,
    required this.appVersion,
    required this.busy,
    required this.onStart,
    required this.onStop,
    required this.onKill,
    required this.onOpenSettings,
    required this.onOpenAbout,
  });

  final DaemonStatus? status;
  final String appVersion;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onKill;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenAbout;

  /// Builds the slim status strip with a corner-anchored engine block.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const barHeight = 32.0;
    final runtime = status?.runtime;
    final running = runtime?.isRunning == true;
    final resources = status?.resources ?? const EngineResources();
    final label = _engineLabel(runtime);
    final badgeColor = running
        ? CalfColors.primary
        : theme.colorScheme.surfaceContainerHighest;
    final badgeForeground = running
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
                      _EngineAction(
                        icon: LucideIcons.play,
                        tooltip: 'Start engine',
                        color: badgeForeground,
                        enabled: !busy && !running,
                        onPressed: onStart,
                      ),
                      _EngineAction(
                        icon: LucideIcons.square,
                        tooltip: 'Stop engine',
                        color: badgeForeground,
                        enabled: !busy && running,
                        onPressed: onStop,
                      ),
                      _EngineAction(
                        icon: LucideIcons.power,
                        tooltip: 'Kill engine',
                        color: badgeForeground,
                        enabled: !busy && running,
                        onPressed: onKill,
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Engine menu',
                        enabled: !busy,
                        padding: EdgeInsets.zero,
                        style: IconButton.styleFrom(
                          foregroundColor: badgeForeground,
                          minimumSize: const Size(28, 28),
                          fixedSize: const Size(28, 28),
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: Icon(
                          LucideIcons.ellipsisVertical,
                          size: 14,
                          color: badgeForeground,
                        ),
                        onSelected: (value) {
                          if (value == 'settings') {
                            onOpenSettings();
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: 'settings',
                            child: Text('Open Settings'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Text(
              'RAM ${_formatPair(resources.memoryUsedBytes, resources.memoryReservedBytes)}'
              '   '
              'CPU ${_formatCpu(resources.cpuPercent)}'
              '   '
              'Disk ${_formatPair(resources.diskUsedBytes, resources.diskReservedBytes)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CalfTheme.muted(theme).copyWith(fontSize: 12),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Tooltip(
                message: 'About Calf',
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

  /// Returns the engine status label for the badge.
  static String _engineLabel(RuntimeStatus? runtime) {
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

  /// Prefixes the version with `v` when missing.
  static String _versionLabel(String version) {
    if (version.isEmpty) {
      return '';
    }
    if (version.startsWith('v') || version == 'unavailable') {
      return version;
    }
    return 'v$version';
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

/// Flat icon control for start/stop/kill on the engine corner block.
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
