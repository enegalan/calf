import 'dart:async';

import 'package:flutter/material.dart';

import 'package:ui/theme/calf_theme.dart';

/// Blocks a second press until the first callback finishes.
mixin _GuardedPressMixin<T extends StatefulWidget> on State<T> {
  bool _pressRunning = false;

  /// Whether a press handler is currently running.
  bool get pressRunning => _pressRunning;

  /// Runs [action] once; later calls return until it completes.
  Future<void> runGuardedPress(FutureOr<void> Function()? action) async {
    if (_pressRunning || action == null) {
      return;
    }
    setState(() => _pressRunning = true);
    try {
      await action();
    } finally {
      _pressRunning = false;
      if (mounted) {
        setState(() {});
      }
    }
  }
}

enum _CalfButtonVariant { primary, outline, ghost, destructive }

class CalfButton extends StatefulWidget {
  /// Creates a primary-themed action button.
  const CalfButton({
    super.key,
    this.child,
    this.onPressed,
    this.enabled = true,
    this.width,
    this.height,
    this.padding,
    this.backgroundColor,
  }) : _variant = _CalfButtonVariant.primary;

  /// Creates an outlined action button.
  const CalfButton.outline({
    super.key,
    this.child,
    this.onPressed,
    this.enabled = true,
    this.width,
    this.height,
    this.padding,
    this.backgroundColor,
  }) : _variant = _CalfButtonVariant.outline;

  /// Creates a low-emphasis ghost action button.
  const CalfButton.ghost({
    super.key,
    this.child,
    this.onPressed,
    this.enabled = true,
    this.width,
    this.height,
    this.padding,
    this.backgroundColor,
  }) : _variant = _CalfButtonVariant.ghost;

  /// Creates a destructive action button.
  const CalfButton.destructive({
    super.key,
    this.child,
    this.onPressed,
    this.enabled = true,
    this.width,
    this.height,
    this.padding,
    this.backgroundColor,
  }) : _variant = _CalfButtonVariant.destructive;

  final _CalfButtonVariant _variant;
  final Widget? child;
  final FutureOr<void> Function()? onPressed;
  final bool enabled;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final Color? backgroundColor;

  /// Creates the mutable state that ignores extra taps while [onPressed] runs.
  @override
  State<CalfButton> createState() => _CalfButtonState();

  /// Returns the Material button style for the current variant and theme.
  ButtonStyle _buttonStyle(ThemeData theme) {
    final textStyle = theme.textTheme.bodySmall;
    final circular = width != null && height != null && width == height;
    final basePadding =
        padding ??
        (circular
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 8));
    final compact = width != null && width! <= 40;
    final minSize = Size(
      width == null || width == 0 ? (compact ? 0 : 64) : width!,
      height ?? (compact ? 32 : 36),
    );
    final density = compact ? VisualDensity.compact : VisualDensity.standard;
    final tapTarget = compact
        ? MaterialTapTargetSize.shrinkWrap
        : MaterialTapTargetSize.padded;
    final shape = circular ? const CircleBorder() : null;

    switch (_variant) {
      case _CalfButtonVariant.primary:
        return FilledButton.styleFrom(
          animationDuration: CalfTheme.materialAnimationDuration,
          minimumSize: minSize,
          maximumSize: circular ? minSize : null,
          padding: basePadding,
          textStyle: textStyle,
          visualDensity: density,
          tapTargetSize: tapTarget,
          shape: shape,
          backgroundColor: theme.colorScheme.primary,
          foregroundColor: theme.colorScheme.onPrimary,
          disabledBackgroundColor: theme.colorScheme.primary.withValues(
            alpha: 0.5,
          ),
          disabledForegroundColor: theme.colorScheme.onPrimary.withValues(
            alpha: 0.7,
          ),
        );
      case _CalfButtonVariant.outline:
        return OutlinedButton.styleFrom(
          animationDuration: CalfTheme.materialAnimationDuration,
          minimumSize: minSize,
          maximumSize: circular ? minSize : null,
          padding: basePadding,
          textStyle: textStyle,
          visualDensity: density,
          tapTargetSize: tapTarget,
          shape: shape,
          foregroundColor: theme.colorScheme.onSurface,
          disabledForegroundColor: theme.colorScheme.onSurfaceVariant,
          backgroundColor: backgroundColor,
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        );
      case _CalfButtonVariant.ghost:
        return TextButton.styleFrom(
          animationDuration: CalfTheme.materialAnimationDuration,
          minimumSize: minSize,
          maximumSize: circular ? minSize : null,
          padding: basePadding,
          textStyle: textStyle,
          visualDensity: density,
          tapTargetSize: tapTarget,
          shape: shape,
          foregroundColor: theme.colorScheme.onSurface,
          disabledForegroundColor: theme.colorScheme.onSurfaceVariant,
          backgroundColor: backgroundColor,
        );
      case _CalfButtonVariant.destructive:
        return FilledButton.styleFrom(
          animationDuration: CalfTheme.materialAnimationDuration,
          minimumSize: minSize,
          maximumSize: circular ? minSize : null,
          padding: basePadding,
          textStyle: textStyle,
          visualDensity: density,
          tapTargetSize: tapTarget,
          shape: shape,
          backgroundColor: theme.colorScheme.error,
          foregroundColor: theme.colorScheme.onError,
          disabledBackgroundColor: theme.colorScheme.error.withValues(
            alpha: 0.5,
          ),
          disabledForegroundColor: theme.colorScheme.onError.withValues(
            alpha: 0.7,
          ),
        );
    }
  }
}

class _CalfButtonState extends State<CalfButton> with _GuardedPressMixin {
  /// Invokes [CalfButton.onPressed] and ignores further taps until it finishes.
  Future<void> _handlePressed() => runGuardedPress(widget.onPressed);

  /// Builds the button for the configured variant and size constraints.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveOnPressed =
        widget.enabled && !pressRunning && widget.onPressed != null
        ? _handlePressed
        : null;
    final style = widget._buttonStyle(theme);

    Widget button;
    switch (widget._variant) {
      case _CalfButtonVariant.primary:
        button = FilledButton(
          onPressed: effectiveOnPressed,
          style: style,
          child: widget.child ?? const SizedBox.shrink(),
        );
      case _CalfButtonVariant.outline:
        button = OutlinedButton(
          onPressed: effectiveOnPressed,
          style: style,
          child: widget.child ?? const SizedBox.shrink(),
        );
      case _CalfButtonVariant.destructive:
        button = FilledButton(
          onPressed: effectiveOnPressed,
          style: style,
          child: widget.child ?? const SizedBox.shrink(),
        );
      case _CalfButtonVariant.ghost:
        button = TextButton(
          onPressed: effectiveOnPressed,
          style: style,
          child: widget.child ?? const SizedBox.shrink(),
        );
    }

    if (widget.width != null) {
      button = SizedBox(
        width: widget.width,
        height: widget.height,
        child: button,
      );
    } else if (widget.height != null) {
      button = SizedBox(height: widget.height, child: button);
    }

    return button;
  }
}

/// One icon action inside a [CalfButtonGroup].
class CalfGroupAction {
  /// Creates a grouped icon action with optional [tooltip] and [selected] state.
  const CalfGroupAction({
    required this.icon,
    this.onPressed,
    this.enabled = true,
    this.tooltip,
    this.selected,
  });

  final IconData icon;
  final FutureOr<void> Function()? onPressed;
  final bool enabled;
  final String? tooltip;

  /// When set, drives the highlighted segment look; when null, enabled segments stay highlighted.
  final bool? selected;
}

/// Joined icon-action strip (e.g. stop / start / restart).
class CalfButtonGroup extends StatefulWidget {
  /// Creates a segmented control from [actions].
  const CalfButtonGroup({super.key, required this.actions, this.size = 40});

  final List<CalfGroupAction> actions;
  final double size;

  /// Horizontal inset around each segment icon.
  static const double _segmentPad = 12;

  /// Creates the mutable state that locks the strip while an action runs.
  @override
  State<CalfButtonGroup> createState() => _CalfButtonGroupState();
}

class _CalfButtonGroupState extends State<CalfButtonGroup>
    with _GuardedPressMixin {
  /// Builds the bordered strip with per-segment ink targets.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(widget.size / 2);
    final segmentWidth = widget.size + CalfButtonGroup._segmentPad;
    final borderColor = theme.colorScheme.outline;

    return Material(
      animationDuration: CalfTheme.materialAnimationDuration,
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: widget.size,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < widget.actions.length; index++) ...[
              if (index > 0)
                Container(width: 1, height: widget.size, color: borderColor),
              _segment(
                widget.actions[index],
                width: segmentWidth,
                height: widget.size,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Builds one segment that shares the group's in-flight lock.
  Widget _segment(
    CalfGroupAction action, {
    required double width,
    required double height,
  }) {
    return _CalfButtonGroupSegment(
      action: action,
      width: width,
      height: height,
      groupRunning: pressRunning,
      onPressed: () => runGuardedPress(action.onPressed),
    );
  }
}

class _CalfButtonGroupSegment extends StatelessWidget {
  /// Creates one tappable segment inside [CalfButtonGroup].
  const _CalfButtonGroupSegment({
    required this.action,
    required this.width,
    required this.height,
    required this.groupRunning,
    required this.onPressed,
  });

  final CalfGroupAction action;
  final double width;
  final double height;
  final bool groupRunning;
  final Future<void> Function() onPressed;

  /// Builds the segment background, icon, and optional tooltip.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = action.enabled && action.onPressed != null && !groupRunning;
    final highlighted = action.selected ?? enabled;
    final Color background;
    final Color foreground;
    if (!enabled) {
      background = theme.colorScheme.surfaceContainerHighest;
      foreground = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);
    } else if (highlighted) {
      background = theme.colorScheme.secondaryContainer;
      foreground = theme.colorScheme.onSecondaryContainer;
    } else {
      background = Colors.transparent;
      foreground = theme.colorScheme.onSurfaceVariant;
    }

    Widget segment = Material(
      animationDuration: CalfTheme.materialAnimationDuration,
      color: background,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        child: SizedBox(
          width: width,
          height: height,
          child: Icon(action.icon, size: 16, color: foreground),
        ),
      ),
    );

    if (action.tooltip != null && action.tooltip!.isNotEmpty) {
      segment = Tooltip(message: action.tooltip!, child: segment);
    }

    return segment;
  }
}
