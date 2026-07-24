import 'package:flutter/material.dart';

import 'package:ui/theme/calf_theme.dart';

class CalfTabBar extends StatelessWidget {
  /// Creates a horizontal tab bar for [labels] with [selectedIndex].
  const CalfTabBar({
    super.key,
    required this.theme,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    this.labelStyle,
  });

  final ThemeData theme;
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final TextStyle? labelStyle;

  /// Builds the tab row with an underline on the selected tab.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            for (var index = 0; index < labels.length; index++) ...[
              if (index > 0) const SizedBox(width: 12),
              _CalfTabButton(
                theme: theme,
                label: labels[index],
                selected: selectedIndex == index,
                labelStyle: labelStyle,
                onTap: () => onSelected(index),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CalfTabButton extends StatelessWidget {
  /// Creates a single tab label with selection styling.
  const _CalfTabButton({
    required this.theme,
    required this.label,
    required this.selected,
    required this.onTap,
    this.labelStyle,
  });

  final ThemeData theme;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final TextStyle? labelStyle;

  /// Builds the tappable tab label with an active underline.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        animationDuration: CalfTheme.materialAnimationDuration,
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected
                      ? theme.colorScheme.primary
                      : const Color(0x00000000),
                  width: 2,
                ),
              ),
            ),
            child: Text(
              label,
              style: (labelStyle ?? theme.textTheme.bodySmall!).copyWith(
                color: selected
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
