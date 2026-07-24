import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:window_manager/window_manager.dart';

import 'package:ui/api/client.dart';
import 'package:ui/app_shell.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/platform/tray_status.dart';
import 'package:ui/theme/calf_theme.dart';

Process? _daemonProcess;
bool _daemonShutdown = false;
Timer? _daemonRestartTimer;
int _daemonRestartAttempts = 0;
const _maxDaemonRestarts = 5;

/// When true, `make dev-ui-*` connects to an already-running `make dev-backend`.
const _externalDaemon = bool.fromEnvironment('CALF_EXTERNAL_DAEMON');

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
    final process = _daemonProcess!;
    _daemonRestartAttempts = 0;
    process.stdout.listen((data) => stdout.add(data));
    process.stderr.listen((data) => stderr.add(data));
    process.exitCode.then((code) {
      stderr.writeln('calf-daemon exited with code $code');
      // Ignore exits from a process that is no longer the active daemon.
      if (!identical(_daemonProcess, process)) {
        return;
      }
      if (_daemonShutdown) {
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
  try {
    await CalfTrayStatus.hide();
  } on PlatformException catch (e, stack) {
    stderr.writeln('failed to hide tray icon: $e');
    stderr.writeln(stack);
  } on MissingPluginException catch (e, stack) {
    stderr.writeln('failed to hide tray icon: $e');
    stderr.writeln(stack);
  } finally {
    final process = _daemonProcess;
    if (process != null) {
      _daemonProcess = null;
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () async {
          process.kill(ProcessSignal.sigkill);
          return process.exitCode;
        },
      );
    }
  }
}

/// Restarts the embedded calf-daemon without quitting the app.
Future<void> _restartDaemon() async {
  if (_externalDaemon || _daemonShutdown) {
    return;
  }

  _daemonRestartTimer?.cancel();
  _daemonRestartAttempts = 0;
  final process = _daemonProcess;
  if (process != null) {
    _daemonProcess = null;
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }
  await _startDaemon();
}

/// Brings the Calf window to the foreground (tray menu action).
Future<void> _openCalfWindow() async {
  if (!supportsTrayStatusIcon) {
    return;
  }
  await windowManager.show();
  await windowManager.focus();
}

/// Quits the app from the tray menu (same as Calf → Quit).
Future<void> _quitCalfApp() async {
  await _stopDaemon();
  CalfTrayStatus.dispose();
  exit(0);
}

/// Application entry point; starts the daemon and runs the Flutter app.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (supportsTrayStatusIcon) {
    await windowManager.ensureInitialized();
  }
  CalfTrayStatus.install(
    onOpen: _openCalfWindow,
    onQuit: _quitCalfApp,
    onRestartEngine: _restartDaemon,
    onOpenUrl: openExternalUrl,
  );
  if (!_externalDaemon) {
    _startDaemon();
  }
  runApp(const MainApp());
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
      unawaited(CalfTrayStatus.show());
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
    CalfTrayStatus.dispose();
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
                unawaited(CalfTrayStatus.show());
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
      theme: CalfTheme.light,
      darkTheme: CalfTheme.dark,
      themeAnimationDuration: CalfTheme.animationDuration,
      themeAnimationCurve: CalfTheme.animationCurve,
      builder: (context, child) {
        final theme = Theme.of(context);
        return Material(
          animationDuration: CalfTheme.materialAnimationDuration,
          color: theme.colorScheme.surface,
          child: DefaultTextStyle(
            style: theme.textTheme.bodyMedium!.copyWith(
              color: theme.colorScheme.onSurface,
            ),
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
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ],
                      ],
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
