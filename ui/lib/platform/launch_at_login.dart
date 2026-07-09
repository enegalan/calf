import 'dart:io';

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

  if (contentsIndex + 1 >= segments.length || segments[contentsIndex + 1] != 'MacOS') {
    return null;
  }

  return p.joinAll(segments.sublist(0, contentsIndex));
}

class LaunchAtLogin {
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

  static Future<bool> _macIsEnabled() async {
    final plist = File(_macLaunchAgentPath());
    if (!plist.existsSync()) {
      return false;
    }

    try {
      final contents = await plist.readAsString();
      final launchPath = launchAtLoginPath();
      return contents.contains(launchPath);
    } catch (_) {
      return false;
    }
  }

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
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _macDisable() async {
    final plist = File(_macLaunchAgentPath());
    if (!plist.existsSync()) {
      return true;
    }

    try {
      await plist.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _macLaunchAgentPath() {
    final home = Platform.environment['HOME'] ?? '';
    return p.join(home, 'Library', 'LaunchAgents', '$_bundleId.plist');
  }

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

  static Future<bool> _linuxIsEnabled() async {
    final desktopFile = File(_linuxDesktopFilePath());
    if (!desktopFile.existsSync()) {
      return false;
    }

    try {
      final contents = await desktopFile.readAsString();
      final launchPath = launchAtLoginPath();
      return contents.contains('Exec=$launchPath') || contents.contains('Exec="$launchPath"');
    } catch (_) {
      return false;
    }
  }

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
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _linuxDisable() async {
    final desktopFile = File(_linuxDesktopFilePath());
    if (!desktopFile.existsSync()) {
      return true;
    }

    try {
      await desktopFile.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _linuxDesktopFilePath() {
    final configHome = Platform.environment['XDG_CONFIG_HOME'];
    if (configHome != null && configHome.isNotEmpty) {
      return p.join(configHome, 'autostart', _linuxDesktopFileName);
    }

    final home = Platform.environment['HOME'] ?? '';
    return p.join(home, '.config', 'autostart', _linuxDesktopFileName);
  }

  static Future<bool> _windowsIsEnabled() async {
    try {
      final result = await Process.run('reg', ['query', _windowsRunKey, '/v', _appName]);
      if (result.exitCode != 0) {
        return false;
      }

      final launchPath = launchAtLoginPath().toLowerCase();
      return result.stdout.toString().toLowerCase().contains(launchPath);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _windowsEnable() async {
    final launchPath = launchAtLoginPath();

    try {
      final result = await Process.run(
        'reg',
        ['add', _windowsRunKey, '/v', _appName, '/t', 'REG_SZ', '/d', launchPath, '/f'],
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _windowsDisable() async {
    try {
      final result = await Process.run('reg', ['delete', _windowsRunKey, '/v', _appName, '/f']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
