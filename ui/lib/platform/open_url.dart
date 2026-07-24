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
String get calfReleasesUrl => 'https://github.com/${CalfGitHub.repo}/releases';

/// URL for Docker Hub.
String get dockerHubUrl => 'https://hub.docker.com/';

/// Builds a Docker Hub URL for [imageRef] (e.g. `ubuntu:22.04` or `user/app:tag`).
String dockerHubImageUrl(String imageRef) {
  var ref = imageRef.trim();
  if (ref.isEmpty) {
    return dockerHubUrl;
  }

  ref = ref.split('@').first;
  final slash = ref.indexOf('/');
  final hostEnd = slash >= 0 ? slash : -1;
  if (hostEnd > 0 && ref.substring(0, hostEnd).contains('.')) {
    ref = ref.substring(hostEnd + 1);
  }
  if (ref.startsWith('library/')) {
    ref = ref.substring('library/'.length);
  }

  final tagSep = ref.lastIndexOf(':');
  var repository = ref;
  var tag = '';
  if (tagSep > 0) {
    repository = ref.substring(0, tagSep);
    tag = ref.substring(tagSep + 1);
  }

  if (!repository.contains('/')) {
    final base = 'https://hub.docker.com/_/$repository';
    if (tag.isEmpty) {
      return base;
    }
    return '$base/tags?name=${Uri.encodeQueryComponent(tag)}';
  }

  final base = 'https://hub.docker.com/r/$repository';
  if (tag.isEmpty) {
    return base;
  }
  return '$base/tags?name=${Uri.encodeQueryComponent(tag)}';
}

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
