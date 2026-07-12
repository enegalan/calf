import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';

class ErrorText extends StatelessWidget {
  /// Displays [error] using the theme destructive text style.
  const ErrorText({super.key, required this.error, this.style});

  final Object error;
  final TextStyle? style;

  /// Builds formatted error text from [error].
  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Text(
      formatAsyncError(error),
      style:
          style ??
          theme.textTheme.small.copyWith(color: theme.colorScheme.destructive),
    );
  }
}

/// Returns a user-facing message for [error], preferring API error text.
String formatAsyncError(Object error) {
  if (error is ApiException) {
    return error.message;
  }

  return error.toString().replaceAll(r'\n', ' ').trim();
}
