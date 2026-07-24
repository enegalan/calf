import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import 'package:ui/api/client.dart';
import 'package:ui/platform/macos_menu.dart';
import 'package:ui/platform/tray_status.dart';
import 'package:ui/platform/launch_at_login.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/screens/builds_screen.dart';
import 'package:ui/screens/containers_screen.dart';
import 'package:ui/screens/images_screen.dart';
import 'package:ui/screens/networks_screen.dart';
import 'package:ui/screens/troubleshoot_screen.dart';
import 'package:ui/screens/volumes_screen.dart';
import 'package:ui/storage/sidebar_preferences.dart';
import 'package:ui/storage/update_preferences.dart';
import 'package:ui/updates/update_checker.dart';
import 'package:ui/updates/update_dialog.dart';
import 'package:ui/updates/update_info.dart';
import 'package:ui/widgets/about_dialog.dart';
import 'package:ui/widgets/app_bottom_bar.dart';
import 'package:ui/widgets/app_top_bar.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/volume_export_form.dart';
import 'package:ui/theme/calf_theme.dart';
import 'package:ui/constants/calf_constants.dart';

class AppShell extends StatefulWidget {
  /// Creates a [AppShell] instance.
  AppShell({
    super.key,
    CalfClient? apiClient,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
  }) : apiClient = apiClient ?? ApiClient();

  final CalfClient apiClient;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  /// Creates the state object for [AppShell].
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  bool _showSettings = false;
  bool _showTroubleshoot = false;
  RegistryLoginStatus? _registryStatus;
  bool _registryLoading = true;
  bool _registryBrowserLoginPending = false;
  String _appVersion = '';
  DaemonStatus? _daemonStatus;
  bool _engineActionBusy = false;
  _EnginePendingAction _enginePending = _EnginePendingAction.none;
  Timer? _statusPollTimer;
  UpdateCheckResult? _updateCheckResult;
  bool _updateDialogShown = false;
  late final UpdateChecker _updateChecker = UpdateChecker();

  bool _isCollapsed = false;
  bool _isHoveringSidebar = false;
  bool _isHoveringToggle = false;
  bool? _lastWidthWasSmall;
  bool _sidebarPrefLoaded = false;

  /// Releases resources when the widget is removed.
  @override
  void dispose() {
    _statusPollTimer?.cancel();
    if (supportsTrayStatusIcon) {
      CalfTrayStatus.unregisterAppActions();
    }
    _updateChecker.close();
    super.dispose();
  }

  /// Initializes state and starts async loading.
  @override
  void initState() {
    super.initState();
    _loadSidebarPreference();
    loadRegistryStatus();
    loadAppVersion();
    _startStatusPolling();
    if (supportsTrayStatusIcon) {
      CalfTrayStatus.registerAppActions(
        CalfTrayAppActions(
          onOpenSettings: openSettings,
          onSignIn: startRegistryBrowserLogin,
          onSignOut: logoutRegistry,
          onCheckForUpdates: () => checkForUpdates(force: true),
          snapshot: _trayMenuSnapshot,
        ),
      );
    }
  }

  /// Starts periodic daemon status polling for the bottom bar.
  void _startStatusPolling() {
    _statusPollTimer?.cancel();
    unawaited(_refreshDaemonStatus());
    _statusPollTimer = Timer.periodic(
      const Duration(milliseconds: CalfDefaults.defaultPollIntervalMs),
      (_) => unawaited(_refreshDaemonStatus()),
    );
  }

  /// Refreshes daemon status used by the bottom bar.
  Future<void> _refreshDaemonStatus() async {
    try {
      final status = await widget.apiClient.fetchStatus();
      if (!mounted) return;
      setState(() {
        _daemonStatus = status;
        if (status.version.isNotEmpty) {
          _appVersion = status.version;
        }
      });
    } on ApiException catch (error) {
      debugPrint('Failed to poll daemon status: ${error.message}');
    } on TimeoutException catch (error) {
      debugPrint('Timed out polling daemon status: $error');
    } on FormatException catch (error) {
      debugPrint('Failed to parse daemon status: $error');
    }
  }

  /// Starts the container engine from the bottom bar.
  Future<void> _startEngine() async {
    await _runEngineAction(
      _EnginePendingAction.starting,
      () => widget.apiClient.startRuntime(),
    );
  }

  /// Stops the container engine from the bottom bar.
  Future<void> _stopEngine() async {
    await _runEngineAction(
      _EnginePendingAction.stopping,
      () => widget.apiClient.stopRuntime(),
    );
  }

  /// Restarts the container engine (stop then start).
  Future<void> _restartEngine() async {
    if (_engineActionBusy) return;
    await _runEngineAction(
      _EnginePendingAction.stopping,
      () => widget.apiClient.stopRuntime(),
    );
    if (!mounted || _daemonStatus?.runtime.isRunning == true) {
      return;
    }
    await _runEngineAction(
      _EnginePendingAction.starting,
      () => widget.apiClient.startRuntime(),
    );
  }

  /// Runs a start/stop action and refreshes status afterward.
  Future<void> _runEngineAction(
    _EnginePendingAction pending,
    Future<RuntimeStatus> Function() action,
  ) async {
    if (_engineActionBusy) return;
    setState(() {
      _engineActionBusy = true;
      _enginePending = pending;
    });
    try {
      final runtime = await action();
      if (!mounted) return;
      setState(() {
        final current = _daemonStatus;
        if (current != null) {
          _daemonStatus = DaemonStatus(
            version: current.version,
            uptimeSeconds: current.uptimeSeconds,
            listenAddr: current.listenAddr,
            logLevel: current.logLevel,
            runtime: runtime,
            resources: current.resources,
            resourceSaverActive: false,
          );
        }
      });
      await _refreshDaemonStatus();
    } on ApiException catch (error) {
      debugPrint('Engine action failed: ${error.message}');
      if (!mounted) return;
      _showEngineSnackBar(error.message);
    } on TimeoutException catch (error) {
      debugPrint('Engine action timed out: $error');
      if (!mounted) return;
      _showEngineSnackBar('Engine action timed out');
    } finally {
      if (mounted) {
        setState(() {
          _engineActionBusy = false;
          _enginePending = _EnginePendingAction.none;
        });
      }
    }
  }

  /// Shows an engine-action error when a [Scaffold] is available.
  void _showEngineSnackBar(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      debugPrint('Engine snackbar skipped (no Scaffold): $message');
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Builds live tray menu data (running containers and registry state).
  Future<CalfTrayMenuSnapshot> _trayMenuSnapshot() async {
    var runningCount = 0;
    var containersLoadFailed = false;

    try {
      final containers = await widget.apiClient.fetchContainers();
      runningCount = containers
          .where((container) => container.isRunning)
          .length;
    } on ApiException catch (error) {
      debugPrint('Tray menu failed to load containers: ${error.message}');
      containersLoadFailed = true;
    } on TimeoutException catch (error) {
      debugPrint('Tray menu timed out loading containers: $error');
      containersLoadFailed = true;
    } on FormatException catch (error) {
      debugPrint('Tray menu failed to parse containers: $error');
      containersLoadFailed = true;
    }

    return CalfTrayMenuSnapshot(
      runningContainerCount: runningCount,
      containersLoadFailed: containersLoadFailed,
      registryLoggedIn: _registryStatus?.loggedIn == true,
      signInPending: _registryBrowserLoginPending,
    );
  }

  /// Loads the persisted sidebar collapsed preference.
  Future<void> _loadSidebarPreference() async {
    final collapsed = await SidebarPreferences.loadCollapsed();
    if (!mounted) return;
    setState(() {
      _isCollapsed = collapsed;
      _sidebarPrefLoaded = true;
    });
  }

  /// Loads the app version from the daemon and checks for updates.
  Future<void> loadAppVersion() async {
    try {
      final status = await widget.apiClient.fetchStatus();
      if (!mounted) return;
      setState(() => _appVersion = status.version);
      await checkForUpdates(force: false);
    } on ApiException catch (error) {
      debugPrint('Failed to load app version from daemon: ${error.message}');
      if (!mounted) return;
      setState(() => _appVersion = 'unavailable');
    } on TimeoutException catch (error) {
      debugPrint('Timed out loading app version: $error');
      if (!mounted) return;
      setState(() => _appVersion = 'unavailable');
    } on FormatException catch (error) {
      debugPrint('Failed to parse app version response: $error');
      if (!mounted) return;
      setState(() => _appVersion = 'unavailable');
    }
  }

  /// Checks GitHub for a newer release.
  Future<void> checkForUpdates({required bool force}) async {
    if (_appVersion.isEmpty) {
      return;
    }

    final result = await _updateChecker.check(
      currentVersion: _appVersion,
      force: force,
    );
    if (!mounted) {
      return;
    }

    setState(() => _updateCheckResult = result);

    if (!force &&
        !_updateDialogShown &&
        result.hasUpdate &&
        result.latest != null) {
      _updateDialogShown = true;
      await showUpdateAvailableDialog(
        context: context,
        update: result.latest!,
        currentVersion: result.currentVersion,
        onDownload: () => openExternalUrl(result.latest!.downloadUrl),
        onSkip: () async {
          await UpdatePreferences.saveSkippedVersion(result.latest!.version);
          if (!mounted) {
            return;
          }
          setState(
            () => _updateCheckResult = UpdateCheckResult.upToDate(
              currentVersion: result.currentVersion,
              checkedAt: result.checkedAt,
            ),
          );
        },
      );
    }
  }

  /// Loads the current Docker Hub registry login status.
  Future<void> loadRegistryStatus() async {
    setState(() => _registryLoading = true);

    try {
      final status = await widget.apiClient.fetchRegistryStatus();
      if (!mounted) return;
      setState(() {
        _registryStatus = status;
        _registryLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _registryLoading = false);
      _showEngineSnackBar(
        error is ApiException
            ? error.message
            : 'Could not load registry status',
      );
    }
  }

  /// Starts a Docker Hub browser-based login flow.
  Future<void> startRegistryBrowserLogin() async {
    setState(() => _registryBrowserLoginPending = true);

    try {
      final start = await widget.apiClient.startRegistryBrowserLogin();
      if (!mounted) return;

      await showRegistryLoginDialog(
        context: context,
        apiClient: widget.apiClient,
        start: start,
        onComplete: (username) async {
          if (!mounted) return;
          setState(() {
            _registryBrowserLoginPending = false;
            _registryStatus = RegistryLoginStatus(
              loggedIn: true,
              server: 'docker.io',
              username: username,
            );
          });
          _showEngineSnackBar(
            username == null || username.isEmpty
                ? 'Signed in to Docker Hub'
                : 'Signed in as $username',
          );
          await loadRegistryStatus();
        },
        onFailed: (message) {
          if (!mounted) return;
          setState(() => _registryBrowserLoginPending = false);
          if (message.isNotEmpty) {
            _showEngineSnackBar(message);
          }
        },
      );

      if (!mounted) return;
      setState(() => _registryBrowserLoginPending = false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _registryBrowserLoginPending = false);
      _showEngineSnackBar(
        error is ApiException
            ? error.message
            : 'Could not start Docker Hub sign-in',
      );
    }
  }

  /// Logs out from a container registry.
  Future<void> logoutRegistry() async {
    try {
      await widget.apiClient.logoutRegistry();
      if (!mounted) return;
      await loadRegistryStatus();
    } catch (error) {
      if (!mounted) return;
      _showEngineSnackBar(
        error is ApiException
            ? error.message
            : 'Could not sign out of Docker Hub',
      );
    }
  }

  /// Switches the main content area to the settings screen.
  void openSettings() {
    setState(() {
      _showTroubleshoot = false;
      _showSettings = true;
    });
  }

  /// Opens the Troubleshoot screen from the engine menu.
  void openTroubleshoot() {
    setState(() {
      _showSettings = false;
      _showTroubleshoot = true;
    });
  }

  /// Closes settings and returns to the selected resource screen.
  void closeSettings() {
    setState(() {
      _showSettings = false;
      _showTroubleshoot = false;
    });
  }

  /// Navigates to a sidebar section by index.
  void navigateToSection(int index) {
    setState(() {
      _selectedIndex = index;
      _showSettings = false;
      _showTroubleshoot = false;
    });
  }

  /// Toggles sidebar collapsed state and persists the preference.
  void toggleSidebar() {
    setState(() {
      _isCollapsed = !_isCollapsed;
      SidebarPreferences.saveCollapsed(_isCollapsed);
    });
  }

  /// Opens the Docker Hub account settings page in the browser.
  Future<void> openAccountSettings() async {
    final username = _registryStatus?.username ?? '';
    if (username.isEmpty) {
      return;
    }
    await openExternalUrl(
      'https://app.docker.com/accounts/$username/settings/account-information',
    );
  }

  /// Builds the widget tree.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const navItems = [
      (label: 'Containers', icon: LucideIcons.box),
      (label: 'Images', icon: LucideIcons.layers),
      (label: 'Volumes', icon: LucideIcons.hardDrive),
      (label: 'Networks', icon: LucideIcons.network),
      (label: 'Builds', icon: LucideIcons.wrench),
    ];

    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 1024;

    if (_lastWidthWasSmall == null) {
      _lastWidthWasSmall = isSmallScreen;
      if (!_sidebarPrefLoaded) {
        _isCollapsed = isSmallScreen;
      }
    } else if (_lastWidthWasSmall != isSmallScreen) {
      _lastWidthWasSmall = isSmallScreen;
      _isCollapsed = isSmallScreen;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        SidebarPreferences.saveCollapsed(_isCollapsed);
      });
    }

    final shell = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppTopBar(
          registryStatus: _registryStatus,
          registryLoading: _registryLoading,
          signInPending: _registryBrowserLoginPending,
          updateAvailable: _updateCheckResult?.hasUpdate == true,
          onOpenSettings: openSettings,
          onSignIn: startRegistryBrowserLogin,
          onSignOut: logoutRegistry,
          onOpenWhatsNew: () => showWhatsNewDialog(context, _appVersion),
        ),
        Expanded(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MouseRegion(
                    onEnter: (_) => setState(() => _isHoveringSidebar = true),
                    onExit: (_) => setState(() => _isHoveringSidebar = false),
                    child: AnimatedContainer(
                      duration: CalfTheme.animationDuration,
                      curve: CalfTheme.animationCurve,
                      width: _isCollapsed ? 72 : 220,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(
                            right: BorderSide(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final isCurrentlyCollapsed =
                                  constraints.maxWidth < 150;
                              return Column(
                                crossAxisAlignment: isCurrentlyCollapsed
                                    ? CrossAxisAlignment.center
                                    : CrossAxisAlignment.start,
                                children: [
                                  for (
                                    var index = 0;
                                    index < navItems.length;
                                    index++
                                  ) ...[
                                    if (index > 0) const SizedBox(height: 8),
                                    _NavItem(
                                      label: navItems[index].label,
                                      icon: navItems[index].icon,
                                      selected:
                                          !_showSettings &&
                                          !_showTroubleshoot &&
                                          _selectedIndex == index,
                                      collapsed: isCurrentlyCollapsed,
                                      onTap: () => setState(() {
                                        _selectedIndex = index;
                                        _showSettings = false;
                                        _showTroubleshoot = false;
                                      }),
                                    ),
                                  ],
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: _showTroubleshoot
                          ? TroubleshootScreen(
                              apiClient: widget.apiClient,
                              onClose: closeSettings,
                              onRestart: _restartEngine,
                              onQuit: CalfTrayStatus.quitApp,
                            )
                          : _showSettings
                          ? SettingsScreen(
                              apiClient: widget.apiClient,
                              appVersion: _appVersion,
                              themeMode: widget.themeMode,
                              onThemeModeChanged: widget.onThemeModeChanged,
                              onClose: closeSettings,
                              initialUpdateCheckResult: _updateCheckResult,
                              onCheckForUpdates: () =>
                                  checkForUpdates(force: true),
                              onUpdateCheckResultChanged: (result) {
                                setState(() => _updateCheckResult = result);
                              },
                            )
                          : switch (_selectedIndex) {
                              0 => ContainersScreen(
                                apiClient: widget.apiClient,
                              ),
                              1 => ImagesScreen(apiClient: widget.apiClient),
                              2 => VolumesScreen(apiClient: widget.apiClient),
                              3 => NetworksScreen(apiClient: widget.apiClient),
                              _ => BuildsScreen(apiClient: widget.apiClient),
                            },
                    ),
                  ),
                ],
              ),
              AnimatedPositioned(
                duration: CalfTheme.animationDuration,
                curve: CalfTheme.animationCurve,
                top: 16,
                left: (_isCollapsed ? 72 : 220) - 18,
                child: MouseRegion(
                  hitTestBehavior: HitTestBehavior.opaque,
                  onEnter: (_) => setState(() => _isHoveringToggle = true),
                  onExit: (_) => setState(() => _isHoveringToggle = false),
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: AnimatedOpacity(
                      opacity: (_isHoveringSidebar || _isHoveringToggle)
                          ? 1.0
                          : 0.35,
                      duration: CalfTheme.animationDuration,
                      curve: CalfTheme.animationCurve,
                      child: IconButton(
                        tooltip: _isCollapsed
                            ? 'Expand sidebar'
                            : 'Collapse sidebar',
                        onPressed: () {
                          setState(() {
                            _isCollapsed = !_isCollapsed;
                            SidebarPreferences.saveCollapsed(_isCollapsed);
                          });
                        },
                        icon: Icon(
                          LucideIcons.panelLeft,
                          size: 14,
                          color: theme.colorScheme.onSurface,
                        ),
                        style: IconButton.styleFrom(
                          animationDuration:
                              CalfTheme.materialAnimationDuration,
                          backgroundColor: theme.colorScheme.surface,
                          foregroundColor: theme.colorScheme.onSurface,
                          side: BorderSide(
                            color: theme.colorScheme.outlineVariant,
                          ),
                          padding: const EdgeInsets.all(6),
                          minimumSize: const Size(28, 28),
                          fixedSize: const Size(28, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                          elevation: 2,
                          shadowColor: theme.colorScheme.onSurface.withValues(
                            alpha: 0.15,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        AppBottomBar(
          status: _daemonStatus,
          appVersion: _appVersion,
          busy: _engineActionBusy,
          pendingAction: _enginePending.label,
          loggedIn: _registryStatus?.loggedIn == true,
          signInPending: _registryBrowserLoginPending,
          updateAvailable: _updateCheckResult?.hasUpdate == true,
          onStart: () => unawaited(_startEngine()),
          onStop: () => unawaited(_stopEngine()),
          onOpenSettings: openSettings,
          onOpenAbout: () =>
              showAboutCalfDialog(context, appVersion: _appVersion),
          onSignIn: () => unawaited(startRegistryBrowserLogin()),
          onSignOut: () => unawaited(logoutRegistry()),
          onTroubleshoot: openTroubleshoot,
          onOpenDockerHub: () => unawaited(openExternalUrl(dockerHubUrl)),
          onDownloadUpdate: () {
            final latest = _updateCheckResult?.latest;
            if (_updateCheckResult?.hasUpdate == true && latest != null) {
              unawaited(openExternalUrl(latest.downloadUrl));
              return;
            }
            unawaited(checkForUpdates(force: true));
          },
          onRestart: () => unawaited(_restartEngine()),
          onQuit: () => unawaited(CalfTrayStatus.quitApp()),
        ),
      ],
    );

    return MacosMenuScope(
      appVersion: _appVersion,
      loggedIn: _registryStatus?.loggedIn == true,
      signInPending: _registryBrowserLoginPending,
      onOpenSettings: openSettings,
      onCheckForUpdates: () => checkForUpdates(force: true),
      onOpenWhatsNew: () => showWhatsNewDialog(context, _appVersion),
      onSignIn: startRegistryBrowserLogin,
      onSignOut: logoutRegistry,
      onOpenAccountSettings: openAccountSettings,
      onNavigateToSection: navigateToSection,
      onToggleSidebar: toggleSidebar,
      onReportIssue: () => openExternalUrl(calfReportIssueUrl),
      onOpenRepository: () => openExternalUrl(calfRepositoryUrl),
      child: Scaffold(body: shell),
    );
  }
}

class _NavItem extends StatelessWidget {
  /// Creates a sidebar navigation row.
  const _NavItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.collapsed = false,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final bool collapsed;

  /// Builds the widget tree.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurface;
    final effectivePadding = collapsed
        ? const EdgeInsets.symmetric(horizontal: 0, vertical: 8)
        : const EdgeInsets.symmetric(horizontal: 16, vertical: 8);

    final button = CalfButton.ghost(
      width: double.infinity,
      onPressed: onTap,
      backgroundColor: selected ? theme.colorScheme.secondaryContainer : null,
      padding: effectivePadding,
      child: Align(
        alignment: collapsed ? Alignment.center : Alignment.centerLeft,
        child: Row(
          mainAxisAlignment: collapsed
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          mainAxisSize: collapsed ? MainAxisSize.min : MainAxisSize.max,
          children: [
            Icon(icon, size: 18, color: color),
            if (!collapsed) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall!.copyWith(color: color),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return Semantics(
      label: label,
      button: true,
      selected: selected,
      child: collapsed ? Tooltip(message: label, child: button) : button,
    );
  }
}

class SettingsScreen extends StatefulWidget {
  /// Creates a [SettingsScreen] instance.
  const SettingsScreen({
    super.key,
    required this.apiClient,
    required this.appVersion,
    required this.themeMode,
    this.onThemeModeChanged,
    this.onClose,
    this.initialUpdateCheckResult,
    this.onCheckForUpdates,
    this.onUpdateCheckResultChanged,
  });

  final CalfClient apiClient;
  final String appVersion;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;
  final VoidCallback? onClose;
  final UpdateCheckResult? initialUpdateCheckResult;
  final Future<void> Function()? onCheckForUpdates;
  final ValueChanged<UpdateCheckResult>? onUpdateCheckResultChanged;

  /// Creates the state object for [SettingsScreen].
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Config? _config;
  bool _configLoading = true;
  String? _configError;
  bool _saving = false;
  double _draftCpus = 4;
  double _draftMemory = 4;
  double _draftSwap = 1;
  double _draftDisk = 100;
  bool _draftResourceSaverEnabled = true;
  int _draftResourceSaverTimeoutSec = 300;
  final _diskImageController = TextEditingController();
  final _httpProxyController = TextEditingController();
  final _httpsProxyController = TextEditingController();
  final _noProxyInputController = TextEditingController();
  List<String> _noProxyEntries = [];
  String? _httpProxyError;
  String? _httpsProxyError;
  bool _migrating = false;
  MigrationStatus? _migrationStatus;
  bool _dockerContextManaged = true;
  bool _dockerContextSaving = false;
  bool? _launchAtLoginEnabled;
  bool _launchAtLoginLoading = true;
  bool _launchAtLoginSaving = false;
  String? _launchAtLoginError;
  UpdateCheckResult? _updateCheckResult;
  bool _updateChecking = false;

  /// Whether any settings differ from the saved config.
  bool get _dirty =>
      _config != null &&
      (_draftCpus.toInt() != _config!.cpus ||
          _draftMemory.toInt() != _config!.memoryGB ||
          _draftSwap.toInt() != _config!.memorySwapGB ||
          _draftDisk.toInt() != _config!.diskGB ||
          _diskImageController.text.trim() != _config!.diskImage ||
          _httpProxyController.text.trim() != _config!.httpProxy ||
          _httpsProxyController.text.trim() != _config!.httpsProxy ||
          _noProxyEntries.join(',') != _config!.noProxy ||
          _draftResourceSaverEnabled != _config!.resourceSaverEnabled ||
          _draftResourceSaverTimeoutSec != _config!.resourceSaverTimeoutSec);

  /// Releases resources when the widget is removed.
  @override
  void dispose() {
    _diskImageController.dispose();
    _httpProxyController.dispose();
    _httpsProxyController.dispose();
    _noProxyInputController.dispose();
    super.dispose();
  }

  /// Initializes state and starts async loading.
  @override
  void initState() {
    super.initState();
    _updateCheckResult = widget.initialUpdateCheckResult;
    loadConfig();
    loadLaunchAtLogin();
  }

  /// Syncs local state when the parent widget configuration changes.
  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialUpdateCheckResult != oldWidget.initialUpdateCheckResult) {
      _updateCheckResult = widget.initialUpdateCheckResult;
    }
  }

  /// Checks GitHub for a newer release.
  Future<void> checkForUpdates() async {
    if (widget.appVersion.isEmpty || widget.onCheckForUpdates == null) {
      return;
    }

    setState(() => _updateChecking = true);

    try {
      await widget.onCheckForUpdates!();
      if (!mounted) {
        return;
      }
      setState(() {
        _updateCheckResult = widget.initialUpdateCheckResult;
        _updateChecking = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _updateChecking = false);
    }
  }

  /// Opens the update download URL in the browser.
  Future<void> downloadUpdate(UpdateInfo update) async {
    await openExternalUrl(update.downloadUrl);
  }

  /// Records the given version as skipped and clears the update prompt.
  Future<void> skipUpdateVersion(UpdateInfo update) async {
    await UpdatePreferences.saveSkippedVersion(update.version);
    if (!mounted) {
      return;
    }

    final result = UpdateCheckResult.upToDate(
      currentVersion: widget.appVersion,
      checkedAt: _updateCheckResult?.checkedAt,
    );
    setState(() => _updateCheckResult = result);
    widget.onUpdateCheckResultChanged?.call(result);
  }

  /// Loads daemon configuration into the settings form.
  Future<void> loadConfig() async {
    setState(() {
      _configLoading = true;
      _configError = null;
    });

    try {
      final config = await widget.apiClient.fetchConfig();
      if (!mounted) return;
      setState(() {
        _config = config;
        _draftCpus = config.cpus.toDouble();
        _draftMemory = config.memoryGB.toDouble();
        _draftSwap = config.memorySwapGB.toDouble();
        _draftDisk = config.diskGB.toDouble();
        _draftResourceSaverEnabled = config.resourceSaverEnabled;
        _draftResourceSaverTimeoutSec = config.resourceSaverTimeoutSec;
        _diskImageController.text = config.diskImage;
        _httpProxyController.text = config.httpProxy;
        _httpsProxyController.text = config.httpsProxy;
        _noProxyEntries = config.noProxy
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        _httpProxyError = null;
        _httpsProxyError = null;
        _dockerContextManaged = config.dockerContextManaged;
        _configLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _configError = error.toString();
        _configLoading = false;
      });
    }
  }

  /// Saves changed resource and proxy settings to the daemon.
  Future<void> applyConfig() async {
    final current = _config;
    if (current == null) return;

    setState(() => _saving = true);

    try {
      final updated = await widget.apiClient.updateConfig(
        current.copyWith(
          cpus: _draftCpus.toInt(),
          memoryGB: _draftMemory.toInt(),
          memorySwapGB: _draftSwap.toInt(),
          diskGB: _draftDisk.toInt(),
          diskImage: _diskImageController.text.trim(),
          httpProxy: _httpProxyController.text.trim(),
          httpsProxy: _httpsProxyController.text.trim(),
          noProxy: _noProxyEntries.join(','),
          resourceSaverEnabled: _draftResourceSaverEnabled,
          resourceSaverTimeoutSec: _draftResourceSaverTimeoutSec,
        ),
      );
      if (!mounted) return;
      setState(() {
        _config = updated;
        _draftCpus = updated.cpus.toDouble();
        _draftMemory = updated.memoryGB.toDouble();
        _draftSwap = updated.memorySwapGB.toDouble();
        _draftDisk = updated.diskGB.toDouble();
        _draftResourceSaverEnabled = updated.resourceSaverEnabled;
        _draftResourceSaverTimeoutSec = updated.resourceSaverTimeoutSec;
        _diskImageController.text = updated.diskImage;
        _httpProxyController.text = updated.httpProxy;
        _httpsProxyController.text = updated.httpsProxy;
        _noProxyEntries = updated.noProxy
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        _httpProxyError = null;
        _httpsProxyError = null;
        _configError = null;
        _saving = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Settings saved')));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _configError = error.toString();
      });
    }
  }

  /// Starts migration from Docker Desktop.
  Future<void> startDockerDesktopMigration() async {
    setState(() {
      _migrating = true;
      _migrationStatus = null;
    });

    try {
      final status = await widget.apiClient.startDockerDesktopMigration();
      if (!mounted) return;
      setState(() => _migrationStatus = status);
      await _pollMigrationStatus();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _migrating = false;
        _migrationStatus = MigrationStatus(
          phase: 'failed',
          step: 'error',
          progress: 0,
          message: error.toString(),
          error: error.toString(),
          summary: const MigrationSummary(
            configApplied: false,
            imagesTotal: 0,
            imagesOK: 0,
            volumesTotal: 0,
            volumesOK: 0,
            containersTotal: 0,
            containersOK: 0,
            buildsTotal: 0,
            buildsOK: 0,
          ),
        );
      });
    }
  }

  /// Polls migration status until it completes or fails.
  Future<void> _pollMigrationStatus() async {
    while (mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;

      try {
        final status = await widget.apiClient.fetchDockerDesktopMigration();
        if (!mounted) return;

        setState(() => _migrationStatus = status);

        if (!status.isRunning) {
          setState(() => _migrating = false);
          if (status.phase == 'completed') {
            await loadConfig();
          }
          return;
        }
      } catch (_) {
        if (!mounted) return;
        setState(() => _migrating = false);
        return;
      }
    }
  }

  /// Loads whether open-at-login is enabled.
  Future<void> loadLaunchAtLogin() async {
    setState(() {
      _launchAtLoginLoading = true;
      _launchAtLoginError = null;
    });

    try {
      final enabled = await LaunchAtLogin.isEnabled();
      if (!mounted) {
        return;
      }
      setState(() {
        _launchAtLoginEnabled = enabled;
        _launchAtLoginLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _launchAtLoginEnabled = false;
        _launchAtLoginLoading = false;
      });
    }
  }

  /// Enables or disables open-at-login.
  Future<void> setLaunchAtLoginEnabled(bool value) async {
    setState(() {
      _launchAtLoginSaving = true;
      _launchAtLoginError = null;
    });

    try {
      final ok = await LaunchAtLogin.setEnabled(value);
      if (!mounted) {
        return;
      }
      if (!ok) {
        setState(() {
          _launchAtLoginSaving = false;
          _launchAtLoginError = 'Could not update startup setting.';
        });
        return;
      }

      final enabled = await LaunchAtLogin.isEnabled();
      if (!mounted) {
        return;
      }
      setState(() {
        _launchAtLoginEnabled = enabled;
        _launchAtLoginSaving = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _launchAtLoginSaving = false;
        _launchAtLoginError = 'Could not update startup setting.';
      });
    }
  }

  /// Toggles whether Calf manages the Docker CLI context.
  Future<void> setDockerContextManaged(bool value) async {
    final current = _config;
    if (current == null) return;

    setState(() {
      _dockerContextManaged = value;
      _dockerContextSaving = true;
    });

    try {
      final updated = await widget.apiClient.updateConfig(
        current.copyWith(dockerContextManaged: value),
      );
      if (!mounted) return;
      setState(() {
        _config = updated;
        _dockerContextManaged = updated.dockerContextManaged;
        _dockerContextSaving = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _dockerContextManaged = current.dockerContextManaged;
        _dockerContextSaving = false;
        _configError = error.toString();
      });
    }
  }

  /// Builds the widget tree.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Settings', style: theme.textTheme.headlineSmall),
              ),
              if (widget.onClose != null)
                Tooltip(
                  message: 'Close settings',
                  child: CalfButton.ghost(
                    width: 36,
                    height: 36,
                    onPressed: widget.onClose,
                    child: const Icon(LucideIcons.x, size: 16),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          _settingRow(
            'Use Calf for Docker CLI',
            Switch(
              value: _dockerContextManaged,
              onChanged: _dockerContextSaving ? null : setDockerContextManaged,
            ),
          ),
          if (_config != null) ...[
            const SizedBox(height: 8),
            Text(
              _config!.dockerContextActive
                  ? 'Active context: calf'
                  : _config!.dockerContextName.isEmpty
                  ? 'Docker CLI context not set to calf'
                  : 'Active context: ${_config!.dockerContextName}',
              style: CalfTheme.muted(theme),
            ),
          ],
          const SizedBox(height: 16),
          _settingRow(
            'Open at login',
            Switch(
              value: _launchAtLoginEnabled ?? false,
              onChanged: _launchAtLoginLoading || _launchAtLoginSaving
                  ? null
                  : setLaunchAtLoginEnabled,
            ),
          ),
          if (_launchAtLoginError != null) ...[
            const SizedBox(height: 8),
            Text(
              _launchAtLoginError!,
              style: theme.textTheme.titleMedium!.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 16),
          _sectionHeader('Theme', theme),
          const SizedBox(height: 12),
          _themeModePicker(theme),
          const SizedBox(height: 24),
          _sectionHeader('Updates', theme),
          const SizedBox(height: 12),
          Text(
            widget.appVersion.isEmpty
                ? 'Loading version...'
                : 'Current version: ${widget.appVersion}',
            style: CalfTheme.muted(theme),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              CalfButton(
                onPressed: _updateChecking || widget.appVersion.isEmpty
                    ? null
                    : checkForUpdates,
                enabled: !_updateChecking && widget.appVersion.isNotEmpty,
                child: Text(
                  _updateChecking ? 'Checking...' : 'Check for updates',
                ),
              ),
              if (_updateCheckResult?.hasUpdate == true &&
                  _updateCheckResult!.latest != null) ...[
                const SizedBox(width: 12),
                CalfButton(
                  onPressed: () => downloadUpdate(_updateCheckResult!.latest!),
                  child: Text(
                    'Download ${_updateCheckResult!.latest!.version}',
                  ),
                ),
              ],
            ],
          ),
          if (_updateCheckResult != null) ...[
            const SizedBox(height: 12),
            if (_updateCheckResult!.error != null)
              Text(
                _updateCheckResult!.error!,
                style: theme.textTheme.titleMedium!.copyWith(
                  color: theme.colorScheme.error,
                ),
              )
            else if (_updateCheckResult!.hasUpdate &&
                _updateCheckResult!.latest != null) ...[
              Text(
                'Version ${_updateCheckResult!.latest!.version} is available.',
                style: theme.textTheme.titleMedium,
              ),
              if (_updateCheckResult!.latest!.releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _updateCheckResult!.latest!.releaseNotes,
                  style: CalfTheme.muted(theme),
                ),
              ],
              const SizedBox(height: 8),
              CalfButton.outline(
                onPressed: () => skipUpdateVersion(_updateCheckResult!.latest!),
                child: const Text('Skip this version'),
              ),
            ] else
              Text('You are up to date.', style: CalfTheme.muted(theme)),
          ],
          const SizedBox(height: 24),
          _sectionHeader('Migration', theme),
          const SizedBox(height: 12),
          Text(
            'Import settings, images, volumes, containers and build history from Docker Desktop.',
            style: CalfTheme.muted(theme),
          ),
          const SizedBox(height: 12),
          CalfButton(
            onPressed: _migrating ? null : startDockerDesktopMigration,
            enabled: !_migrating,
            child: Text(
              _migrating ? 'Migrating...' : 'Migrate from Docker Desktop',
            ),
          ),
          if (_migrationStatus != null) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _migrationStatus!.progress / 100),
            const SizedBox(height: 8),
            Text(_migrationStatus!.message, style: theme.textTheme.titleMedium),
            if (_migrationStatus!.error != null &&
                _migrationStatus!.error!.isNotEmpty)
              Text(
                _migrationStatus!.error!,
                style: theme.textTheme.titleMedium!.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            if (_migrationStatus!.phase == 'completed') ...[
              const SizedBox(height: 8),
              Text(
                'Images: ${_migrationStatus!.summary.imagesOK}/${_migrationStatus!.summary.imagesTotal} · '
                'Volumes: ${_migrationStatus!.summary.volumesOK}/${_migrationStatus!.summary.volumesTotal} · '
                'Containers: ${_migrationStatus!.summary.containersOK}/${_migrationStatus!.summary.containersTotal} · '
                'Builds: ${_migrationStatus!.summary.buildsOK}/${_migrationStatus!.summary.buildsTotal}',
                style: CalfTheme.muted(theme),
              ),
            ],
          ],
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Proxy'),
                      if (_config != null &&
                          (_config!.httpProxy.isNotEmpty ||
                              _config!.httpsProxy.isNotEmpty ||
                              _config!.noProxy.isNotEmpty))
                        const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: Chip(
                            label: Text('Configured'),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'HTTP and HTTPS proxy settings for image pulls inside the VM.',
                  ),
                  const SizedBox(height: 12),
                  _proxyField(
                    label: 'HTTP proxy',
                    controller: _httpProxyController,
                    placeholder: 'http://proxy.example.com:8080',
                    icon: LucideIcons.globe,
                    theme: theme,
                    error: _httpProxyError,
                    onChanged: _validateHttpProxy,
                  ),
                  const SizedBox(height: 12),
                  _proxyField(
                    label: 'HTTPS proxy',
                    controller: _httpsProxyController,
                    placeholder: 'http://proxy.example.com:8080',
                    icon: LucideIcons.lock,
                    theme: theme,
                    error: _httpsProxyError,
                    onChanged: _validateHttpsProxy,
                  ),
                  const SizedBox(height: 12),
                  _noProxySection(theme),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          _sectionHeader('System', theme),
          const SizedBox(height: 12),
          if (_configLoading)
            Text('Loading config...', style: CalfTheme.muted(theme))
          else if (_configError != null)
            Text(
              _configError!,
              style: theme.textTheme.titleMedium!.copyWith(
                color: theme.colorScheme.error,
              ),
            )
          else if (_config != null) ...[
            _sliderRow(
              'Memory limit',
              _draftMemory,
              1,
              _config!.hostMemoryGB.toDouble(),
              (value) => setState(() => _draftMemory = value),
              trailing: Text('${_draftMemory.toInt()} GB'),
            ),
            const SizedBox(height: 16),
            _sliderRow(
              'Memory swap',
              _draftSwap,
              0,
              _config!.hostMemoryGB.toDouble(),
              (value) => setState(() => _draftSwap = value),
              trailing: Text('${_draftSwap.toInt()} GB'),
            ),
            const SizedBox(height: 16),
            _sliderRow(
              'CPU limit',
              _draftCpus,
              1,
              _config!.hostCPUs.toDouble(),
              (value) => setState(() => _draftCpus = value),
              trailing: Text('${_draftCpus.toInt()} cores'),
            ),
            const SizedBox(height: 16),
            _sliderRow(
              'Disk image size',
              _draftDisk,
              1,
              _config!.hostDiskGB.toDouble(),
              (value) => setState(() => _draftDisk = value),
              trailing: Text('${_draftDisk.toInt()} GB'),
            ),
            const SizedBox(height: 16),
            _diskImageField(theme),
            const SizedBox(height: 24),
            _resourceSaverSection(theme),
            const SizedBox(height: 24),
            CalfButton(
              onPressed:
                  _dirty &&
                      !_saving &&
                      _httpProxyError == null &&
                      _httpsProxyError == null
                  ? applyConfig
                  : null,
              enabled:
                  _dirty && _httpProxyError == null && _httpsProxyError == null,
              child: Text(_saving ? 'Saving...' : 'Apply'),
            ),
          ],
        ],
      ),
    );
  }

  /// Builds the Resource Saver toggle and idle-timeout slider.
  Widget _resourceSaverSection(ThemeData theme) {
    final timeoutIndex = CalfResourceSaver.indexForSeconds(
      _draftResourceSaverTimeoutSec,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Resource Saver',
          style: theme.textTheme.titleMedium!.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        _settingRow(
          'Enable Resource Saver',
          Switch(
            value: _draftResourceSaverEnabled,
            onChanged: (value) =>
                setState(() => _draftResourceSaverEnabled = value),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Reduces CPU and memory utilization when no containers are running. '
          'Exit from Resource Saver mode happens automatically when containers are started.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 8),
        Text(
          'Use the slider to set the duration of time between no containers '
          'running and Calf entering Resource Saver mode.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 12),
        IgnorePointer(
          ignoring: !_draftResourceSaverEnabled,
          child: Opacity(
            opacity: _draftResourceSaverEnabled ? 1 : 0.45,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Slider(
                  value: timeoutIndex.toDouble(),
                  min: 0,
                  max: (CalfResourceSaver.timeoutSeconds.length - 1).toDouble(),
                  divisions: CalfResourceSaver.timeoutSeconds.length - 1,
                  label: CalfResourceSaver.labelForSeconds(
                    CalfResourceSaver.timeoutSeconds[timeoutIndex],
                  ),
                  onChanged: (value) {
                    setState(() {
                      _draftResourceSaverTimeoutSec =
                          CalfResourceSaver.timeoutSeconds[value.round()];
                    });
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      for (final seconds in CalfResourceSaver.timeoutSeconds)
                        Expanded(
                          child: Text(
                            CalfResourceSaver.showTickLabel(seconds)
                                ? CalfResourceSaver.labelForSeconds(seconds)
                                : '',
                            textAlign: TextAlign.center,
                            style: CalfTheme.muted(
                              theme,
                            ).copyWith(fontSize: 10),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Builds the Light / Dark / System theme picker with preview cards.
  Widget _themeModePicker(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: _themeModeCard(
            theme: theme,
            mode: ThemeMode.light,
            label: 'Light',
            icon: LucideIcons.sun,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _themeModeCard(
            theme: theme,
            mode: ThemeMode.dark,
            label: 'Dark',
            icon: LucideIcons.moon,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _themeModeCard(
            theme: theme,
            mode: ThemeMode.system,
            label: 'System',
            icon: LucideIcons.monitor,
          ),
        ),
      ],
    );
  }

  /// Builds one selectable theme preview card.
  Widget _themeModeCard({
    required ThemeData theme,
    required ThemeMode mode,
    required String label,
    required IconData icon,
  }) {
    final selected = widget.themeMode == mode;
    final enabled = widget.onThemeModeChanged != null;
    final borderColor = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.outlineVariant;
    final labelColor = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;

    return Material(
      animationDuration: CalfTheme.materialAnimationDuration,
      color: selected
          ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.45)
          : theme.colorScheme.surface,
      borderRadius: CalfTheme.radius,
      child: InkWell(
        onTap: enabled ? () => widget.onThemeModeChanged!(mode) : null,
        borderRadius: CalfTheme.radius,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
          decoration: BoxDecoration(
            borderRadius: CalfTheme.radius,
            border: Border.all(color: borderColor, width: 2),
          ),
          child: Column(
            children: [
              _themePreview(mode),
              const SizedBox(height: 10),
              Icon(icon, size: 16, color: labelColor),
              const SizedBox(height: 6),
              Text(
                label,
                style: theme.textTheme.bodySmall!.copyWith(
                  color: labelColor,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Draws a miniature window preview for [mode].
  Widget _themePreview(ThemeMode mode) {
    const lightBg = Color(0xFFF8FAFC);
    const lightPanel = Color(0xFFFFFFFF);
    const lightLine = Color(0xFFE2E8F0);
    const darkBg = Color(0xFF020817);
    const darkPanel = Color(0xFF1E293B);
    const darkLine = Color(0xFF334155);
    const accent = CalfColors.primary;

    Widget half({
      required Color background,
      required Color panel,
      required Color line,
    }) {
      return ColoredBox(
        color: background,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 5, 6, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    decoration: const BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: panel,
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: line),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final preview = switch (mode) {
      ThemeMode.light => half(
        background: lightBg,
        panel: lightPanel,
        line: lightLine,
      ),
      ThemeMode.dark => half(
        background: darkBg,
        panel: darkPanel,
        line: darkLine,
      ),
      ThemeMode.system => Row(
        children: [
          Expanded(
            child: half(
              background: lightBg,
              panel: lightPanel,
              line: lightLine,
            ),
          ),
          Expanded(
            child: half(background: darkBg, panel: darkPanel, line: darkLine),
          ),
        ],
      ),
    };

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(height: 56, width: double.infinity, child: preview),
    );
  }

  /// Builds a settings section header label.
  Widget _sectionHeader(String label, ThemeData theme) {
    return Text(
      label,
      style: theme.textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w600),
    );
  }

  /// Builds a label-control row for a settings toggle.
  Widget _settingRow(String label, Widget control) {
    return Row(
      children: [
        Flexible(
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        const SizedBox(width: 16),
        control,
      ],
    );
  }

  /// Builds a labeled slider row for a numeric setting.
  Widget _sliderRow(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    final safeMax = max < min ? min : max;
    final safeValue = value.clamp(min, safeMax);
    final divisions = (safeMax - min).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: safeValue,
                min: min,
                max: safeMax,
                divisions: divisions > 0 ? divisions : null,
                // ignore: deprecated_member_use
                year2023: false,
                onChanged: _saving ? null : onChanged,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              SizedBox(
                width: 88,
                child: Align(alignment: Alignment.centerRight, child: trailing),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// Builds the disk image location text field with a folder browse button.
  Widget _diskImageField(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Disk image location', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _diskImageController,
                enabled: !_saving,
                decoration: InputDecoration(
                  hintText: '~/.config/calf/guest/calf/disk.raw',
                  prefixIcon: Icon(
                    LucideIcons.folder,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            CalfButton.outline(
              onPressed: _saving ? null : _browseDiskImageDirectory,
              child: const Text('Browse'),
            ),
          ],
        ),
      ],
    );
  }

  /// Opens a folder picker and sets the disk image path under the chosen directory.
  Future<void> _browseDiskImageDirectory() async {
    try {
      final directory = await getDirectoryPath(confirmButtonText: 'Select');
      if (directory == null || !mounted) {
        return;
      }
      final current = _diskImageController.text.trim();
      final fileName = current.isEmpty ? 'disk.raw' : p.basename(current);
      setState(() {
        _diskImageController.text = p.join(directory, fileName);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = folderPickerErrorMessage(error);
      if (message == null) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Validates the HTTP proxy field and updates the error state.
  void _validateHttpProxy(String value) {
    setState(() => _httpProxyError = _validateProxyUrl(value, ['http']));
  }

  /// Validates the HTTPS proxy field and updates the error state.
  void _validateHttpsProxy(String value) {
    setState(
      () => _httpsProxyError = _validateProxyUrl(value, ['http', 'https']),
    );
  }

  /// Returns a validation error for an invalid proxy URL, or null.
  String? _validateProxyUrl(String value, List<String> allowedSchemes) {
    final v = value.trim();
    if (v.isEmpty) return null;
    final hasScheme = allowedSchemes.any((s) => v.startsWith('$s://'));
    if (!hasScheme) {
      return allowedSchemes.length == 1
          ? 'Must start with ${allowedSchemes.first}://'
          : 'Must start with ${allowedSchemes.join(' or ')}://';
    }
    final uri = Uri.tryParse(v);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return 'Invalid URL format';
    }
    return null;
  }

  /// Builds the no-proxy host list editor section.
  Widget _noProxySection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'No proxy',
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        if (_noProxyEntries.isNotEmpty) ...[
          Semantics(
            container: true,
            label: 'No proxy hosts',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in _noProxyEntries)
                  InputChip(
                    label: Text(entry),
                    labelStyle: theme.textTheme.bodyMedium!.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    deleteIcon: const Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(LucideIcons.x, size: 12),
                    ),
                    deleteIconColor: theme.colorScheme.onSurfaceVariant,
                    deleteButtonTooltipMessage:
                        'Remove $entry from no proxy list',
                    onDeleted: () {
                      setState(() => _noProxyEntries.remove(entry));
                    },
                    side: BorderSide(color: theme.colorScheme.outline),
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    shape: const RoundedRectangleBorder(
                      borderRadius: CalfTheme.radius,
                    ),
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _noProxyInputController,
                decoration: InputDecoration(
                  hintText: 'localhost',
                  prefixIcon: Icon(
                    LucideIcons.ban,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (value) {
                  _addNoProxyEntry(value, theme);
                },
              ),
            ),
            const SizedBox(width: 8),
            CalfButton.outline(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              onPressed: _noProxyInputController.text.trim().isEmpty
                  ? null
                  : () => _addNoProxyEntry(_noProxyInputController.text, theme),
              child: const Text('Add'),
            ),
          ],
        ),
        if (_noProxyInputController.text.trim().isNotEmpty &&
            !_isValidNoProxyEntry(_noProxyInputController.text.trim()))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Must be a valid hostname or IP address',
              style: CalfTheme.muted(theme).copyWith(fontSize: 12),
            ),
          ),
      ],
    );
  }

  /// Adds a validated host to the no-proxy list.
  void _addNoProxyEntry(String rawValue, ThemeData theme) {
    final value = rawValue.trim();
    if (value.isEmpty || _noProxyEntries.contains(value)) return;
    if (!_isValidNoProxyEntry(value)) return;
    setState(() {
      _noProxyEntries.add(value);
      _noProxyInputController.clear();
    });
  }

  /// Whether the entry is a valid hostname, IP, or host:port.
  bool _isValidNoProxyEntry(String entry) {
    if (entry.isEmpty) return false;
    if (entry.contains('/')) return false;
    final host = entry.startsWith('.') ? entry.substring(1) : entry;
    if (_isIpAddress(host)) return true;
    final colonIdx = host.lastIndexOf(':');
    if (colonIdx > 0) {
      final port = host.substring(colonIdx + 1);
      if (RegExp(r'^\d+$').hasMatch(port)) {
        return _isValidHostname(host.substring(0, colonIdx));
      }
    }
    return _isValidHostname(host);
  }

  /// Whether [host] looks like an IPv4 address.
  bool _isIpAddress(String host) {
    return RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(host);
  }

  /// Whether [host] is a valid DNS hostname.
  bool _isValidHostname(String host) {
    if (host.isEmpty || host.length > 253) return false;
    final parts = host.split('.');
    for (final part in parts) {
      if (part.isEmpty || part.length > 63) return false;
      if (part.startsWith('-') || part.endsWith('-')) return false;
      if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(part)) return false;
    }
    return true;
  }

  /// Builds a labeled proxy URL input field.
  Widget _proxyField({
    required String label,
    required TextEditingController controller,
    required String placeholder,
    required IconData icon,
    required ThemeData theme,
    String? error,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: placeholder,
            prefixIcon: Icon(
              icon,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            suffixIcon: controller.text.isNotEmpty
                ? IconButton(
                    icon: Icon(
                      LucideIcons.x,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    visualDensity: VisualDensity.compact,
                  )
                : null,
          ),
          onChanged: (value) {
            setState(() {});
            onChanged(value);
          },
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              error,
              style: CalfTheme.muted(
                theme,
              ).copyWith(fontSize: 12, color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}

/// Pending bottom-bar engine action shown while Start/Stop is in flight.
enum _EnginePendingAction { none, starting, stopping }

extension on _EnginePendingAction {
  /// User-visible label for the badge, or empty when idle.
  String get label => switch (this) {
    _EnginePendingAction.none => '',
    _EnginePendingAction.starting => 'Engine starting…',
    _EnginePendingAction.stopping => 'Engine stopping…',
  };
}
