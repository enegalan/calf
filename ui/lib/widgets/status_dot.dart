import 'package:flutter/material.dart';

import 'package:ui/constants/calf_constants.dart';

class StatusDot extends StatelessWidget {
  /// Creates a small circular status indicator.
  const StatusDot({
    super.key,
    required this.active,
    this.size = 9,
    this.activeColor,
    this.hollow = false,
  });

  final bool active;
  final double size;
  final Color? activeColor;
  final bool hollow;

  /// Renders a filled, hollow, or inactive status dot.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (hollow || !active) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: theme.colorScheme.onSurfaceVariant,
            width: 1.5,
          ),
        ),
      );
    }

    final color = activeColor ?? CalfColors.success;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: theme.colorScheme.surface, width: 1.5),
      ),
    );
  }
}
