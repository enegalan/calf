import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/widgets/calf_button.dart';

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String description,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) {
  return showShadDialog<bool>(
    context: context,
    builder: (dialogContext) => ShadDialog(
      title: Text(title),
      description: Text(description),
      actions: [
        CalfButton.outline(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        if (destructive)
          CalfButton.destructive(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          )
        else
          CalfButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
      ],
    ),
  ).then((value) => value == true);
}
