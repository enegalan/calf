import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/widgets/calf_button.dart';
import 'package:ui/theme/calf_theme.dart';

class DetailBreadcrumb extends StatelessWidget {
  /// Creates a back button and slash-separated [segments] breadcrumb trail.
  const DetailBreadcrumb({
    super.key,
    required this.segments,
    required this.onBack,
    this.onBackEnabled = true,
    this.trailing,
  });

  final List<String> segments;
  final VoidCallback? onBack;
  final bool onBackEnabled;
  final Widget? trailing;

  /// Builds an accessible breadcrumb row with optional [trailing] actions.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canGoBack = onBackEnabled && onBack != null;

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Breadcrumb',
      child: Row(
        children: [
          Tooltip(
            message: 'Go back',
            child: Semantics(
              button: true,
              enabled: canGoBack,
              label: 'Go back',
              excludeSemantics: true,
              child: CalfButton.ghost(
                onPressed: canGoBack ? onBack : null,
                width: 36,
                height: 36,
                padding: EdgeInsets.zero,
                child: Icon(
                  LucideIcons.chevronLeft,
                  size: 18,
                  color: canGoBack
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          for (var index = 0; index < segments.length; index++) ...[
            if (index > 0)
              ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    '/',
                    style: CalfTheme.muted(
                      theme,
                    ).copyWith(fontWeight: FontWeight.w400),
                  ),
                ),
              ),
            if (index == segments.length - 1)
              Expanded(
                child: _BreadcrumbSegment(
                  label: segments[index],
                  isCurrent: true,
                ),
              )
            else
              _BreadcrumbSegment(
                label: segments[index],
                isCurrent: false,
                onTap: canGoBack ? onBack : null,
              ),
          ],
          ?trailing,
        ],
      ),
    );
  }
}

class _BreadcrumbSegment extends StatelessWidget {
  /// Creates one breadcrumb crumb; [isCurrent] marks the active page.
  const _BreadcrumbSegment({
    required this.label,
    required this.isCurrent,
    this.onTap,
  });

  final String label;
  final bool isCurrent;
  final VoidCallback? onTap;

  /// Builds a current-page label or a tappable parent crumb.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (isCurrent) {
      return Semantics(
        header: true,
        selected: true,
        child: Text(
          label,
          style: theme.textTheme.titleMedium!.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      );
    }

    return Semantics(
      button: true,
      enabled: onTap != null,
      label: 'Go to $label',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: onTap != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: InkWell(
          onTap: onTap,
          borderRadius: CalfTheme.radius,
          hoverColor: theme.colorScheme.primary.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Text(
              label,
              style: CalfTheme.muted(
                theme,
              ).copyWith(fontWeight: FontWeight.w500),
            ),
          ),
        ),
      ),
    );
  }
}
