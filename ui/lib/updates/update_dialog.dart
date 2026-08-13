import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/constants/calf_constants.dart';
import 'package:ui/theme/calf_theme.dart';
import 'package:ui/updates/update_info.dart';
import 'package:ui/widgets/calf_button.dart';

/// Shows a dialog prompting the user to download an available update.
Future<void> showUpdateAvailableDialog({
  required BuildContext context,
  required UpdateInfo update,
  required String currentVersion,
  required Future<void> Function() onDownload,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      final currentLabel = CalfVersion.displayLabel(currentVersion);
      final latestLabel = CalfVersion.displayLabel(update.version);

      return AlertDialog(
        shape: CalfTheme.dialogShape(theme.colorScheme),
        titlePadding: EdgeInsets.zero,
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
        actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
        content: SizedBox(
          width: 420,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: CalfTheme.radius,
                ),
                alignment: Alignment.center,
                child: Icon(
                  LucideIcons.download,
                  size: 22,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Update available',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'A newer calf release is ready to install.',
                      style: CalfTheme.muted(theme).copyWith(fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    _VersionUpgradeRow(
                      currentVersion: currentLabel,
                      latestVersion: latestLabel,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          CalfButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Later'),
          ),
          CalfButton(
            onPressed: () async {
              await onDownload();
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: const Text('Download'),
          ),
        ],
      );
    },
  );
}

/// Current → latest version chips for the update prompt.
class _VersionUpgradeRow extends StatelessWidget {
  /// Creates the version comparison row.
  const _VersionUpgradeRow({
    required this.currentVersion,
    required this.latestVersion,
  });

  final String currentVersion;
  final String latestVersion;

  /// Builds the chip row with an arrow between versions.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        _VersionChip(label: currentVersion, emphasized: false),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Icon(
            LucideIcons.arrowRight,
            size: 13,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
        _VersionChip(label: latestVersion, emphasized: true),
      ],
    );
  }
}

/// Compact version label used in the update header.
class _VersionChip extends StatelessWidget {
  /// Creates a version chip; [emphasized] marks the newest release quietly.
  const _VersionChip({required this.label, required this.emphasized});

  final String label;
  final bool emphasized;

  /// Builds a muted version pill (latest is only slightly stronger).
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = emphasized
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: emphasized ? 0.9 : 0.45,
        ),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(
            alpha: emphasized ? 1 : 0.55,
          ),
        ),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: foreground,
          fontWeight: emphasized ? FontWeight.w600 : FontWeight.w500,
          fontFamily: CalfFonts.mono,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
