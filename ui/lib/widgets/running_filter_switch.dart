import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class RunningFilterSwitch extends StatelessWidget {
  const RunningFilterSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'Show only running',
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Row(
      children: [
        ShadSwitch(
          value: value,
          onChanged: onChanged,
        ),
        const SizedBox(width: 8),
        Text(label, style: theme.textTheme.small),
      ],
    );
  }
}
