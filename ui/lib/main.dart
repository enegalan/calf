import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/app_shell.dart';
import 'package:ui/constants/calf_constants.dart';

final _lightShadTheme = ShadThemeData(
  brightness: Brightness.light,
  colorScheme: const ShadBlueColorScheme.light(
    primary: CalfColors.primary,
    ring: CalfColors.primary,
  ),
);

final _darkShadTheme = ShadThemeData(
  brightness: Brightness.dark,
  colorScheme: const ShadBlueColorScheme.dark(
    primary: CalfColors.primary,
    ring: CalfColors.primary,
  ),
);

Process? _daemonProcess;
bool _daemonShutdown = false;
Timer? _daemonRestartTimer;
int _daemonRestartAttempts = 0;
const _maxDaemonRestarts = 5;

/// Spawns the embedded calf-daemon subprocess and wires restart on exit.
Future<void> _startDaemon() async {
  if (_daemonShutdown) {
    return;
  }

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
    _daemonProcess = await Process.start(
      daemonPath,
      [],
      runInShell: false,
      environment: env,
    );
    _daemonRestartAttempts = 0;
    _daemonProcess!.stdout.listen((data) => stdout.add(data));
    _daemonProcess!.stderr.listen((data) => stderr.add(data));
    _daemonProcess!.exitCode.then((code) {
      stderr.writeln('calf-daemon exited with code $code');
      if (_daemonShutdown || _daemonProcess == null) {
        _daemonProcess = null;
        return;
      }
      _daemonProcess = null;
      _daemonRestartAttempts++;
      if (_daemonRestartAttempts > _maxDaemonRestarts) {
        stderr.writeln(
          'calf-daemon failed to stay running after $_maxDaemonRestarts attempts',
        );
        return;
      }
      // Back off between restarts so a crash loop does not hammer the port.
      final delay = Duration(seconds: _daemonRestartAttempts);
      _daemonRestartTimer = Timer(delay, _startDaemon);
    });
  } catch (e) {
    stderr.writeln('failed to start calf-daemon: $e');
  }
}

/// Locates the calf-daemon binary next to the app executable.
String? _findDaemon() {
  final dir = File(Platform.resolvedExecutable).parent.path;
  final candidates = Platform.isWindows
      ? ['$dir/calf-daemon.exe', '$dir/calf-daemon']
      : ['$dir/calf-daemon'];
  for (final daemonPath in candidates) {
    if (File(daemonPath).existsSync()) {
      return daemonPath;
    }
  }
  stderr.writeln('calf-daemon not found in $dir');
  return null;
}

// Homebrew paths are often missing from the GUI subprocess PATH on macOS.
/// Returns Homebrew bin paths missing from the GUI subprocess PATH on macOS.
String _extraPaths() {
  if (Platform.isMacOS) {
    final path = Platform.environment['PATH'] ?? '';
    final missing = <String>[];
    for (final dir in [
      '/opt/homebrew/bin',
      '/opt/homebrew/sbin',
      '/usr/local/bin',
    ]) {
      if (!path.contains(dir)) {
        missing.add(dir);
      }
    }
    return missing.join(':');
  }
  return '';
}

/// Terminates the calf-daemon subprocess and cancels pending restarts.
Future<void> _stopDaemon() async {
  _daemonShutdown = true;
  _daemonRestartTimer?.cancel();
  _daemonRestartTimer = null;
  final process = _daemonProcess;
  if (process == null) return;
  _daemonProcess = null;
  process.kill();
  await process.exitCode.timeout(
    const Duration(seconds: 5),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
}

/// Application entry point; starts the daemon and runs the Flutter app.
void main() {
  _startDaemon();
  runApp(const MainApp());
}

/// Builds a Material [ThemeData] bridged from a Shadcn theme.
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
  /// Creates a [MainApp] instance.
  const MainApp({super.key, this.apiClient});

  final CalfClient? apiClient;

  /// Creates the state object for [MainApp].
  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> with WidgetsBindingObserver {
  ThemeMode _themeMode = ThemeMode.system;
  bool _daemonReady = false;
  String? _error;

  /// Initializes state and starts async loading.
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

  /// Stops the daemon when the app is detached.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _stopDaemon();
    }
  }

  /// Releases resources when the widget is removed.
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopDaemon();
    super.dispose();
  }

  /// Polls the daemon status endpoint until the runtime is running or times out.
  Future<void> _waitForDaemon() async {
    final url = Uri.parse('${CalfDefaults.defaultBaseUrl}/v1/status');
    const attempts = 120;
    final client = http.Client();

    for (var i = 0; i < attempts; i++) {
      try {
        final response = await client
            .get(url)
            .timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) {
          final body = jsonDecode(response.body);
          if (body is Map<String, dynamic>) {
            final runtime = body['runtime'];
            if (runtime is Map<String, dynamic> &&
                runtime['state'] == 'running') {
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
                setState(
                  () => _error = (log is String && log.isNotEmpty) ? log : null,
                );
              }
            }
          }
        }
      } on SocketException {
        // expected while daemon is not up yet
      } on TimeoutException {
        // expected while daemon is starting
      } on http.ClientException {
        // expected while daemon is not up yet
      } on FormatException catch (e) {
        stderr.writeln('invalid daemon status response: $e');
      } catch (e) {
        stderr.writeln('unexpected error while waiting for daemon: $e');
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    client.close();
    if (mounted) {
      setState(() {
        _error =
            _error ??
            'Daemon did not become ready in time. Try restarting Calf.';
      });
    }
  }

  /// Builds the widget tree.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: _materialTheme(_lightShadTheme),
      darkTheme: _materialTheme(_darkShadTheme),
      builder: (context, child) {
        final brightness = Theme.of(context).brightness;
        final shadTheme = brightness == Brightness.dark
            ? _darkShadTheme
            : _lightShadTheme;

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
                            Text(
                              _error!,
                              style: TextStyle(
                                color: shadTheme.colorScheme.destructive,
                              ),
                            ),
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
