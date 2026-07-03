import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum _CalfButtonVariant { primary, outline, ghost, destructive }

class CalfButton extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
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

  ButtonStyle _buttonStyle(ShadThemeData theme) {
    final textStyle = theme.textTheme.small;
    final basePadding = padding ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 8);
    final compact = width != null && width! <= 40;
    final minSize = Size(
      width == null || width == 0 ? (compact ? 0 : 64) : width!,
      height ?? (compact ? 32 : 36),
    );
    final density = compact ? VisualDensity.compact : VisualDensity.standard;
    final tapTarget = compact ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded;

    switch (_variant) {
      case _CalfButtonVariant.primary:
        return FilledButton.styleFrom(
          minimumSize: minSize,
          padding: basePadding,
          textStyle: textStyle,
          visualDensity: density,
          tapTargetSize: tapTarget,
          backgroundColor: theme.colorScheme.primary,
          foregroundColor: theme.colorScheme.primaryForeground,
          disabledBackgroundColor: theme.colorScheme.primary.withValues(alpha: 0.5),
          disabledForegroundColor: theme.colorScheme.primaryForeground.withValues(alpha: 0.7),
        );
      case _CalfButtonVariant.outline:
        return OutlinedButton.styleFrom(
          minimumSize: minSize,
          padding: basePadding,
          textStyle: textStyle,
          visualDensity: density,
          tapTargetSize: tapTarget,
          foregroundColor: theme.colorScheme.foreground,
          disabledForegroundColor: theme.colorScheme.mutedForeground,
          side: BorderSide(color: theme.colorScheme.border),
        );
      case _CalfButtonVariant.ghost:
        return TextButton.styleFrom(
          minimumSize: minSize,
          padding: basePadding,
          textStyle: textStyle,
          visualDensity: density,
          tapTargetSize: tapTarget,
          foregroundColor: theme.colorScheme.foreground,
          disabledForegroundColor: theme.colorScheme.mutedForeground,
          backgroundColor: backgroundColor,
        );
      case _CalfButtonVariant.destructive:
        return FilledButton.styleFrom(
          minimumSize: minSize,
          padding: basePadding,
          textStyle: textStyle,
          visualDensity: density,
          tapTargetSize: tapTarget,
          backgroundColor: theme.colorScheme.destructive,
          foregroundColor: theme.colorScheme.destructiveForeground,
          disabledBackgroundColor: theme.colorScheme.destructive.withValues(alpha: 0.5),
          disabledForegroundColor: theme.colorScheme.destructiveForeground.withValues(alpha: 0.7),
        );
    }
  }
}
