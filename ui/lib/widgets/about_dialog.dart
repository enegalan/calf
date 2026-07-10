import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/platform/open_url.dart';
import 'package:ui/widgets/calf_button.dart';

void showAboutCalfDialog(BuildContext context, {required String appVersion}) {
  final theme = ShadTheme.of(context);
  final logoAsset = theme.brightness == Brightness.dark
      ? 'assets/brand/calf_logo_white.png'
      : 'assets/brand/calf_logo_black.png';
  final versionLabel = appVersion.isEmpty ? 'dev' : appVersion;

  showShadDialog<void>(
    context: context,
    builder: (dialogContext) => ShadDialog(
      scrollable: false,
      constraints: const BoxConstraints(maxWidth: 320),
      gap: 16,
      title: const Text('Calf'),
      description: Text('Version $versionLabel'),
      actions: [
        CalfButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(logoAsset, width: 48, height: 48, fit: BoxFit.contain),
          const SizedBox(height: 16),
          Text(
            'A lightweight alternative to Docker Desktop.',
            textAlign: TextAlign.center,
            style: theme.textTheme.small.copyWith(
              color: theme.colorScheme.mutedForeground,
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
            style: theme.textTheme.small.copyWith(
              color: theme.colorScheme.mutedForeground,
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> _openExternalLink(BuildContext context, String url) async {
  final opened = await openExternalUrl(url);
  if (!opened && context.mounted) {
    await showShadDialog<void>(
      context: context,
      builder: (errorContext) => ShadDialog(
        title: const Text('Could not open link'),
        description: const Text(
          'Your system could not open the URL in a browser.',
        ),
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
  const _AboutLink({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return CalfButton.ghost(
      padding: EdgeInsets.zero,
      height: 28,
      onPressed: onPressed,
      child: Text(
        label,
        style: theme.textTheme.small.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
