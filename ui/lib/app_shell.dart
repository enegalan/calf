import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/platform/macos_menu.dart';
import 'package:ui/platform/tray_status.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/screens/builds_screen.dart';
import 'package:ui/screens/containers_screen.dart';
import 'package:ui/screens/disk_cleanup_screen.dart';
import 'package:ui/screens/images_screen.dart';
import 'package:ui/screens/networks_screen.dart';
import 'package:ui/screens/settings_screen.dart';
import 'package:ui/screens/troubleshoot_screen.dart';
import 'package:ui/screens/volumes_screen.dart';
import 'package:ui/storage/sidebar_preferences.dart';
import 'package:ui/updates/update_checker.dart';
import 'package:ui/updates/update_dialog.dart';
import 'package:ui/updates/update_info.dart';
import 'package:ui/widgets/about_dialog.dart';
import 'package:ui/widgets/app_bottom_bar.dart';
import 'package:ui/widgets/app_top_bar.dart';
import 'package:ui/widgets/build_row_icons.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/calf_snack_bar.dart';
import 'package:ui/widgets/global_search_dialog.dart';
import 'package:ui/theme/calf_theme.dart';
import 'package:ui/constants/calf_constants.dart';

class AppShell extends StatefulWidget {
  /// Creates a [AppShell] instance.
  AppShell({
    super.key,
    CalfClient? apiClient,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
    this.onRestartDaemon,
    this.usesExternalDaemon = false,
  }) : apiClient = apiClient ?? ApiClient();

  final CalfClient apiClient;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  /// Restarts the embedded calf-daemon process itself (full calf restart),
  /// as opposed to [_AppShellState._restartEngine] which only stops/starts
  /// the container engine inside an already-running daemon.
  final Future<void> Function()? onRestartDaemon;

  /// True when the UI connects to a separately started daemon (`make
  /// dev-backend`) instead of spawning `calf-daemon` itself.
  final bool usesExternalDaemon;

  /// Creates the state object for [AppShell].
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  bool _showSettings = false;
  bool _showTroubleshoot = false;
  bool _showDiskCleanup = false;
  String? _pendingImageReference;
  String? _pendingContainerId;
  String? _pendingVolumeName;
  String? _pendingNetworkName;
  String? _pendingBuildId;
  RegistryLoginStatus? _registryStatus;
  bool _registryLoading = true;
  bool _registryBrowserLoginPending = false;
  String _appVersion = '';
  DaemonStatus? _daemonStatus;
  int _daemonStatusFailureCount = 0;
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
          onRestartEngine: _restartEngine,
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
      _daemonStatusFailureCount = 0;
      setState(() {
        _daemonStatus = status;
        if (status.version.isNotEmpty) {
          _appVersion = status.version;
        }
      });
    } on ApiException catch (error) {
      debugPrint('Failed to poll daemon status: ${error.message}');
      _markDaemonStatusFailure();
    } on TimeoutException catch (error) {
      debugPrint('Timed out polling daemon status: $error');
      _markDaemonStatusFailure();
    } on FormatException catch (error) {
      debugPrint('Failed to parse daemon status: $error');
      _markDaemonStatusFailure();
    }
  }

  /// Clears the stale daemon status after repeated consecutive polling
  /// failures, so the bottom bar stops showing an outdated "running" state.
  void _markDaemonStatusFailure() {
    _daemonStatusFailureCount++;
    if (_daemonStatusFailureCount >= 3 && mounted && _daemonStatus != null) {
      setState(() => _daemonStatus = null);
    }
  }

  /// Clears a pending deep-link after the current frame.
  ///
  /// Resource screens may consume the link from [State.didUpdateWidget],
  /// which runs during the parent build; calling [setState] synchronously
  /// there throws.
  void _clearPendingDeepLinkAfterFrame(VoidCallback clear) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      clear();
    });
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
      if (!mounted) return;
      final successMessage = switch (pending) {
        _EnginePendingAction.starting => 'Engine started',
        _EnginePendingAction.stopping => 'Engine stopped',
        _EnginePendingAction.none => null,
      };
      if (successMessage != null) {
        showCalfSnackBar(context, successMessage);
      }
    } on ApiException catch (error) {
      debugPrint('Engine action failed: ${error.message}');
      if (!mounted) return;
      showCalfSnackBar(context, error.message);
    } on TimeoutException catch (error) {
      debugPrint('Engine action timed out: $error');
      if (!mounted) return;
      showCalfSnackBar(context, 'Engine action timed out');
    } finally {
      if (mounted) {
        setState(() {
          _engineActionBusy = false;
          _enginePending = _EnginePendingAction.none;
        });
      }
    }
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

    if (result.hasUpdate && result.latest != null) {
      if (force || !_updateDialogShown) {
        if (!force) {
          _updateDialogShown = true;
        }
        await showUpdateAvailableDialog(
          context: context,
          update: result.latest!,
          currentVersion: result.currentVersion,
          onDownload: () => openExternalUrl(result.latest!.downloadUrl),
        );
      }
    } else if (force) {
      if (result.error != null && result.error!.isNotEmpty) {
        showCalfSnackBar(context, result.error!);
      } else {
        showCalfSnackBar(context, "You're up to date.");
      }
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
      showCalfSnackBar(
        context,
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
          showCalfSnackBar(
            context,
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
            showCalfSnackBar(context, message);
          }
        },
      );

      if (!mounted) return;
      setState(() => _registryBrowserLoginPending = false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _registryBrowserLoginPending = false);
      showCalfSnackBar(
        context,
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
      if (!mounted) return;
      showCalfSnackBar(context, 'Signed out of Docker Hub');
    } catch (error) {
      if (!mounted) return;
      showCalfSnackBar(
        context,
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
      _showDiskCleanup = false;
      _showSettings = true;
    });
  }

  /// Opens the Troubleshoot screen from the engine menu.
  void openTroubleshoot() {
    setState(() {
      _showSettings = false;
      _showDiskCleanup = false;
      _showTroubleshoot = true;
    });
  }

  /// Opens the clean unused data screen from Troubleshoot.
  void openDiskCleanup() {
    setState(() {
      _showSettings = false;
      _showTroubleshoot = false;
      _showDiskCleanup = true;
    });
  }

  /// Closes settings and returns to the selected resource screen.
  void closeSettings() {
    setState(() {
      _showSettings = false;
      _showTroubleshoot = false;
      _showDiskCleanup = false;
    });
  }

  /// Returns from disk cleanup to the Troubleshoot screen.
  void closeDiskCleanup() {
    setState(() {
      _showDiskCleanup = false;
      _showTroubleshoot = true;
    });
  }

  /// Navigates to a sidebar section by index.
  void navigateToSection(int index) {
    setState(() {
      _selectedIndex = index;
      _showSettings = false;
      _showTroubleshoot = false;
      _showDiskCleanup = false;
    });
  }

  /// Opens the Images screen detail for [imageReference].
  void openImageView(String imageReference) {
    final reference = imageReference.trim();
    if (reference.isEmpty) {
      return;
    }
    setState(() {
      _selectedIndex = 1;
      _pendingImageReference = reference;
      _showSettings = false;
      _showTroubleshoot = false;
      _showDiskCleanup = false;
    });
  }

  /// Opens the Containers screen detail for [containerId].
  void openContainerView(String containerId) {
    final id = containerId.trim();
    if (id.isEmpty) {
      return;
    }
    setState(() {
      _selectedIndex = 0;
      _pendingContainerId = id;
      _showSettings = false;
      _showTroubleshoot = false;
      _showDiskCleanup = false;
    });
  }

  /// Opens the Volumes screen detail for [volumeName].
  void openVolumeView(String volumeName) {
    final name = volumeName.trim();
    if (name.isEmpty) {
      return;
    }
    setState(() {
      _selectedIndex = 2;
      _pendingVolumeName = name;
      _showSettings = false;
      _showTroubleshoot = false;
      _showDiskCleanup = false;
    });
  }

  /// Opens the Networks screen detail for [networkName].
  void openNetworkView(String networkName) {
    final name = networkName.trim();
    if (name.isEmpty) {
      return;
    }
    setState(() {
      _selectedIndex = 3;
      _pendingNetworkName = name;
      _showSettings = false;
      _showTroubleshoot = false;
      _showDiskCleanup = false;
    });
  }

  /// Opens the Builds screen detail for [buildId].
  void openBuildView(String buildId) {
    final id = buildId.trim();
    if (id.isEmpty) {
      return;
    }
    setState(() {
      _selectedIndex = 4;
      _pendingBuildId = id;
      _showSettings = false;
      _showTroubleshoot = false;
      _showDiskCleanup = false;
    });
  }

  /// Opens the global resource search palette.
  Future<void> openGlobalSearch() async {
    final hit = await showGlobalSearchDialog(
      context,
      apiClient: widget.apiClient,
    );
    if (!mounted || hit == null) {
      return;
    }
    switch (hit.kind) {
      case GlobalSearchKind.container:
        openContainerView(hit.id);
      case GlobalSearchKind.image:
        openImageView(hit.id);
      case GlobalSearchKind.volume:
        openVolumeView(hit.id);
      case GlobalSearchKind.network:
        openNetworkView(hit.id);
      case GlobalSearchKind.build:
        openBuildView(hit.id);
    }
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
      (label: 'Containers', icon: LucideIcons.box, svgAsset: null),
      (label: 'Images', icon: null, svgAsset: buildPlaceholderIconAsset),
      (label: 'Volumes', icon: LucideIcons.hardDrive, svgAsset: null),
      (label: 'Networks', icon: LucideIcons.network, svgAsset: null),
      (label: 'Builds', icon: LucideIcons.wrench, svgAsset: null),
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
          onOpenGlobalSearch: () => unawaited(openGlobalSearch()),
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
                                      svgAsset: navItems[index].svgAsset,
                                      selected:
                                          !_showSettings &&
                                          !_showTroubleshoot &&
                                          !_showDiskCleanup &&
                                          _selectedIndex == index,
                                      collapsed: isCurrentlyCollapsed,
                                      onTap: () => setState(() {
                                        _selectedIndex = index;
                                        _showSettings = false;
                                        _showTroubleshoot = false;
                                        _showDiskCleanup = false;
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
                      child: _showDiskCleanup
                          ? DiskCleanupScreen(
                              apiClient: widget.apiClient,
                              onClose: closeDiskCleanup,
                            )
                          : _showTroubleshoot
                          ? TroubleshootScreen(
                              apiClient: widget.apiClient,
                              onClose: closeSettings,
                              onRestart:
                                  widget.onRestartDaemon ?? _restartEngine,
                              onQuit: CalfTrayStatus.quitApp,
                              usesExternalDaemon: widget.usesExternalDaemon,
                              onCleanUnusedData: openDiskCleanup,
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
                                onOpenImage: openImageView,
                                initialContainerId: _pendingContainerId,
                                onInitialContainerConsumed: () {
                                  if (_pendingContainerId == null) {
                                    return;
                                  }
                                  _clearPendingDeepLinkAfterFrame(() {
                                    if (_pendingContainerId == null) {
                                      return;
                                    }
                                    setState(() => _pendingContainerId = null);
                                  });
                                },
                              ),
                              1 => ImagesScreen(
                                apiClient: widget.apiClient,
                                initialImageReference: _pendingImageReference,
                                onInitialImageConsumed: () {
                                  if (_pendingImageReference == null) {
                                    return;
                                  }
                                  _clearPendingDeepLinkAfterFrame(() {
                                    if (_pendingImageReference == null) {
                                      return;
                                    }
                                    setState(
                                      () => _pendingImageReference = null,
                                    );
                                  });
                                },
                              ),
                              2 => VolumesScreen(
                                apiClient: widget.apiClient,
                                onOpenContainer: openContainerView,
                                initialVolumeName: _pendingVolumeName,
                                onInitialVolumeConsumed: () {
                                  if (_pendingVolumeName == null) {
                                    return;
                                  }
                                  _clearPendingDeepLinkAfterFrame(() {
                                    if (_pendingVolumeName == null) {
                                      return;
                                    }
                                    setState(() => _pendingVolumeName = null);
                                  });
                                },
                              ),
                              3 => NetworksScreen(
                                apiClient: widget.apiClient,
                                initialNetworkName: _pendingNetworkName,
                                onInitialNetworkConsumed: () {
                                  if (_pendingNetworkName == null) {
                                    return;
                                  }
                                  _clearPendingDeepLinkAfterFrame(() {
                                    if (_pendingNetworkName == null) {
                                      return;
                                    }
                                    setState(() => _pendingNetworkName = null);
                                  });
                                },
                              ),
                              _ => BuildsScreen(
                                apiClient: widget.apiClient,
                                initialBuildId: _pendingBuildId,
                                onInitialBuildConsumed: () {
                                  if (_pendingBuildId == null) {
                                    return;
                                  }
                                  _clearPendingDeepLinkAfterFrame(() {
                                    if (_pendingBuildId == null) {
                                      return;
                                    }
                                    setState(() => _pendingBuildId = null);
                                  });
                                },
                              ),
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
                          : 0.0,
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

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () {
          unawaited(openGlobalSearch());
        },
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
          unawaited(openGlobalSearch());
        },
      },
      child: Focus(
        autofocus: true,
        child: MacosMenuScope(
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
          onOpenGlobalSearch: () => unawaited(openGlobalSearch()),
          onReportIssue: () => openExternalUrl(calfReportIssueUrl),
          onOpenRepository: () => openExternalUrl(calfRepositoryUrl),
          onOpenTroubleshoot: openTroubleshoot,
          child: Scaffold(body: CalfToastLayer(child: shell)),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  /// Creates a sidebar navigation row.
  const _NavItem({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.svgAsset,
    this.collapsed = false,
  }) : assert(icon != null || svgAsset != null);

  final String label;
  final IconData? icon;
  final String? svgAsset;
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
    final leading = svgAsset != null
        ? SvgPicture.asset(
            svgAsset!,
            width: 18,
            height: 18,
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          )
        : Icon(icon, size: 18, color: color);

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
            leading,
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
