import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'package:ui/platform/open_url.dart';
import 'package:ui/theme/calf_theme.dart';

/// Renders GitHub release-notes markdown with theme-aware styles and link opens.
class ReleaseNotesMarkdown extends StatelessWidget {
  /// Creates a markdown body for [data].
  const ReleaseNotesMarkdown({super.key, required this.data});

  final String data;

  /// Builds selectable markdown styled for dialogs.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface,
      height: 1.45,
    );
    final muted = CalfTheme.muted(theme).copyWith(height: 1.45);

    return MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: body,
        a: body?.copyWith(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
        h1: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        h2: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        h3: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        h4: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        h5: body?.copyWith(fontWeight: FontWeight.w600),
        h6: body?.copyWith(fontWeight: FontWeight.w600),
        listBullet: body,
        strong: body?.copyWith(fontWeight: FontWeight.w700),
        em: body?.copyWith(fontStyle: FontStyle.italic),
        code: body?.copyWith(
          fontFamily: 'monospace',
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        codeblockDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: CalfTheme.radius,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        blockquote: muted,
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: theme.colorScheme.outlineVariant, width: 3),
          ),
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
      ),
      onTapLink: (text, href, title) {
        if (href != null && href.isNotEmpty) {
          openExternalUrl(href);
        }
      },
    );
  }
}
