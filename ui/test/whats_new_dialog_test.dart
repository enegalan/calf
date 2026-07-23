import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ui/theme/calf_theme.dart';
import 'package:ui/widgets/app_top_bar.dart';
import 'package:ui/widgets/release_notes_markdown.dart';

void main() {
  testWidgets('ReleaseNotesMarkdown builds GitHub-style notes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: CalfTheme.dark,
        home: const Scaffold(
          body: SingleChildScrollView(
            child: ReleaseNotesMarkdown(
              data: '''
## Added
- **Disk image** settings
- Engine status bar

### Fixed
- Guest disk arch
''',
            ),
          ),
        ),
      ),
    );

    expect(find.byType(ReleaseNotesMarkdown), findsOneWidget);
    expect(find.textContaining('Disk image'), findsOneWidget);
  });

  testWidgets('showWhatsNewDialog presents the dialog', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: CalfTheme.dark,
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () => showWhatsNewDialog(context, '0.9.8'),
                child: const Text('Open whats new'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open whats new'));
    // Dialog is scheduled on the next frame after the menu/gesture settles.
    await tester.pump();
    await tester.pump();

    expect(find.text("What's new"), findsOneWidget);

    // Allow the GitHub fetch to settle (fails under test binding → offline UI).
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Calf 0.9.8'), findsOneWidget);
    expect(
      find.text('Release notes are not available offline.'),
      findsOneWidget,
    );
  });
}
