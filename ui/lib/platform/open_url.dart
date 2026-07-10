import 'dart:io';

import 'package:ui/constants/calf_constants.dart';

/// URL for opening a new GitHub issue in the Calf repository.
String get calfReportIssueUrl =>
    'https://github.com/${CalfGitHub.repo}/issues/new';

/// URL for the Calf GitHub repository home page.
String get calfRepositoryUrl => 'https://github.com/${CalfGitHub.repo}';

/// Opens [port] in the system browser via `http://localhost`.
void openPort(int port) {
  openExternalUrl('http://localhost:$port');
}

/// Opens [url] in the platform default browser. Returns false on empty URL or failure.
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
