import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/widgets/calf_button.dart';

/// Wraps [child] in the Material ancestors CalfButton needs.
Widget _harness(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  testWidgets('CalfButton ignores a second tap while onPressed is running', (
    tester,
  ) async {
    var calls = 0;
    final started = Completer<void>();
    final release = Completer<void>();

    await tester.pumpWidget(
      _harness(
        CalfButton(
          onPressed: () async {
            calls += 1;
            if (!started.isCompleted) {
              started.complete();
            }
            await release.future;
          },
          child: const Text('Go'),
        ),
      ),
    );

    await tester.tap(find.text('Go'));
    await tester.pump();
    await started.future;

    await tester.tap(find.text('Go'));
    await tester.pump();

    expect(calls, 1);

    release.complete();
    await tester.pump();
  });

  testWidgets(
    'CalfButtonGroup ignores a second tap while an action is running',
    (tester) async {
      var calls = 0;
      final started = Completer<void>();
      final release = Completer<void>();

      await tester.pumpWidget(
        _harness(
          CalfButtonGroup(
            actions: [
              CalfGroupAction(
                icon: LucideIcons.play,
                tooltip: 'Start',
                onPressed: () async {
                  calls += 1;
                  if (!started.isCompleted) {
                    started.complete();
                  }
                  await release.future;
                },
              ),
            ],
          ),
        ),
      );

      await tester.tap(find.byIcon(LucideIcons.play));
      await tester.pump();
      await started.future;

      await tester.tap(find.byIcon(LucideIcons.play));
      await tester.pump();

      expect(calls, 1);

      release.complete();
      await tester.pump();
    },
  );
}
