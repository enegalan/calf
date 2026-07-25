import 'package:flutter/material.dart';

import 'package:ui/theme/calf_theme.dart';

class HoverListRow extends StatefulWidget {
  /// Creates a list row that highlights on hover and optional selection.
  const HoverListRow({
    super.key,
    required this.theme,
    required this.padding,
    required this.child,
    this.selected = false,
    this.onTap,
  });

  final ThemeData theme;
  final EdgeInsets padding;
  final Widget child;
  final bool selected;
  final VoidCallback? onTap;

  /// Creates state for the hoverable list row.
  @override
  State<HoverListRow> createState() => _HoverListRowState();
}

class _HoverListRowState extends State<HoverListRow> {
  bool _hovered = false;

  /// Builds the row with hover and selection background styling.
  @override
  Widget build(BuildContext context) {
    Color? background;
    if (widget.selected) {
      background = widget.theme.colorScheme.surfaceContainerHighest;
    } else if (_hovered) {
      background = widget.theme.colorScheme.surfaceContainerHighest.withValues(
        alpha: 0.45,
      );
    }

    final content = Container(
      color: background,
      padding: widget.padding,
      child: widget.child,
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.onTap == null
          ? content
          : Material(
              animationDuration: CalfTheme.materialAnimationDuration,
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.onTap,
                hoverColor: Colors.transparent,
                splashColor: widget.theme.colorScheme.onSurface.withValues(
                  alpha: 0.06,
                ),
                child: content,
              ),
            ),
    );
  }
}
