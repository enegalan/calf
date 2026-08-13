import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/theme/calf_theme.dart';

/// Shows a bordered popup menu matching calf dialog/panel chrome.
Future<T?> showCalfMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  double? minWidth,
  bool useRootNavigator = false,
}) {
  final theme = Theme.of(context);
  return showMenu<T>(
    context: context,
    position: position,
    items: items,
    color: theme.colorScheme.surface,
    surfaceTintColor: const Color(0x00000000),
    shape: CalfTheme.popupMenuShape(theme.colorScheme),
    constraints: minWidth == null ? null : BoxConstraints(minWidth: minWidth),
    useRootNavigator: useRootNavigator,
  );
}

/// Three-dot [PopupMenuButton] with the shared bordered menu surface.
class CalfPopupMenuButton<T> extends StatelessWidget {
  /// Creates a vertical-ellipsis overflow menu button.
  const CalfPopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.onSelected,
    this.tooltip = 'Actions',
    this.enabled = true,
    this.iconSize = 16,
    this.iconColor,
    this.style,
    this.padding = EdgeInsets.zero,
    this.constraints,
  });

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T>? onSelected;
  final String tooltip;
  final bool enabled;
  final double iconSize;
  final Color? iconColor;
  final ButtonStyle? style;
  final EdgeInsetsGeometry padding;
  final BoxConstraints? constraints;

  /// Builds the overflow trigger and bordered menu.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = iconColor ?? theme.colorScheme.onSurfaceVariant;
    return PopupMenuButton<T>(
      tooltip: tooltip,
      enabled: enabled,
      padding: padding,
      constraints: constraints,
      style: style,
      color: theme.colorScheme.surface,
      surfaceTintColor: const Color(0x00000000),
      shape: CalfTheme.popupMenuShape(theme.colorScheme),
      icon: Icon(LucideIcons.ellipsisVertical, size: iconSize, color: color),
      onSelected: onSelected,
      itemBuilder: itemBuilder,
    );
  }
}

/// Icon + label row for overflow menu items.
class CalfPopupMenuRow extends StatelessWidget {
  /// Creates a menu row with a leading [icon] and [label].
  const CalfPopupMenuRow({
    super.key,
    required this.icon,
    required this.label,
    this.color,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final Color? color;
  final Widget? trailing;

  /// Builds the icon and label spaced like a native menu item.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = color ?? theme.colorScheme.onSurface;
    return Row(
      children: [
        Icon(
          icon,
          size: 16,
          color: color ?? theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label, style: TextStyle(color: foreground)),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}
