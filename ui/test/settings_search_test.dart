import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/screens/settings_screen.dart';

void main() {
  group('matchingSettingTitles', () {
    const entries = [
      'Choose theme for calf',
      'Start calf when you sign in to your computer',
      'Enable Resource Saver',
    ];

    test('empty query matches nothing', () {
      expect(matchingSettingTitles(entries, ''), isEmpty);
      expect(matchingSettingTitles(entries, '  '), isEmpty);
    });

    test('matches option titles nested under a category', () {
      expect(matchingSettingTitles(entries, 'Choose theme'), [
        'Choose theme for calf',
      ]);
    });

    test('is case-insensitive', () {
      expect(matchingSettingTitles(entries, 'resource saver'), [
        'Enable Resource Saver',
      ]);
    });
  });

  group('highlightSearchQuery', () {
    test('returns the full text when query is empty', () {
      final spans = highlightSearchQuery('Choose theme for calf', '');
      expect(spans, hasLength(1));
      expect((spans.single as TextSpan).text, 'Choose theme for calf');
    });

    test('bolds the matched substring', () {
      final spans = highlightSearchQuery(
        'Choose theme for calf',
        'Choose theme',
      );
      expect(spans, hasLength(2));
      expect((spans[0] as TextSpan).text, 'Choose theme');
      expect((spans[0] as TextSpan).style?.fontWeight, FontWeight.w700);
      expect((spans[1] as TextSpan).text, ' for calf');
    });
  });

  group('fileShareLabel', () {
    test('uses the last path component', () {
      expect(fileShareLabel('/Volumes'), 'Volumes');
      expect(fileShareLabel('/tmp'), 'tmp');
      expect(fileShareLabel('/private/tmp/'), 'tmp');
    });
  });

  group('isValidFileSharePath', () {
    test('requires an absolute path', () {
      expect(isValidFileSharePath('/tmp'), isTrue);
      expect(isValidFileSharePath('/Volumes/Data'), isTrue);
      expect(isValidFileSharePath('tmp'), isFalse);
      expect(isValidFileSharePath(''), isFalse);
      expect(isValidFileSharePath('  '), isFalse);
    });
  });

  group('normalizeFileSharePath', () {
    test('trims and collapses redundant separators', () {
      expect(normalizeFileSharePath(' /tmp/foo/ '), '/tmp/foo');
    });
  });

  group('displayDockerSubnet', () {
    test('shows the default when config is empty', () {
      expect(displayDockerSubnet(''), defaultDockerSubnet);
      expect(displayDockerSubnet('  '), defaultDockerSubnet);
    });

    test('shows the saved value when set', () {
      expect(displayDockerSubnet('10.0.0.0/24'), '10.0.0.0/24');
    });
  });

  group('normalizeDockerSubnetForSave', () {
    test('stores empty for blank or default values', () {
      expect(normalizeDockerSubnetForSave(''), '');
      expect(normalizeDockerSubnetForSave(defaultDockerSubnet), '');
    });

    test('keeps custom subnets', () {
      expect(normalizeDockerSubnetForSave('10.0.0.0/24'), '10.0.0.0/24');
    });
  });

  group('displayDaemonJson', () {
    test('shows the Docker Desktop default when config is empty', () {
      expect(displayDaemonJson(''), defaultDaemonJsonOverlay);
      expect(displayDaemonJson('  '), defaultDaemonJsonOverlay);
    });

    test('shows the saved overlay when set', () {
      expect(displayDaemonJson('{"debug": true}'), '{"debug": true}');
    });
  });

  group('normalizeDaemonJsonForSave', () {
    test('stores empty for blank or default values', () {
      expect(normalizeDaemonJsonForSave(''), '');
      expect(normalizeDaemonJsonForSave(defaultDaemonJsonOverlay), '');
    });

    test('keeps custom overlays', () {
      expect(normalizeDaemonJsonForSave('{"debug": true}'), '{"debug": true}');
    });
  });

  group('proxyConfigIsEmpty', () {
    test('is true when every proxy field is blank', () {
      expect(proxyConfigIsEmpty('', '', ''), isTrue);
      expect(proxyConfigIsEmpty('  ', '', ''), isTrue);
    });

    test('is false when any proxy field is set', () {
      expect(proxyConfigIsEmpty('http://proxy:8080', '', ''), isFalse);
      expect(proxyConfigIsEmpty('', 'https://proxy:8080', ''), isFalse);
      expect(proxyConfigIsEmpty('', '', 'localhost'), isFalse);
    });
  });

  group('resourcesPaneForSetting', () {
    test('maps proxy titles to the Proxies pane', () {
      expect(resourcesPaneForSetting('HTTP proxy'), ResourcesPane.proxies);
      expect(resourcesPaneForSetting('No proxy'), ResourcesPane.proxies);
    });

    test('maps network titles to the Network pane', () {
      expect(resourcesPaneForSetting('Docker subnet'), ResourcesPane.network);
      expect(
        resourcesPaneForSetting('Port binding behavior'),
        ResourcesPane.network,
      );
    });

    test('maps file sharing and the rest', () {
      expect(
        resourcesPaneForSetting('File sharing'),
        ResourcesPane.fileSharing,
      );
      expect(resourcesPaneForSetting('CPU limit'), ResourcesPane.advanced);
    });
  });
}
