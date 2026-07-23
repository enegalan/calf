import 'package:flutter/material.dart';

import 'package:ui/widgets/calf_button.dart';

/// Shows a confirmation dialog and returns true when the user confirms.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String description,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(description),
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
