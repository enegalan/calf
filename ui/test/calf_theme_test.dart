import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ui/theme/calf_theme.dart';

void main() {
  test('selected switch thumb stays onPrimary while hovered', () {
    for (final theme in <ThemeData>[CalfTheme.light, CalfTheme.dark]) {
      final thumb = theme.switchTheme.thumbColor!.resolve({
        WidgetState.selected,
        WidgetState.hovered,
      });
      expect(thumb, theme.colorScheme.onPrimary);
      expect(thumb, isNot(theme.colorScheme.primary));
    }
  });
}
