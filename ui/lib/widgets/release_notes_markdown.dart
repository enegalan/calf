import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'package:ui/constants/calf_constants.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/theme/calf_theme.dart';

/// Matches `in https://github.com/org/repo/pull/123` in auto-generated notes.
final RegExp _pullRequestUrlPattern = RegExp(
  r'in (https://github\.com/[^/\s]+/[^/\s]+/pull/(\d+))',
);

/// Matches `**Full Changelog**: https://...` at the end of GitHub notes.
final RegExp _fullChangelogPattern = RegExp(
  r'\*\*Full Changelog\*\*:\s*(https://\S+)',
  caseSensitive: false,
);

/// Normalizes GitHub release-note markdown for readable in-app rendering.
String normalizeReleaseNotesMarkdown(String raw) {
  var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (text.isEmpty) {
    return text;
  }

  text = text.replaceAllMapped(
    _pullRequestUrlPattern,
    (match) => 'in [#${match.group(2)}](${match.group(1)})',
  );
  text = text.replaceAllMapped(
    _fullChangelogPattern,
    (match) => '[Full changelog](${match.group(1)})',
  );
  return text;
}

/// Renders GitHub release-notes markdown with theme-aware styles and link opens.
class ReleaseNotesMarkdown extends StatelessWidget {
  /// Creates a markdown body for [data].
  const ReleaseNotesMarkdown({super.key, required this.data});

  final String data;

  /// Builds selectable markdown styled for dialogs.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurface,
      height: 1.5,
      fontSize: 13,
    );
    final muted = CalfTheme.muted(theme).copyWith(height: 1.5, fontSize: 13);
    final normalized = normalizeReleaseNotesMarkdown(data);

    return MarkdownBody(
      data: normalized,
      selectable: true,
      softLineBreak: true,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: body,
        pPadding: const EdgeInsets.only(bottom: 8),
        a: body?.copyWith(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: theme.colorScheme.primary.withValues(alpha: 0.45),
        ),
        h1: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: 18,
          height: 1.3,
        ),
        h1Padding: const EdgeInsets.only(top: 4, bottom: 10),
        h2: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: 15,
          height: 1.3,
        ),
        h2Padding: const EdgeInsets.only(top: 4, bottom: 8),
        h3: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: 13.5,
          height: 1.3,
        ),
        h3Padding: const EdgeInsets.only(top: 2, bottom: 6),
        h4: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
        h5: body?.copyWith(fontWeight: FontWeight.w600),
        h6: body?.copyWith(fontWeight: FontWeight.w600),
        listBullet: body,
        listIndent: 20,
        listBulletPadding: const EdgeInsets.only(right: 8),
        strong: body?.copyWith(fontWeight: FontWeight.w700),
        em: body?.copyWith(fontStyle: FontStyle.italic),
        code: body?.copyWith(
          fontFamily: CalfFonts.mono,
          fontSize: 12.5,
          backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.7),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        codeblockDecoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.7),
          borderRadius: CalfTheme.radius,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        blockquote: muted,
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: theme.colorScheme.outlineVariant, width: 3),
          ),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        blockSpacing: 8,
      ),
      onTapLink: (text, href, title) {
        if (href != null && href.isNotEmpty) {
          openExternalUrl(href);
        }
      },
    );
  }
}
