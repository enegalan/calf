import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/app_shell.dart';

const _calfPrimary = Color(0xFF2496ED);

final _lightShadTheme = ShadThemeData(
  brightness: Brightness.light,
  colorScheme: const ShadBlueColorScheme.light(
    primary: _calfPrimary,
    ring: _calfPrimary,
  ),
);

final _darkShadTheme = ShadThemeData(
  brightness: Brightness.dark,
  colorScheme: const ShadBlueColorScheme.dark(
    primary: _calfPrimary,
    ring: _calfPrimary,
  ),
);

Process? _daemonProcess;

Future<void> _startDaemon() async {
  final daemonPath = _findDaemon();

  if (daemonPath == null) {
    return;
  }

  try {
    final env = Map<String, String>.from(Platform.environment);
    final path = env['PATH'] ?? '';
    final extras = _extraPaths();
    if (extras.isNotEmpty) {
      env['PATH'] = '$extras:$path';
    }
    _daemonProcess = await Process.start(daemonPath, [], runInShell: false, environment: env);
    _daemonProcess!.stdout.listen((data) => stdout.add(data));
    _daemonProcess!.stderr.listen((data) => stderr.add(data));
    _daemonProcess!.exitCode.then((code) {
      stderr.writeln('calf-daemon exited with code $code');
      if (_daemonProcess == null) return;
      _daemonProcess = null;
      Future.delayed(const Duration(seconds: 1), _startDaemon);
    });
  } catch (e) {
    stderr.writeln('failed to start calf-daemon: $e');
  }
}

String? _findDaemon() {
  final dir = File(Platform.resolvedExecutable).parent.path;
  final daemonPath = '$dir/calf-daemon';
  if (File(daemonPath).existsSync()) {
    return daemonPath;
  }
  // On macOS, daemon is next to the executable inside the .app bundle
  // On Linux/Windows, also check next to executable
  stderr.writeln('calf-daemon not found at $daemonPath');
  return null;
}

String _extraPaths() {
  if (Platform.isMacOS) {
    final path = Platform.environment['PATH'] ?? '';
    final missing = <String>[];
    for (final dir in ['/opt/homebrew/bin', '/opt/homebrew/sbin', '/usr/local/bin']) {
      if (!path.contains(dir)) {
        missing.add(dir);
      }
    }
    return missing.join(':');
  }
  return '';
}

Future<void> _stopDaemon() async {
  final process = _daemonProcess;
  if (process == null) return;
  _daemonProcess = null;
  process.kill();
  await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
    process.kill(ProcessSignal.sigkill);
    return -1;
  });
}

void main() {
  _startDaemon();
  runApp(const MainApp());
}

ThemeData _materialTheme(ShadThemeData shadTheme) {
  return ThemeData(
    fontFamily: shadTheme.textTheme.family,
    colorScheme: ColorScheme(
      brightness: shadTheme.brightness,
      primary: shadTheme.colorScheme.primary,
      onPrimary: shadTheme.colorScheme.primaryForeground,
      secondary: shadTheme.colorScheme.secondary,
      onSecondary: shadTheme.colorScheme.secondaryForeground,
      error: shadTheme.colorScheme.destructive,
      onError: shadTheme.colorScheme.destructiveForeground,
      surface: shadTheme.colorScheme.background,
      onSurface: shadTheme.colorScheme.foreground,
    ),
    scaffoldBackgroundColor: shadTheme.colorScheme.background,
    brightness: shadTheme.brightness,
    dividerTheme: DividerThemeData(
      color: shadTheme.separatorTheme.color ?? shadTheme.colorScheme.border,
      thickness: shadTheme.separatorTheme.thickness ?? 1,
    ),
    useMaterial3: true,
  );
}

class MainApp extends StatefulWidget {
  const MainApp({super.key, this.apiClient});

  final CalfClient? apiClient;

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> with WidgetsBindingObserver {
  ThemeMode _themeMode = ThemeMode.system;
  bool _daemonReady = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.apiClient == null) {
      _waitForDaemon();
    } else {
      _daemonReady = true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _stopDaemon();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopDaemon();
    super.dispose();
  }

  Future<void> _waitForDaemon() async {
    const url = 'http://127.0.0.1:8765/v1/status';
    const attempts = 120;
    final client = http.Client();

    for (var i = 0; i < attempts; i++) {
      try {
        final response = await client.get(Uri.parse(url)).timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) {
          final body = jsonDecode(response.body);
          if (body is Map<String, dynamic>) {
            final runtime = body['runtime'];
            if (runtime is Map<String, dynamic> && runtime['state'] == 'running') {
              client.close();
              if (mounted) {
                setState(() {
                  _daemonReady = true;
                  _error = null;
                });
              }
              return;
            }
            if (runtime is Map<String, dynamic>) {
              final log = runtime['log'];
              if (mounted) {
                setState(() => _error = (log is String && log.isNotEmpty) ? log : null);
              }
            }
          }
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }
    client.close();
    if (mounted) {
      setState(() {
        _error = _error ?? 'Daemon did not become ready in time. Try restarting Calf.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: _materialTheme(_lightShadTheme),
      darkTheme: _materialTheme(_darkShadTheme),
      builder: (context, child) {
        final brightness = Theme.of(context).brightness;
        final shadTheme = brightness == Brightness.dark ? _darkShadTheme : _lightShadTheme;

        return ShadTheme(
          data: shadTheme,
          child: DefaultTextStyle(
            style: TextStyle(
              color: shadTheme.colorScheme.foreground,
              fontFamily: shadTheme.textTheme.family,
            ),
            child: ColoredBox(
              color: shadTheme.colorScheme.background,
              child: _daemonReady
                  ? (child ?? const SizedBox.shrink())
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          if (_error != null) ...[
                            const SizedBox(height: 16),
                            Text(_error!, style: TextStyle(color: shadTheme.colorScheme.destructive)),
                          ],
                        ],
                      ),
                    ),
            ),
          ),
        );
      },
      home: _daemonReady
          ? AppShell(
              apiClient: widget.apiClient,
              themeMode: _themeMode,
              onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
            )
          : const SizedBox.shrink(),
    );
  }
}
