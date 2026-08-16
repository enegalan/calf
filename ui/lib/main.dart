import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

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

/// True after Quit is chosen; the close button then destroys the window.
bool _appQuitting = false;

/// Intercepts the window close button so calf hides to the tray.
final _calfWindowListener = _CalfWindowListener();

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
    process.stdout.listen((data) => stdout.add(data));
    process.stderr.listen((data) => stderr.add(data));
    // Only clear the restart budget after the process has proven it can stay
    // up; resetting it immediately on start would let a fast crash loop spin
    // forever instead of stopping after `_maxDaemonRestarts`.
    Timer(const Duration(seconds: 30), () {
      if (identical(_daemonProcess, process)) {
        _daemonRestartAttempts = 0;
      }
    });
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
///
/// Throws [StateError] when the UI was started with an external daemon
/// (`CALF_EXTERNAL_DAEMON`), because this process does not own that daemon.
Future<void> _restartDaemon() async {
  if (_daemonShutdown) {
    return;
  }
  if (_externalDaemon) {
    throw StateError(
      'Development mode is active. Restart the backend manually.',
    );
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

/// Brings the calf window to the foreground (tray menu action).
Future<void> _openCalfWindow() async {
  if (!supportsTrayStatusIcon) {
    return;
  }
  await windowManager.show();
  await windowManager.focus();
}

/// Hides the main window without stopping the daemon.
Future<void> _hideCalfWindow() async {
  try {
    await windowManager.hide();
  } on PlatformException catch (e, stack) {
    stderr.writeln('failed to hide calf window: $e');
    stderr.writeln(stack);
  } on MissingPluginException catch (e, stack) {
    stderr.writeln('failed to hide calf window: $e');
    stderr.writeln(stack);
  }
}

/// Quits the app from the tray menu (same as calf → Quit).
Future<void> _quitCalfApp() async {
  _appQuitting = true;
  if (supportsTrayStatusIcon) {
    try {
      await windowManager.setPreventClose(false);
    } on PlatformException catch (e, stack) {
      stderr.writeln('failed to allow window close: $e');
      stderr.writeln(stack);
    } on MissingPluginException catch (e, stack) {
      stderr.writeln('failed to allow window close: $e');
      stderr.writeln(stack);
    }
  }
  await _stopDaemon();
  CalfTrayStatus.dispose();
  exit(0);
}

/// Hides the window on close so calf stays in the tray.
class _CalfWindowListener with WindowListener {
  /// Hides the main window instead of quitting when the close button is used.
  @override
  void onWindowClose() {
    if (_appQuitting) {
      return;
    }
    unawaited(_hideCalfWindow());
  }
}

/// Application entry point; starts the daemon and runs the Flutter app.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (supportsTrayStatusIcon) {
    await windowManager.ensureInitialized();
    windowManager.addListener(_calfWindowListener);
    try {
      await windowManager.setPreventClose(true);
    } on PlatformException catch (e, stack) {
      stderr.writeln('failed to prevent window close: $e');
      stderr.writeln(stack);
    } on MissingPluginException catch (e, stack) {
      stderr.writeln('failed to prevent window close: $e');
      stderr.writeln(stack);
    }
  }
  CalfTrayStatus.install(
    onOpen: _openCalfWindow,
    onQuit: _quitCalfApp,
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

  /// Stops the daemon before Flutter lets macOS finish Dock Quit / Cmd+Q.
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    _appQuitting = true;
    await _stopDaemon();
    CalfTrayStatus.dispose();
    return AppExitResponse.exit;
  }

  /// Releases resources when the widget is removed.
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopDaemon();
    CalfTrayStatus.dispose();
    super.dispose();
  }

  /// Polls the daemon status endpoint until it answers or times out.
  ///
  /// The daemon is considered ready as soon as it answers with HTTP 200 and a
  /// parseable body, regardless of the guest runtime's boot state: the engine
  /// (VM/container runtime) may still be starting, but the UI itself no
  /// longer needs to block on that since screens handle a stopped runtime.
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
            'Daemon did not become ready in time. Try restarting calf.';
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
              onRestartDaemon: _restartDaemon,
              usesExternalDaemon: _externalDaemon,
            )
          : const SizedBox.shrink(),
    );
  }
}
