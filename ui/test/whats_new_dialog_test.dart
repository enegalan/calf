import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ui/theme/calf_theme.dart';
import 'package:ui/updates/update_dialog.dart';
import 'package:ui/updates/update_info.dart';
import 'package:ui/widgets/app_top_bar.dart';
import 'package:ui/widgets/release_notes_markdown.dart';

void main() {
  test('normalizeReleaseNotesMarkdown shortens GitHub PR and changelog links', () {
    const raw = '''
## What's Changed\r
* Update benchmarks by @enegalan in https://github.com/enegalan/calf/pull/60\r
\r
**Full Changelog**: https://github.com/enegalan/calf/compare/v0.9.7...v0.9.8
''';

    final normalized = normalizeReleaseNotesMarkdown(raw);

    expect(normalized.contains('\r'), isFalse);
    expect(
      normalized,
      contains(
        'in [#60](https://github.com/enegalan/calf/pull/60)',
      ),
    );
    expect(
      normalized,
      contains(
        '[Full changelog](https://github.com/enegalan/calf/compare/v0.9.7...v0.9.8)',
      ),
    );
  });

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
    expect(find.textContaining('##'), findsNothing);
    expect(find.textContaining('Disk image'), findsOneWidget);
    expect(find.textContaining('Added'), findsOneWidget);
  });

  testWidgets('showUpdateAvailableDialog shows versions without notes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: CalfTheme.dark,
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  showUpdateAvailableDialog(
                    context: context,
                    update: const UpdateInfo(
                      version: '1.0.0',
                      releaseNotes: '''
## Added
- **Disk image** settings
''',
                      downloadUrl: 'https://example.com/calf.dmg',
                      releasePageUrl: 'https://example.com/release',
                    ),
                    currentVersion: '0.9.20',
                    onDownload: () async {},
                  );
                },
                child: const Text('Open update'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open update'));
    await tester.pumpAndSettle();

    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('0.9.20'), findsOneWidget);
    expect(find.text('1.0.0'), findsOneWidget);
    expect(find.byType(ReleaseNotesMarkdown), findsNothing);
    expect(find.textContaining('Disk image'), findsNothing);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
    expect(find.text('Skip this version'), findsNothing);
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
    expect(find.text('calf 0.9.8'), findsOneWidget);

    // Allow the GitHub fetch / disk cache load to settle.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text("What's new"), findsOneWidget);
    final hasNotes = find.byType(ReleaseNotesMarkdown).evaluate().isNotEmpty;
    final offline = find
        .text('Release notes are not available offline.')
        .evaluate()
        .isNotEmpty;
    expect(hasNotes || offline, isTrue);
  });
}
