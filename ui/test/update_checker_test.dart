import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ui/updates/update_checker.dart';

void main() {
  test('compareVersions orders semver parts', () {
    expect(UpdateChecker.compareVersions('0.9.1', '0.9.2'), -1);
    expect(UpdateChecker.compareVersions('0.9.2', '0.9.2'), 0);
    expect(UpdateChecker.compareVersions('1.0.0', '0.9.9'), 1);
    expect(UpdateChecker.compareVersions('v0.9.2', '0.9.3'), -1);
  });

  test('normalizeTagName strips leading v', () {
    expect(UpdateChecker.normalizeTagName('v0.9.2'), '0.9.2');
    expect(UpdateChecker.normalizeTagName('0.9.2'), '0.9.2');
  });

  test('parseReleaseJson extracts release metadata', () {
    final release = UpdateChecker.parseReleaseJson({
      'tag_name': 'v1.2.3',
      'html_url': 'https://github.com/enegalan/calf/releases/tag/v1.2.3',
      'body': 'Bug fixes',
      'assets': [
        {
          'name': 'Calf-1.2.3.dmg',
          'browser_download_url': 'https://example.com/Calf-1.2.3.dmg',
        },
      ],
    });

    expect(release, isNotNull);
    expect(release!.version, '1.2.3');
    expect(release.releaseNotes, 'Bug fixes');
    expect(release.downloadUrl, 'https://example.com/Calf-1.2.3.dmg');
  });

  test('preferredAssetNames matches current platform', () {
    final assetNames = UpdateChecker.preferredAssetNames('1.2.3');

    if (Platform.isMacOS) {
      expect(assetNames, contains('Calf-1.2.3.dmg'));
      expect(assetNames, contains('Calf-1.2.3.pkg'));
    } else if (Platform.isWindows) {
      expect(assetNames, contains('Calf-1.2.3.exe'));
    } else if (Platform.isLinux) {
      expect(assetNames, contains('Calf-1.2.3-x86_64.AppImage'));
    } else {
      expect(assetNames, isEmpty);
    }
  });
}
