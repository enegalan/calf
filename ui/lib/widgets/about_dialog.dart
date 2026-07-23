import 'package:flutter/material.dart';

import 'package:ui/platform/open_url.dart';
import 'package:ui/widgets/calf_button.dart';

/// Shows the About Calf dialog with version info and links.
void showAboutCalfDialog(BuildContext context, {required String appVersion}) {
  final theme = Theme.of(context);
  final logoAsset = theme.brightness == Brightness.dark
      ? 'assets/brand/calf_logo_white.png'
      : 'assets/brand/calf_logo_black.png';
  final versionLabel = appVersion.isEmpty ? 'dev' : appVersion;

  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Calf'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Version $versionLabel'),
            const SizedBox(height: 16),
            Image.asset(logoAsset, width: 48, height: 48, fit: BoxFit.contain),
            const SizedBox(height: 16),
            Text(
              'A lightweight alternative to Docker Desktop.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _AboutLink(
                  label: 'GitHub',
                  onPressed: () =>
                      _openExternalLink(dialogContext, calfRepositoryUrl),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'MIT License · © ${DateTime.now().year}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        CalfButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// Opens [url] externally and shows an error dialog if that fails.
Future<void> _openExternalLink(BuildContext context, String url) async {
  final opened = await openExternalUrl(url);
  if (!opened && context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (errorContext) => AlertDialog(
        title: const Text('Could not open link'),
        content: const Text('Your system could not open the URL in a browser.'),
        actions: [
          CalfButton(
            onPressed: () => Navigator.of(errorContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

class _AboutLink extends StatelessWidget {
  /// Renders a text link styled for the About dialog.
  const _AboutLink({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  /// Builds the styled text link button.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CalfButton.ghost(
      padding: EdgeInsets.zero,
      height: 28,
      onPressed: onPressed,
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
