import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/constants/calf_constants.dart';

class StatusDot extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    if (hollow || !active) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: theme.colorScheme.mutedForeground, width: 1.5),
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
        border: Border.all(color: theme.colorScheme.background, width: 1.5),
      ),
    );
  }
}
