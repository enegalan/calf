import 'package:flutter/material.dart';

import 'package:ui/widgets/calf_button.dart';

/// Default content width for compact calf dialogs.
const double calfDialogWidth = 400;

/// Shared modal chrome: 16px title, fixed width, tight padding, no M3 tint.
class CalfAlertDialog extends StatelessWidget {
  /// Creates a calf-styled [AlertDialog].
  const CalfAlertDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.width = calfDialogWidth,
  });

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final double width;

  /// Builds the dialog with compact paddings and a constrained content width.
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      clipBehavior: Clip.antiAlias,
      titlePadding: title == null
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(20, 18, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      buttonPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: title,
      content: content == null ? null : SizedBox(width: width, child: content),
      actions: actions,
    );
  }
}

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
    builder: (dialogContext) => CalfAlertDialog(
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
