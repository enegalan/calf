import 'dart:io';

import 'package:ui/constants/calf_constants.dart';

String get calfReportIssueUrl =>
    'https://github.com/${CalfGitHub.repo}/issues/new';

String get calfRepositoryUrl => 'https://github.com/${CalfGitHub.repo}';

void openPort(int port) {
  openExternalUrl('http://localhost:$port');
}

Future<bool> openExternalUrl(String url) async {
  if (url.isEmpty) {
    return false;
  }

  try {
    if (Platform.isMacOS) {
      final result = await Process.run('open', [url]);
      return result.exitCode == 0;
    }

    if (Platform.isLinux) {
      final result = await Process.run('xdg-open', [url]);
      return result.exitCode == 0;
    }

    if (Platform.isWindows) {
      final result = await Process.run('rundll32', [
        'url.dll,FileProtocolHandler',
        url,
      ]);
      return result.exitCode == 0;
    }
  } catch (_) {}

  return false;
}
