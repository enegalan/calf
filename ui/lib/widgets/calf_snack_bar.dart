import 'package:flutter/material.dart';

/// Shows a SnackBar when a [ScaffoldMessenger] is available for [context].
void showCalfSnackBar(
  BuildContext context,
  String message, {
  Duration? duration,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) {
    return;
  }
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration ?? const Duration(milliseconds: 4000),
    ),
  );
}
