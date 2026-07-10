import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/updates/update_info.dart';
import 'package:ui/widgets/calf_button.dart';

Future<void> showUpdateAvailableDialog({
  required BuildContext context,
  required UpdateInfo update,
  required String currentVersion,
  required Future<void> Function() onDownload,
  required Future<void> Function() onSkip,
}) {
  final theme = ShadTheme.of(context);

  return showShadDialog<void>(
    context: context,
    builder: (dialogContext) => ShadDialog(
      scrollable: true,
      constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
      gap: 12,
      title: Text('Update available (${update.version})'),
      description: Text('You are running Calf $currentVersion.'),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (update.releaseNotes.isNotEmpty)
            Text(
              update.releaseNotes,
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.mutedForeground,
              ),
            )
          else
            Text(
              'A newer version is available on GitHub.',
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.mutedForeground,
              ),
            ),
        ],
      ),
    ),
  );
}
