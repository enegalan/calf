import 'package:flutter/material.dart';

import 'package:ui/updates/update_info.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/release_notes_markdown.dart';

/// Shows a dialog prompting the user to download or skip an available update.
Future<void> showUpdateAvailableDialog({
  required BuildContext context,
  required UpdateInfo update,
  required String currentVersion,
  required Future<void> Function() onDownload,
  required Future<void> Function() onSkip,
}) {
  final theme = Theme.of(context);

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Update available (${update.version})'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('You are running Calf $currentVersion.'),
              const SizedBox(height: 12),
              if (update.releaseNotes.isNotEmpty)
                ReleaseNotesMarkdown(data: update.releaseNotes)
              else
                Text(
                  'A newer version is available on GitHub.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        CalfButton.outline(
          onPressed: () async {
            await onSkip();
            if (dialogContext.mounted) {
              Navigator.of(dialogContext).pop();
            }
          },
          child: const Text('Skip this version'),
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
    ),
  );
}
