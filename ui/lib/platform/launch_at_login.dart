import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

const _appName = 'Calf';
const _bundleId = 'com.enegalan.calf';
const _windowsRunKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
const _linuxDesktopFileName = 'calf.desktop';

/// Resolves the path used when registering Calf to start at login.
String launchAtLoginPath() {
  final executable = Platform.resolvedExecutable;
  if (Platform.isMacOS) {
    final appBundle = macAppBundlePath(executable);
    if (appBundle != null) {
      return appBundle;
    }
  }

  return executable;
}

/// Returns the `.app` bundle path for a macOS executable, if applicable.
String? macAppBundlePath(String executable) {
  final segments = p.split(executable);
  final contentsIndex = segments.lastIndexOf('Contents');
  if (contentsIndex <= 0) {
    return null;
  }

  if (contentsIndex + 1 >= segments.length ||
      segments[contentsIndex + 1] != 'MacOS') {
    return null;
  }

  return p.joinAll(segments.sublist(0, contentsIndex));
}

class LaunchAtLogin {
  /// Returns whether Calf is registered to start at login on this platform.
  static Future<bool> isEnabled() async {
    if (Platform.isMacOS) {
      return _macIsEnabled();
    }
    if (Platform.isLinux) {
      return _linuxIsEnabled();
    }
    if (Platform.isWindows) {
      return _windowsIsEnabled();
    }

    return false;
  }

  /// Enables or disables launch-at-login registration for Calf.
  static Future<bool> setEnabled(bool enabled) async {
    if (Platform.isMacOS) {
      return enabled ? _macEnable() : _macDisable();
    }
    if (Platform.isLinux) {
      return enabled ? _linuxEnable() : _linuxDisable();
    }
    if (Platform.isWindows) {
      return enabled ? _windowsEnable() : _windowsDisable();
    }

    return false;
  }

  /// Returns whether the macOS LaunchAgent plist exists and references Calf.
  static Future<bool> _macIsEnabled() async {
    final plist = File(_macLaunchAgentPath());
    if (!plist.existsSync()) {
      return false;
    }

    try {
      final contents = await plist.readAsString();
      final launchPath = launchAtLoginPath();
      return contents.contains(launchPath);
    } on FileSystemException catch (error) {
      debugPrint('Failed to read launch-at-login plist: $error');
      return false;
    }
  }

  /// Writes the macOS LaunchAgent plist so Calf starts at login.
  static Future<bool> _macEnable() async {
    final launchPath = launchAtLoginPath();
    if (await _macIsEnabled()) {
      return true;
    }

    final plist = File(_macLaunchAgentPath());
    try {
      plist.parent.createSync(recursive: true);
      await plist.writeAsString(_macLaunchAgentPlist(launchPath));
      return true;
    } on FileSystemException catch (error) {
      debugPrint('Failed to write launch-at-login plist: $error');
      return false;
    }
  }

  /// Removes the macOS LaunchAgent plist for Calf.
  static Future<bool> _macDisable() async {
    final plist = File(_macLaunchAgentPath());
    if (!plist.existsSync()) {
      return true;
    }

    try {
      await plist.delete();
      return true;
    } on FileSystemException catch (error) {
      debugPrint('Failed to delete launch-at-login plist: $error');
      return false;
    }
  }

  /// Returns the path to the macOS LaunchAgent plist for Calf.
  static String _macLaunchAgentPath() {
    final home = Platform.environment['HOME'] ?? '';
    return p.join(home, 'Library', 'LaunchAgents', '$_bundleId.plist');
  }

  /// Builds the LaunchAgent plist XML that opens [appPath] at login.
  static String _macLaunchAgentPlist(String appPath) {
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$_bundleId</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>$appPath</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
''';
  }

  /// Returns whether the Linux XDG autostart desktop file exists for Calf.
  static Future<bool> _linuxIsEnabled() async {
    final desktopFile = File(_linuxDesktopFilePath());
    if (!desktopFile.existsSync()) {
      return false;
    }

    try {
      final contents = await desktopFile.readAsString();
      final launchPath = launchAtLoginPath();
      return contents.contains('Exec=$launchPath') ||
          contents.contains('Exec="$launchPath"');
    } on FileSystemException catch (error) {
      debugPrint('Failed to read launch-at-login desktop file: $error');
      return false;
    }
  }

  /// Writes the Linux XDG autostart desktop file for Calf.
  static Future<bool> _linuxEnable() async {
    final launchPath = launchAtLoginPath();
    final desktopFile = File(_linuxDesktopFilePath());

    try {
      desktopFile.parent.createSync(recursive: true);
      await desktopFile.writeAsString('''[Desktop Entry]
Type=Application
Name=$_appName
Exec="$launchPath"
Terminal=false
X-GNOME-Autostart-enabled=true
''');
      return true;
    } on FileSystemException catch (error) {
      debugPrint('Failed to write launch-at-login desktop file: $error');
      return false;
    }
  }

  /// Removes the Linux XDG autostart desktop file for Calf.
  static Future<bool> _linuxDisable() async {
    final desktopFile = File(_linuxDesktopFilePath());
    if (!desktopFile.existsSync()) {
      return true;
    }

    try {
      await desktopFile.delete();
      return true;
    } on FileSystemException catch (error) {
      debugPrint('Failed to delete launch-at-login desktop file: $error');
      return false;
    }
  }

  /// Returns the path to the Linux autostart desktop file for Calf.
  static String _linuxDesktopFilePath() {
    final configHome = Platform.environment['XDG_CONFIG_HOME'];
    if (configHome != null && configHome.isNotEmpty) {
      return p.join(configHome, 'autostart', _linuxDesktopFileName);
    }

    final home = Platform.environment['HOME'] ?? '';
    return p.join(home, '.config', 'autostart', _linuxDesktopFileName);
  }

  /// Returns whether the Windows Run registry key includes Calf.
  static Future<bool> _windowsIsEnabled() async {
    try {
      final result = await Process.run('reg', [
        'query',
        _windowsRunKey,
        '/v',
        _appName,
      ]);
      if (result.exitCode != 0) {
        return false;
      }

      final launchPath = launchAtLoginPath().toLowerCase();
      final output = result.stdout.toString().toLowerCase();
      return output.contains(launchPath) || output.contains('"$launchPath"');
    } on ProcessException catch (error) {
      debugPrint('Failed to query Windows launch-at-login registry: $error');
      return false;
    }
  }

  /// Adds Calf to the Windows Run registry key for login startup.
  static Future<bool> _windowsEnable() async {
    final launchPath = launchAtLoginPath();
    final runValue = _windowsRunValue(launchPath);

    try {
      final result = await Process.run('reg', [
        'add',
        _windowsRunKey,
        '/v',
        _appName,
        '/t',
        'REG_SZ',
        '/d',
        runValue,
        '/f',
      ]);
      return result.exitCode == 0;
    } on ProcessException catch (error) {
      debugPrint('Failed to enable Windows launch-at-login: $error');
      return false;
    }
  }

  /// Formats [launchPath] as a quoted Windows registry Run value.
  static String _windowsRunValue(String launchPath) => '"$launchPath"';

  /// Removes Calf from the Windows Run registry key.
  static Future<bool> _windowsDisable() async {
    try {
      final result = await Process.run('reg', [
        'delete',
        _windowsRunKey,
        '/v',
        _appName,
        '/f',
      ]);
      return result.exitCode == 0;
    } on ProcessException catch (error) {
      debugPrint('Failed to disable Windows launch-at-login: $error');
      return false;
    }
  }
}
