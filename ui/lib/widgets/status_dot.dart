import 'package:flutter/material.dart';

import 'package:ui/constants/calf_constants.dart';

/// Visual state for a compact status indicator.
enum StatusDotState {
  /// Fully active / running / in use.
  active,

  /// Inactive / stopped / not in use (hollow ring).
  inactive,

  /// Mixed state (some running, some stopped).
  partial,
}

class StatusDot extends StatelessWidget {
  /// Creates a small circular status indicator.
  const StatusDot({
    super.key,
    required this.active,
    this.size = 9,
    this.activeColor,
    this.hollow = false,
    this.tooltip,
  }) : state = null;

  /// Creates a status indicator from an explicit [state].
  const StatusDot.fromState({
    super.key,
    required this.state,
    this.size = 9,
    this.activeColor,
    this.tooltip,
  }) : active = state == StatusDotState.active,
       hollow = state == StatusDotState.inactive;

  final bool active;
  final double size;
  final Color? activeColor;
  final bool hollow;
  final String? tooltip;
  final StatusDotState? state;

  /// Renders a filled, hollow, partial, or inactive status dot.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolved = state ??
        (hollow || !active
            ? StatusDotState.inactive
            : StatusDotState.active);

    final Widget dot;
    switch (resolved) {
      case StatusDotState.inactive:
        dot = Container(
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
      case StatusDotState.partial:
        final color = activeColor ?? CalfColors.success;
        dot = SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _PartialDotPainter(
              color: color,
              borderColor: theme.colorScheme.surface,
            ),
          ),
        );
      case StatusDotState.active:
        final color = activeColor ?? CalfColors.success;
        dot = Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: theme.colorScheme.surface, width: 1.5),
          ),
        );
    }

    final labeled = Semantics(
      label: tooltip ??
          switch (resolved) {
            StatusDotState.active => 'Active',
            StatusDotState.inactive => 'Inactive',
            StatusDotState.partial => 'Partially active',
          },
      child: dot,
    );

    if (tooltip == null || tooltip!.isEmpty) {
      return labeled;
    }
    return Tooltip(message: tooltip!, child: labeled);
  }
}

class _PartialDotPainter extends CustomPainter {
  /// Paints a half-filled circle for mixed running state.
  _PartialDotPainter({required this.color, required this.borderColor});

  final Color color;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final fill = Paint()..color = color;
    final border = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final outline = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 0.75),
      -1.5708,
      3.1416,
      true,
      fill,
    );
    canvas.drawCircle(center, radius - 0.75, outline);
    canvas.drawCircle(center, radius - 0.75, border);
  }

  @override
  bool shouldRepaint(covariant _PartialDotPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.borderColor != borderColor;
  }
}
