import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/screens/unified_logs_screen.dart';
import 'package:ui/widgets/logs_panel.dart';

void main() {
  group('logLineMatchesQuery', () {
    test('empty query matches every line', () {
      expect(logLineMatchesQuery('ERROR boom', '', matchCase: false), isTrue);
    });

    test('literal search is case-insensitive unless match case is on', () {
      expect(
        logLineMatchesQuery('ERROR boom', 'error', matchCase: false),
        isTrue,
      );
      expect(
        logLineMatchesQuery('ERROR boom', 'error', matchCase: true),
        isFalse,
      );
      expect(
        logLineMatchesQuery('ERROR boom', 'ERROR', matchCase: true),
        isTrue,
      );
    });

    test('slash-delimited values are regular expressions', () {
      expect(
        logLineMatchesQuery('warn: x', '/error|warn/', matchCase: false),
        isTrue,
      );
      expect(
        logLineMatchesQuery('info: x', '/error|warn/', matchCase: false),
        isFalse,
      );
    });

    test('regex i flag ignores match case', () {
      expect(
        logLineMatchesQuery('ERROR boom', '/error/i', matchCase: true),
        isTrue,
      );
    });

    test('invalid regex matches nothing', () {
      expect(logLineMatchesQuery('error', '/(/', matchCase: false), isFalse);
    });
  });

  group('logsToCsv', () {
    test('escapes commas and quotes', () {
      final csv = logsToCsv([
        MixedLogBlock(
          containerId: 'web',
          containerName: 'web',
          color: const Color(0xFF000000),
          lines: [
            LogLine(
              text: 'hello, "world"',
              receivedAt: DateTime.utc(2026, 8, 17, 18, 0, 0),
            ),
          ],
        ),
      ]);

      expect(csv, startsWith('timestamp,container,message\n'));
      expect(csv, contains('web'));
      expect(csv, contains('"hello, ""world"""'));
    });
  });
}
