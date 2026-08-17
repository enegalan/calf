import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/platform/launch_at_login.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/storage/window_preferences.dart';
import 'package:ui/theme/calf_theme.dart';
import 'package:ui/updates/update_info.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/calf_snack_bar.dart';
import 'package:ui/widgets/volume_export_form.dart';

/// Settings categories matching Docker Desktop's sidebar.
enum _SettingsTab {
  general,
  resources,
  engine,
  builders,
  updates,
  advanced,
}

/// One sidebar row in Settings.
class _SettingsNavItem {
  /// Creates a [_SettingsNavItem].
  const _SettingsNavItem({
    required this.tab,
    required this.label,
    required this.icon,
    required this.keywords,
  });

  final _SettingsTab tab;
  final String label;
  final IconData icon;
  final List<String> keywords;
}

/// Settings screen with a Docker Desktop-style sidebar and described options.
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
    this.onDebugChanged,
  });

  final CalfClient apiClient;
  final String appVersion;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;
  final VoidCallback? onClose;
  final UpdateCheckResult? initialUpdateCheckResult;
  final Future<void> Function()? onCheckForUpdates;
  final ValueChanged<UpdateCheckResult>? onUpdateCheckResultChanged;
  final ValueChanged<bool>? onDebugChanged;

  /// Creates the state object for [SettingsScreen].
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Config? _config;
  bool _configLoading = true;
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
  final _daemonJsonController = TextEditingController();
  final _fileSharesController = TextEditingController();
  final _dockerSubnetController = TextEditingController();
  List<String> _noProxyEntries = [];
  List<BuilderInfo> _builders = [];
  String? _httpProxyError;
  String? _httpsProxyError;
  bool _migrating = false;
  MigrationStatus? _migrationStatus;
  bool _dockerContextManaged = true;
  bool _dockerContextSaving = false;
  bool _debugSaving = false;
  bool? _launchAtLoginEnabled;
  bool _launchAtLoginLoading = true;
  bool _launchAtLoginSaving = false;
  String? _launchAtLoginError;
  bool _openWindowOnLaunch = true;
  bool _openWindowSaving = false;
  UpdateCheckResult? _updateCheckResult;
  bool _updateChecking = false;
  _SettingsTab _tab = _SettingsTab.general;
  final _searchController = TextEditingController();
  String _searchQuery = '';

  static const _navItems = [
    _SettingsNavItem(
      tab: _SettingsTab.general,
      label: 'General',
      icon: LucideIcons.slidersHorizontal,
      keywords: [
        'start',
        'login',
        'window',
        'theme',
        'light',
        'dark',
        'cli',
        'completions',
        'rosetta',
        'amd64',
        'emulation',
        'migration',
      ],
    ),
    _SettingsNavItem(
      tab: _SettingsTab.resources,
      label: 'Resources',
      icon: LucideIcons.cpu,
      keywords: [
        'cpu',
        'memory',
        'ram',
        'swap',
        'disk',
        'file shares',
        'proxy',
        'network',
        'subnet',
        'resource saver',
        'host networking',
        'localhost',
      ],
    ),
    _SettingsNavItem(
      tab: _SettingsTab.engine,
      label: 'Docker Engine',
      icon: LucideIcons.container,
      keywords: ['daemon', 'json', 'engine', 'dockerd'],
    ),
    _SettingsNavItem(
      tab: _SettingsTab.builders,
      label: 'Builders',
      icon: LucideIcons.hammer,
      keywords: ['buildx', 'builder', 'build'],
    ),
    _SettingsNavItem(
      tab: _SettingsTab.updates,
      label: 'Software updates',
      icon: LucideIcons.download,
      keywords: ['update', 'version', 'release'],
    ),
    _SettingsNavItem(
      tab: _SettingsTab.advanced,
      label: 'Advanced',
      icon: LucideIcons.shield,
      keywords: ['socket', 'privileged', 'ports', 'debug', 'password'],
    ),
  ];

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
          _draftResourceSaverTimeoutSec != _config!.resourceSaverTimeoutSec ||
          _daemonJsonController.text.trim() != _config!.daemonJSON ||
          _fileSharesController.text.trim() != _config!.fileShares.join(', ') ||
          _dockerSubnetController.text.trim() != _config!.dockerSubnet);

  /// Releases resources when the widget is removed.
  @override
  void dispose() {
    _diskImageController.dispose();
    _httpProxyController.dispose();
    _httpsProxyController.dispose();
    _noProxyInputController.dispose();
    _daemonJsonController.dispose();
    _fileSharesController.dispose();
    _dockerSubnetController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Initializes state and starts async loading.
  @override
  void initState() {
    super.initState();
    _updateCheckResult = widget.initialUpdateCheckResult;
    loadConfig();
    loadLaunchAtLogin();
    WindowPreferences.loadOpenOnLaunch().then((value) {
      if (!mounted) {
        return;
      }
      setState(() => _openWindowOnLaunch = value);
    });
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

  /// Loads daemon configuration into the settings form.
  Future<void> loadConfig() async {
    setState(() => _configLoading = true);

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
        _daemonJsonController.text = config.daemonJSON;
        _fileSharesController.text = config.fileShares.join(', ');
        _dockerSubnetController.text = config.dockerSubnet;
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
      unawaited(_loadBuilders());
    } catch (error) {
      if (!mounted) return;
      setState(() => _configLoading = false);
      showCalfErrorSnackBar(context, error);
    }
  }

  /// Loads docker buildx builders when the engine is running.
  Future<void> _loadBuilders() async {
    try {
      final builders = await widget.apiClient.fetchBuilders();
      if (!mounted) {
        return;
      }
      setState(() => _builders = builders);
    } on ApiException {
      if (mounted) {
        setState(() => _builders = []);
      }
    }
  }

  /// Copies the VM disk image to a user-chosen path. The engine must be stopped.
  Future<void> _copyDiskImage() async {
    final location = await getSaveLocation(suggestedName: 'calf-disk.raw');
    if (location == null || !mounted) {
      return;
    }
    final ok = await runCalfToastAction(
      pending: 'Copying disk image...',
      done: 'Disk image copied',
      action: () => widget.apiClient.copyDiskImage(location.path),
    );
    if (!ok && mounted) {
      return;
    }
  }

  /// PUTs a boolean config field and refreshes the view.
  Future<void> _patchBool(Config Function(Config current) update) async {
    final current = _config;
    if (current == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      final updated = await widget.apiClient.updateConfig(update(current));
      if (!mounted) {
        return;
      }
      setState(() {
        _config = updated;
        _saving = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _saving = false);
      showCalfErrorSnackBar(context, error);
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
          daemonJSON: _daemonJsonController.text.trim(),
          dockerSubnet: _dockerSubnetController.text.trim(),
          fileShares: _fileSharesController.text
              .split(',')
              .map((part) => part.trim())
              .where((part) => part.isNotEmpty)
              .toList(),
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
        _daemonJsonController.text = updated.daemonJSON;
        _fileSharesController.text = updated.fileShares.join(', ');
        _dockerSubnetController.text = updated.dockerSubnet;
        _noProxyEntries = updated.noProxy
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        _httpProxyError = null;
        _httpsProxyError = null;
        _saving = false;
      });
      showCalfSnackBar(context, 'Settings saved', kind: CalfToastKind.success);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showCalfErrorSnackBar(context, error);
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
            if (mounted) {
              showCalfSnackBar(context, 'Migration completed');
            }
          }
          return;
        }
      } catch (error) {
        if (!mounted) return;
        setState(() => _migrating = false);
        showCalfSnackBar(
          context,
          error is ApiException
              ? error.message
              : 'Could not read migration status',
        );
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

  /// Toggles whether calf manages the Docker CLI context.
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
      });
      showCalfErrorSnackBar(context, error);
    }
  }

  /// Toggles verbose daemon logging and the top-bar logs button.
  Future<void> setDebugEnabled(bool value) async {
    final current = _config;
    if (current == null) {
      return;
    }

    setState(() => _debugSaving = true);

    try {
      final updated = await widget.apiClient.updateLogLevel(
        value ? 'debug' : 'info',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _config = updated;
        _debugSaving = false;
      });
      widget.onDebugChanged?.call(updated.logLevel == 'debug');
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _debugSaving = false);
      showCalfErrorSnackBar(context, error);
    }
  }

  /// Sidebar categories matching the current search query.
  List<_SettingsNavItem> get _visibleNav {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return _navItems;
    }
    return _navItems.where((item) {
      if (item.label.toLowerCase().contains(query)) {
        return true;
      }
      return item.keywords.any((keyword) => keyword.contains(query));
    }).toList();
  }

  /// Builds the widget tree.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canApply =
        _dirty &&
        !_saving &&
        _httpProxyError == null &&
        _httpsProxyError == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Settings',
                  style: theme.textTheme.titleLarge!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 228, child: _sidebar(theme)),
              VerticalDivider(
                width: 1,
                color: theme.colorScheme.outlineVariant,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _configLoading
                          ? Center(
                              child: Text(
                                'Loading settings...',
                                style: CalfTheme.muted(theme),
                              ),
                            )
                          : SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(28, 20, 28, 28),
                              child: _pageForTab(theme),
                            ),
                    ),
                    Divider(
                      height: 1,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(28, 12, 28, 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (widget.onClose != null)
                            CalfButton.outline(
                              onPressed: widget.onClose,
                              child: const Text('Close'),
                            ),
                          const SizedBox(width: 8),
                          CalfButton(
                            onPressed: canApply ? applyConfig : null,
                            enabled: canApply,
                            child: Text(_saving ? 'Saving...' : 'Apply'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Builds the Settings category sidebar with search.
  Widget _sidebar(ThemeData theme) {
    final visible = _visibleNav;
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search settings',
                isDense: true,
                prefixIcon: Icon(
                  LucideIcons.search,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              children: [
                for (final item in visible) _navTile(theme, item),
                if (visible.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'No matching settings',
                      style: CalfTheme.muted(theme),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Filters the sidebar and jumps to the first matching category.
  void _onSearchChanged(String value) {
    setState(() {
      _searchQuery = value;
      final visible = _visibleNav;
      if (visible.isNotEmpty &&
          !visible.any((item) => item.tab == _tab)) {
        _tab = visible.first.tab;
      }
    });
  }

  /// Builds one sidebar category row.
  Widget _navTile(ThemeData theme, _SettingsNavItem item) {
    final selected = item.tab == _tab;
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        animationDuration: CalfTheme.materialAnimationDuration,
        color: selected
            ? theme.colorScheme.secondaryContainer
            : Colors.transparent,
        borderRadius: CalfTheme.radius,
        child: InkWell(
          borderRadius: CalfTheme.radius,
          onTap: () => setState(() => _tab = item.tab),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(item.icon, size: 16, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.label,
                    style: theme.textTheme.bodyMedium!.copyWith(
                      color: color,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Returns the content pane for the selected category.
  Widget _pageForTab(ThemeData theme) {
    return switch (_tab) {
      _SettingsTab.general => _generalPage(theme),
      _SettingsTab.resources => _resourcesPage(theme),
      _SettingsTab.engine => _enginePage(theme),
      _SettingsTab.builders => _buildersPage(theme),
      _SettingsTab.updates => _updatesPage(theme),
      _SettingsTab.advanced => _advancedPage(theme),
    };
  }

  /// Builds the General pane: startup, theme, CLI, completions, emulation.
  Widget _generalPage(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pageTitle(theme, 'General'),
        _option(
          title: 'Start calf when you sign in to your computer',
          description:
              'Automatically start calf when you sign in to your machine.',
          value: _launchAtLoginEnabled ?? false,
          onChanged: _launchAtLoginLoading || _launchAtLoginSaving
              ? null
              : setLaunchAtLoginEnabled,
        ),
        if (_launchAtLoginError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _launchAtLoginError!,
              style: theme.textTheme.bodyMedium!.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        _option(
          title: 'Open the dashboard when calf starts',
          description: 'Automatically open the window when starting calf.',
          value: _openWindowOnLaunch,
          onChanged: _openWindowSaving
              ? null
              : (value) async {
                  setState(() {
                    _openWindowOnLaunch = value;
                    _openWindowSaving = true;
                  });
                  await WindowPreferences.saveOpenOnLaunch(value);
                  if (mounted) {
                    setState(() => _openWindowSaving = false);
                  }
                },
        ),
        _groupLabel(theme, 'Choose theme for calf'),
        RadioGroup<ThemeMode>(
          groupValue: widget.themeMode,
          onChanged: (mode) {
            if (mode != null) {
              widget.onThemeModeChanged?.call(mode);
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _radioOption(title: 'Light', value: ThemeMode.light),
              _radioOption(title: 'Dark', value: ThemeMode.dark),
              _radioOption(
                title: 'Use system settings',
                value: ThemeMode.system,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _option(
          title: 'Use calf for Docker CLI',
          description:
              'Points the docker CLI at calf so docker and docker compose work in a terminal.',
          value: _dockerContextManaged,
          onChanged: _dockerContextSaving ? null : setDockerContextManaged,
        ),
        if (_config != null) ...[
          Padding(
            padding: const EdgeInsets.only(left: 40, bottom: 8),
            child: Text(
              _config!.dockerContextActive
                  ? 'Active context: calf'
                  : _config!.dockerContextName.isEmpty
                  ? 'Docker CLI context is not set to calf'
                  : 'Active context: ${_config!.dockerContextName}',
              style: CalfTheme.muted(theme),
            ),
          ),
          if (!_config!.dockerCliAvailable ||
              _config!.dockerPluginsHint.isNotEmpty) ...[
            if (_config!.dockerPluginsHint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 40, bottom: 8),
                child: Text(
                  _config!.dockerPluginsHint,
                  style: theme.textTheme.bodyMedium!.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 40, bottom: 16),
              child: CalfButton.outline(
                onPressed: _saving
                    ? null
                    : () async {
                        final ok = await runCalfToastAction(
                          pending: 'Installing Docker CLI...',
                          done: 'Docker CLI installed',
                          action: widget.apiClient.installDockerCli,
                        );
                        if (ok && mounted) {
                          await loadConfig();
                        }
                      },
                child: const Text('Install Docker CLI'),
              ),
            ),
          ],
          for (final warning in _config!.hijackWarnings)
            Padding(
              padding: const EdgeInsets.only(left: 40, bottom: 8),
              child: Text(warning.message, style: CalfTheme.muted(theme)),
            ),
        ],
        _option(
          title: 'Configure shell completions',
          description:
              'Edits your shell configuration so Tab completes docker commands, flags, and objects.',
          value: _config?.shellCompletions ?? false,
          onChanged: _saving
              ? null
              : (value) => _patchBool(
                  (cfg) => cfg.copyWith(shellCompletions: value),
                ),
        ),
        if (theme.platform == TargetPlatform.macOS)
          _option(
            title:
                'Use Rosetta for x86_64/amd64 emulation on Apple Silicon',
            description:
                'Accelerate x86/AMD64 binary emulation on Apple Silicon.',
            value: _config?.enableAmd64Emulation ?? false,
            onChanged: _saving
                ? null
                : (value) => _patchBool(
                    (cfg) => cfg.copyWith(enableAmd64Emulation: value),
                  ),
          )
        else
          _option(
            title: 'Enable amd64 emulation',
            description:
                'Run images built for x86_64/amd64 on this machine.',
            value: _config?.enableAmd64Emulation ?? false,
            onChanged: _saving
                ? null
                : (value) => _patchBool(
                    (cfg) => cfg.copyWith(enableAmd64Emulation: value),
                  ),
          ),
        const SizedBox(height: 12),
        _groupLabel(theme, 'Import from Docker Desktop'),
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
      ],
    );
  }

  /// Builds the Resources pane: CPU, memory, disk, shares, network, proxy.
  Widget _resourcesPage(ThemeData theme) {
    if (_config == null) {
      return Text('Loading config...', style: CalfTheme.muted(theme));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pageTitle(theme, 'Resources'),
        _sliderRow(
          'CPU limit',
          _draftCpus,
          1,
          _config!.hostCPUs.toDouble(),
          (value) => setState(() => _draftCpus = value),
          trailing: Text('${_draftCpus.toInt()} CPUs'),
        ),
        const SizedBox(height: 20),
        _sliderRow(
          'Memory limit',
          _draftMemory,
          1,
          _config!.hostMemoryGB.toDouble(),
          (value) => setState(() => _draftMemory = value),
          trailing: Text('${_draftMemory.toInt()} GB'),
        ),
        const SizedBox(height: 20),
        _sliderRow(
          'Swap',
          _draftSwap,
          0,
          _config!.hostMemoryGB.toDouble(),
          (value) => setState(() => _draftSwap = value),
          trailing: Text('${_draftSwap.toInt()} GB'),
        ),
        const SizedBox(height: 20),
        _sliderRow(
          'Disk usage limit',
          _draftDisk,
          1,
          _config!.hostDiskGB.toDouble(),
          (value) => setState(() => _draftDisk = value),
          trailing: Text('${_draftDisk.toInt()} GB'),
        ),
        const SizedBox(height: 8),
        Text(
          'Limit the amount of disk space the engine can use, including overheads. '
          'calf will allocate and free space on demand, but will not exceed this limit.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 20),
        _diskImageField(theme),
        const SizedBox(height: 8),
        CalfButton.outline(
          onPressed: _saving ? null : _copyDiskImage,
          child: const Text('Copy disk image'),
        ),
        const SizedBox(height: 8),
        Text(
          'Copies the VM disk while the engine is stopped.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 28),
        _groupLabel(theme, 'File sharing'),
        Text(
          'Share extra folders with Linux containers. Your home directory is already shared. '
          'Add paths outside home if a bind mount is denied at runtime.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _fileSharesController,
          enabled: !_saving,
          decoration: const InputDecoration(
            hintText: '/tmp, /Volumes',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Text(
          'Comma-separated paths. Apply, then restart the engine.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 28),
        _groupLabel(theme, 'Network'),
        _option(
          title: 'Enable host networking',
          description:
              'Lets containers use the host network stack. Restart the engine after changing this.',
          value: _config?.hostNetworking ?? false,
          onChanged: _saving
              ? null
              : (value) => _patchBool(
                  (cfg) => cfg.copyWith(hostNetworking: value),
                ),
        ),
        _option(
          title: 'Bind published ports to localhost',
          description:
              'Published ports listen on 127.0.0.1 instead of all interfaces.',
          value: _config?.bindLocalhostOnly ?? false,
          onChanged: _saving
              ? null
              : (value) => _patchBool(
                  (cfg) => cfg.copyWith(bindLocalhostOnly: value),
                ),
        ),
        Text('Docker subnet', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _dockerSubnetController,
          enabled: !_saving,
          decoration: const InputDecoration(hintText: '192.168.65.0/24'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 28),
        _resourceSaverSection(theme),
        const SizedBox(height: 28),
        _groupLabel(theme, 'Proxies'),
        Text(
          'HTTP and HTTPS proxy settings for image pulls inside the engine.',
          style: CalfTheme.muted(theme),
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
    );
  }

  /// Builds the Docker Engine pane: daemon.json editor.
  Widget _enginePage(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pageTitle(theme, 'Docker Engine'),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CalfColors.warning.withValues(alpha: 0.16),
            borderRadius: CalfTheme.radius,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                LucideIcons.triangleAlert,
                size: 16,
                color: CalfColors.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'This can prevent the engine from starting. Reset your daemon settings if it hangs.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Configure the Docker daemon by typing a JSON Docker daemon configuration file.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _daemonJsonController,
          enabled: !_saving,
          maxLines: 16,
          style: const TextStyle(
            fontFamily: CalfFonts.mono,
            fontSize: 13,
          ),
          decoration: InputDecoration(
            hintText: '{\n  "debug": true\n}',
            alignLabelWithHint: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Text(
          'Merged with calf defaults on the next engine start. Select Apply to save.',
          style: CalfTheme.muted(theme),
        ),
      ],
    );
  }

  /// Builds the Builders pane: selected builder and the rest.
  Widget _buildersPage(ThemeData theme) {
    final selected = _builders.where((b) => b.selected).toList();
    final available = _builders.where((b) => !b.selected).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pageTitle(theme, 'Builders'),
        _groupLabel(theme, 'Selected builder'),
        Text(
          'The default builder used when you start a build.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 12),
        if (selected.isEmpty)
          Text(
            'Start the engine to inspect builders.',
            style: CalfTheme.muted(theme),
          )
        else
          for (final builder in selected) _builderCard(theme, builder),
        const SizedBox(height: 24),
        _groupLabel(theme, 'Available builders'),
        Text(
          'Inspect and manage your builders.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 12),
        if (available.isEmpty && selected.isNotEmpty)
          Text('No other builders.', style: CalfTheme.muted(theme)),
        for (final builder in available) ...[
          _builderCard(theme, builder),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  /// Builds one builder card with use and remove actions.
  Widget _builderCard(ThemeData theme, BuilderInfo builder) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: CalfTheme.radius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  builder.name,
                  style: theme.textTheme.titleMedium!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (builder.selected)
                Text(
                  'Current',
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (builder.driver.isNotEmpty) builder.driver,
              if (builder.lastActivity.isNotEmpty) builder.lastActivity,
            ].join(' · '),
            style: CalfTheme.muted(theme),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!builder.selected)
                CalfButton.outline(
                  onPressed: _saving
                      ? null
                      : () async {
                          final ok = await runCalfToastAction(
                            pending: 'Using ${builder.name}...',
                            done: 'Using ${builder.name}',
                            action: () =>
                                widget.apiClient.useBuilder(builder.name),
                          );
                          if (ok && mounted) {
                            await _loadBuilders();
                          }
                        },
                  child: const Text('Use'),
                ),
              if (!builder.selected) const SizedBox(width: 8),
              CalfButton.outline(
                onPressed: _saving
                    ? null
                    : () async {
                        final ok = await runCalfToastAction(
                          pending: 'Removing ${builder.name}...',
                          done: 'Removed ${builder.name}',
                          action: () =>
                              widget.apiClient.removeBuilder(builder.name),
                        );
                        if (ok && mounted) {
                          await _loadBuilders();
                        }
                      },
                child: const Text('Remove'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Builds the Software updates pane.
  Widget _updatesPage(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pageTitle(theme, 'Software updates'),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.7),
            borderRadius: CalfTheme.radius,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                LucideIcons.info,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'To check for updates, select Check for updates.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _groupLabel(theme, 'Software updates preferences'),
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
              _updateCheckResult!.latest != null)
            Text(
              'Version ${_updateCheckResult!.latest!.version} is available.',
              style: theme.textTheme.titleMedium,
            )
          else
            Text('You are up to date.', style: CalfTheme.muted(theme)),
        ],
      ],
    );
  }

  /// Builds the Advanced pane: default socket, privileged ports, debug.
  Widget _advancedPage(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pageTitle(theme, 'Advanced'),
        Text(
          'These settings are intended for environments with extra security or compatibility needs. Changing them can limit how some tools talk to calf.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 20),
        _option(
          title: 'Allow the default Docker socket to be used (requires password)',
          description:
              'Creates /var/run/docker.sock which some third-party clients may use to communicate with calf.',
          value: _config?.defaultDockerSocket ?? false,
          onChanged: _saving
              ? null
              : (value) => _patchBool(
                  (cfg) => cfg.copyWith(defaultDockerSocket: value),
                ),
        ),
        if ((_config?.defaultSocketHint ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 40, bottom: 12),
            child: Text(
              _config!.defaultSocketHint,
              style: CalfTheme.muted(theme),
            ),
          ),
        _option(
          title: 'Allow privileged port mapping (requires password)',
          description:
              'Starts the privileged helper which binds published ports between 1 and 1024.',
          value: _config?.privilegedPorts ?? false,
          onChanged: _saving
              ? null
              : (value) => _patchBool(
                  (cfg) => cfg.copyWith(privilegedPorts: value),
                ),
        ),
        _option(
          title: 'Debug',
          description:
              'Shows a bug button in the top bar so you can copy daemon logs when something goes wrong.',
          value: _config?.logLevel == 'debug',
          onChanged: _config == null || _debugSaving ? null : setDebugEnabled,
        ),
      ],
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
        _groupLabel(theme, 'Resource Saver'),
        _option(
          title: 'Enable Resource Saver',
          description:
              'Reduces CPU and memory utilization when no containers are running. '
              'Exit from Resource Saver mode happens automatically when containers are started.',
          value: _draftResourceSaverEnabled,
          onChanged: (value) =>
              setState(() => _draftResourceSaverEnabled = value),
        ),
        Text(
          'Use the slider to set the duration of time between no containers '
          'running and calf entering Resource Saver mode.',
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
                  max: (CalfResourceSaver.timeoutSeconds.length - 1)
                      .toDouble(),
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

  /// Builds a large pane heading.
  Widget _pageTitle(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Text(
        title,
        style: theme.textTheme.headlineSmall!.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// Builds a bold group heading inside a pane.
  Widget _groupLabel(ThemeData theme, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        label,
        style: theme.textTheme.titleMedium!.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// Builds a checkbox option with a title and muted description.
  Widget _option({
    required String title,
    required String description,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Checkbox(
              value: value,
              visualDensity: VisualDensity.compact,
              onChanged: onChanged == null
                  ? null
                  : (checked) => onChanged(checked ?? false),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: InkWell(
              onTap: onChanged == null ? null : () => onChanged(!value),
              child: Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 2),
                    Text(description, style: CalfTheme.muted(theme)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds a theme radio row. Must sit under a [RadioGroup].
  Widget _radioOption({
    required String title,
    required ThemeMode value,
  }) {
    final theme = Theme.of(context);
    final enabled = widget.onThemeModeChanged != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Radio<ThemeMode>(
            value: value,
            enabled: enabled,
            visualDensity: VisualDensity.compact,
          ),
          InkWell(
            onTap: enabled ? () => widget.onThemeModeChanged!(value) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(title, style: theme.textTheme.bodyLarge),
            ),
          ),
        ],
      ),
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
      showCalfSnackBar(context, message);
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
