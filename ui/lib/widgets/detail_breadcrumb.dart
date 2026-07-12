import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/widgets/calf_button.dart';

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

  /// Builds the breadcrumb row with optional [trailing] actions.
  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Row(
      children: [
        CalfButton.ghost(
          onPressed: onBackEnabled ? onBack : null,
          child: Icon(
            LucideIcons.chevronLeft,
            size: 18,
            color: theme.colorScheme.foreground,
          ),
        ),
        const SizedBox(width: 4),
        for (var index = 0; index < segments.length; index++) ...[
          if (index > 0) Text(' / ', style: theme.textTheme.muted),
          if (index == segments.length - 1)
            Expanded(
              child: Text(
                segments[index],
                style: theme.textTheme.large.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            Text(segments[index], style: theme.textTheme.muted),
        ],
        ?trailing,
      ],
    );
  }
}
