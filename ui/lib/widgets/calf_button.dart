import 'package:flutter/material.dart';

import 'package:ui/theme/calf_theme.dart';

enum _CalfButtonVariant { primary, outline, ghost, destructive }

class CalfButton extends StatelessWidget {
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
  final VoidCallback? onPressed;
  final bool enabled;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final Color? backgroundColor;

  /// Builds the button for the configured variant and size constraints.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveOnPressed = enabled ? onPressed : null;
    final style = _buttonStyle(theme);

    Widget button;
    switch (_variant) {
      case _CalfButtonVariant.primary:
        button = FilledButton(
          onPressed: effectiveOnPressed,
          style: style,
          child: child ?? const SizedBox.shrink(),
        );
      case _CalfButtonVariant.outline:
        button = OutlinedButton(
          onPressed: effectiveOnPressed,
          style: style,
          child: child ?? const SizedBox.shrink(),
        );
      case _CalfButtonVariant.destructive:
        button = FilledButton(
          onPressed: effectiveOnPressed,
          style: style,
          child: child ?? const SizedBox.shrink(),
        );
      case _CalfButtonVariant.ghost:
        button = TextButton(
          onPressed: effectiveOnPressed,
          style: style,
          child: child ?? const SizedBox.shrink(),
        );
    }

    if (width != null) {
      button = SizedBox(width: width, height: height, child: button);
    } else if (height != null) {
      button = SizedBox(height: height, child: button);
    }

    return button;
  }

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
  final VoidCallback? onPressed;
  final bool enabled;
  final String? tooltip;

  /// When set, drives the highlighted segment look; when null, enabled segments stay highlighted.
  final bool? selected;
}

/// Joined icon-action strip (e.g. stop / start / restart).
class CalfButtonGroup extends StatelessWidget {
  /// Creates a segmented control from [actions].
  const CalfButtonGroup({super.key, required this.actions, this.size = 40});

  final List<CalfGroupAction> actions;
  final double size;

  /// Horizontal inset around each segment icon.
  static const double _segmentPad = 12;

  /// Builds the bordered strip with per-segment ink targets.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(size / 2);
    final segmentWidth = size + _segmentPad;
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
        height: size,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < actions.length; index++) ...[
              if (index > 0)
                Container(
                  width: 1,
                  height: size,
                  color: borderColor,
                ),
              _CalfButtonGroupSegment(
                action: actions[index],
                width: segmentWidth,
                height: size,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CalfButtonGroupSegment extends StatelessWidget {
  /// Creates one tappable segment inside [CalfButtonGroup].
  const _CalfButtonGroupSegment({
    required this.action,
    required this.width,
    required this.height,
  });

  final CalfGroupAction action;
  final double width;
  final double height;

  /// Builds the segment background, icon, and optional tooltip.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = action.enabled && action.onPressed != null;
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
        onTap: enabled ? action.onPressed : null,
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
