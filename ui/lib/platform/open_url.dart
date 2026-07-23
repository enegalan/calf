import 'dart:io';

import 'package:ui/constants/calf_constants.dart';

/// URL for opening a new GitHub issue in the Calf repository.
String get calfReportIssueUrl =>
    'https://github.com/${CalfGitHub.repo}/issues/new';

/// URL for the Calf GitHub repository home page.
String get calfRepositoryUrl => 'https://github.com/${CalfGitHub.repo}';

/// URL for the Calf README on GitHub.
String get calfReadmeUrl => 'https://github.com/${CalfGitHub.repo}#readme';

/// URL for Calf GitHub Releases.
String get calfReleasesUrl =>
    'https://github.com/${CalfGitHub.repo}/releases';

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

/// Opens [path] in the platform file manager. Returns false on empty path or failure.
Future<bool> openInFileExplorer(String path) async {
  if (path.isEmpty) {
    return false;
  }

  try {
    if (Platform.isMacOS) {
      final result = await Process.run('open', [path]);
      return result.exitCode == 0;
    }

    if (Platform.isLinux) {
      final result = await Process.run('xdg-open', [path]);
      return result.exitCode == 0;
    }

    if (Platform.isWindows) {
      final result = await Process.run('explorer', [path]);
      // explorer.exe often returns a non-zero exit code even when it opens.
      return result.exitCode == 0 || result.stdout.toString().isEmpty;
    }
  } catch (_) {}

  return false;
}
