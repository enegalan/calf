import 'package:flutter/material.dart';

class RunningFilterSwitch extends StatelessWidget {
  /// Creates a labeled switch for filtering to running resources only.
  const RunningFilterSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'Show only running',
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;

  /// Builds the switch and [label] in a horizontal row.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Switch(value: value, onChanged: onChanged),
            const SizedBox(width: 8),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
