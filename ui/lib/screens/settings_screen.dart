import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
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
import 'package:ui/widgets/calf_tab_bar.dart';
import 'package:ui/widgets/volume_export_form.dart';

/// Option titles in [entries] that contain [query] (case-insensitive).
List<String> matchingSettingTitles(List<String> entries, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) {
    return const [];
  }
  return [
    for (final title in entries)
      if (title.toLowerCase().contains(q)) title,
  ];
}

/// Text spans that bold the first case-insensitive match of [query] in [text].
List<InlineSpan> highlightSearchQuery(String text, String query) {
  final q = query.trim();
  if (q.isEmpty) {
    return [TextSpan(text: text)];
  }
  final index = text.toLowerCase().indexOf(q.toLowerCase());
  if (index < 0) {
    return [TextSpan(text: text)];
  }
  final end = index + q.length;
  return [
    if (index > 0) TextSpan(text: text.substring(0, index)),
    TextSpan(
      text: text.substring(index, end),
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
    if (end < text.length) TextSpan(text: text.substring(end)),
  ];
}

/// Last path component used as the file-share row label.
String fileShareLabel(String path) {
  final name = p.basename(normalizeFileSharePath(path));
  return name.isEmpty ? path.trim() : name;
}

/// Whether [path] is an absolute host path suitable as an extra file share.
bool isValidFileSharePath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  return p.isAbsolute(trimmed);
}

/// Trims and normalizes a file-share path for storage and comparison.
String normalizeFileSharePath(String path) {
  return p.normalize(path.trim());
}

/// Whether HTTP, HTTPS, and no-proxy are all unset.
bool proxyConfigIsEmpty(String httpProxy, String httpsProxy, String noProxy) {
  return httpProxy.trim().isEmpty &&
      httpsProxy.trim().isEmpty &&
      noProxy.trim().isEmpty;
}

/// Default bridge CIDR when docker_subnet is unset in config.
const defaultDockerSubnet = '172.17.0.0/16';

/// Returns the Docker subnet value shown in Settings.
String displayDockerSubnet(String saved) {
  final trimmed = saved.trim();
  return trimmed.isEmpty ? defaultDockerSubnet : trimmed;
}

/// Normalizes the Docker subnet draft for save and dirty checks.
String normalizeDockerSubnetForSave(String draft) {
  final trimmed = draft.trim();
  if (trimmed.isEmpty || trimmed == defaultDockerSubnet) {
    return '';
  }
  return trimmed;
}

/// dockerd CLI reference for daemon.json options.
const dockerdReferenceUrl = 'https://docs.docker.com/reference/cli/dockerd/';

/// Default daemon.json overlay shown in Settings (matches Docker Desktop).
const defaultDaemonJsonOverlay =
    '{\n'
    '  "builder": {\n'
    '    "gc": {\n'
    '      "defaultKeepStorage": "20GB",\n'
    '      "enabled": true\n'
    '    }\n'
    '  },\n'
    '  "experimental": false\n'
    '}';

/// Returns the daemon.json overlay shown in Settings.
String displayDaemonJson(String saved) {
  final trimmed = saved.trim();
  return trimmed.isEmpty ? defaultDaemonJsonOverlay : trimmed;
}

/// Whether two daemon.json strings decode to the same JSON value.
bool daemonJsonEquivalent(String left, String right) {
  try {
    final decodedLeft = jsonDecode(left.trim());
    final decodedRight = jsonDecode(right.trim());
    return jsonEncode(decodedLeft) == jsonEncode(decodedRight);
  } on FormatException {
    return false;
  }
}

/// Normalizes the daemon.json draft for save and dirty checks.
String normalizeDaemonJsonForSave(String draft) {
  final trimmed = draft.trim();
  if (trimmed.isEmpty ||
      daemonJsonEquivalent(trimmed, defaultDaemonJsonOverlay)) {
    return '';
  }
  return trimmed;
}

/// Resources sub-pane matching Docker Desktop's Advanced / File sharing / Proxies / Network tabs.
enum ResourcesPane { advanced, fileSharing, proxies, network }

/// Proxy UI mode: hide fields, or edit HTTP/HTTPS/no-proxy manually.
enum _ProxyMode { none, manual }

/// Resources sub-pane for a Settings option title.
ResourcesPane resourcesPaneForSetting(String title) {
  switch (title) {
    case 'File sharing':
      return ResourcesPane.fileSharing;
    case 'Proxies':
    case 'calf proxy':
    case 'Containers proxy':
    case 'Engine proxy':
    case 'Proxy mode':
    case 'No proxy':
    case 'Manual configuration':
    case 'System proxy':
    case 'HTTP proxy':
    case 'HTTPS proxy':
    case 'Bypass proxy settings':
      return ResourcesPane.proxies;
    case 'Network':
    case 'Enable host networking':
    case 'Bind published ports to localhost':
    case 'Docker subnet':
    case 'Port binding behavior':
      return ResourcesPane.network;
    default:
      return ResourcesPane.advanced;
  }
}

/// Settings categories matching Docker Desktop's sidebar.
enum _SettingsTab { general, resources, engine, builders, updates, advanced }

/// One sidebar row in Settings.
class _SettingsNavItem {
  /// Creates a [_SettingsNavItem].
  const _SettingsNavItem({
    required this.tab,
    required this.label,
    required this.icon,
    required this.keywords,
    required this.entries,
  });

  final _SettingsTab tab;
  final String label;
  final IconData icon;
  final List<String> keywords;
  final List<String> entries;
}

/// A Settings category plus nested option titles that matched search.
class _SettingsSearchGroup {
  /// Creates a [_SettingsSearchGroup].
  const _SettingsSearchGroup({required this.item, this.hits = const []});

  final _SettingsNavItem item;
  final List<String> hits;
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
  final _noProxyController = TextEditingController();
  final _daemonJsonController = TextEditingController();
  final _fileShareInputController = TextEditingController();
  final _dockerSubnetController = TextEditingController();
  List<String> _fileShares = [];
  List<BuilderInfo> _builders = [];
  String? _httpProxyError;
  String? _httpsProxyError;
  _ProxyMode _proxyMode = _ProxyMode.none;
  ResourcesPane _resourcesPane = ResourcesPane.advanced;
  bool _migrating = false;
  MigrationStatus? _migrationStatus;
  bool _dockerContextManaged = true;
  bool _draftShellCompletions = false;
  bool _draftEnableAmd64Emulation = false;
  bool _draftHostNetworking = false;
  bool _draftBindLocalhostOnly = false;
  bool _draftDefaultDockerSocket = false;
  bool _draftPrivilegedPorts = false;
  bool _draftDebug = false;
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
      entries: [
        'Start calf when you sign in to your computer',
        'Open the dashboard when calf starts',
        'Choose theme for calf',
        'Light',
        'Dark',
        'Use system settings',
        'Use calf for Docker CLI',
        'Configure shell completions',
        'Use Rosetta for x86_64/amd64 emulation on Apple Silicon',
        'Enable amd64 emulation',
        'Import from Docker Desktop',
        'Migrate from Docker Desktop',
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
      entries: [
        'CPU limit',
        'Memory limit',
        'Swap',
        'Disk usage limit',
        'Disk image location',
        'File sharing',
        'Network',
        'Enable host networking',
        'Bind published ports to localhost',
        'Docker subnet',
        'Port binding behavior',
        'Resource Saver',
        'Enable Resource Saver',
        'Proxies',
        'calf proxy',
        'Containers proxy',
        'System proxy',
        'Proxy mode',
        'No proxy',
        'Manual configuration',
        'HTTP proxy',
        'HTTPS proxy',
        'Bypass proxy settings',
      ],
    ),
    _SettingsNavItem(
      tab: _SettingsTab.engine,
      label: 'Docker Engine',
      icon: LucideIcons.container,
      keywords: ['daemon', 'json', 'engine', 'dockerd', 'registry', 'mirror'],
      entries: [
        'Docker daemon configuration',
        'registry-mirrors',
        'insecure-registries',
        'dockerd command reference',
      ],
    ),
    _SettingsNavItem(
      tab: _SettingsTab.builders,
      label: 'Builders',
      icon: LucideIcons.hammer,
      keywords: ['buildx', 'builder', 'build'],
      entries: ['Selected builder', 'Available builders'],
    ),
    _SettingsNavItem(
      tab: _SettingsTab.updates,
      label: 'Software updates',
      icon: LucideIcons.download,
      keywords: ['update', 'version', 'release'],
      entries: ['Software updates preferences', 'Check for updates'],
    ),
    _SettingsNavItem(
      tab: _SettingsTab.advanced,
      label: 'Advanced',
      icon: LucideIcons.shield,
      keywords: ['socket', 'privileged', 'ports', 'debug', 'password'],
      entries: [
        'Allow the default Docker socket to be used (requires password)',
        'Allow privileged port mapping (requires password)',
        'Debug',
      ],
    ),
  ];

  /// Whether proxy fields differ from the saved config.
  bool get _proxyDirty {
    final config = _config;
    if (config == null) {
      return false;
    }
    final savedEmpty = proxyConfigIsEmpty(
      config.httpProxy,
      config.httpsProxy,
      config.noProxy,
    );
    if (_proxyMode == _ProxyMode.none) {
      return !savedEmpty;
    }
    return _httpProxyController.text.trim() != config.httpProxy ||
        _httpsProxyController.text.trim() != config.httpsProxy ||
        _noProxyController.text.trim() != config.noProxy;
  }

  /// Whether any settings differ from the saved config.
  bool get _dirty =>
      _config != null &&
      (_draftCpus.toInt() != _config!.cpus ||
          _draftMemory.toInt() != _config!.memoryGB ||
          _draftSwap.toInt() != _config!.memorySwapGB ||
          _draftDisk.toInt() != _config!.diskGB ||
          _diskImageController.text.trim() != _config!.diskImage ||
          _proxyDirty ||
          _draftResourceSaverEnabled != _config!.resourceSaverEnabled ||
          _draftResourceSaverTimeoutSec != _config!.resourceSaverTimeoutSec ||
          _dockerContextManaged != _config!.dockerContextManaged ||
          _draftShellCompletions != _config!.shellCompletions ||
          _draftEnableAmd64Emulation != _config!.enableAmd64Emulation ||
          _draftHostNetworking != _config!.hostNetworking ||
          _draftBindLocalhostOnly != _config!.bindLocalhostOnly ||
          _draftDefaultDockerSocket != _config!.defaultDockerSocket ||
          _draftPrivilegedPorts != _config!.privilegedPorts ||
          _draftDebug != (_config!.logLevel == 'debug') ||
          normalizeDaemonJsonForSave(_daemonJsonController.text) !=
              _config!.daemonJSON.trim() ||
          !listEquals(_fileShares, _config!.fileShares) ||
          normalizeDockerSubnetForSave(_dockerSubnetController.text) !=
              _config!.dockerSubnet.trim());

  /// Releases resources when the widget is removed.
  @override
  void dispose() {
    _diskImageController.dispose();
    _httpProxyController.dispose();
    _httpsProxyController.dispose();
    _noProxyController.dispose();
    _daemonJsonController.dispose();
    _fileShareInputController.dispose();
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
        _dockerContextManaged = config.dockerContextManaged;
        _draftShellCompletions = config.shellCompletions;
        _draftEnableAmd64Emulation = config.enableAmd64Emulation;
        _draftHostNetworking = config.hostNetworking;
        _draftBindLocalhostOnly = config.bindLocalhostOnly;
        _draftDefaultDockerSocket = config.defaultDockerSocket;
        _draftPrivilegedPorts = config.privilegedPorts;
        _draftDebug = config.logLevel == 'debug';
        _diskImageController.text = config.diskImage;
        _httpProxyController.text = config.httpProxy;
        _httpsProxyController.text = config.httpsProxy;
        _proxyMode =
            proxyConfigIsEmpty(
              config.httpProxy,
              config.httpsProxy,
              config.noProxy,
            )
            ? _ProxyMode.none
            : _ProxyMode.manual;
        _daemonJsonController.text = displayDaemonJson(config.daemonJSON);
        _fileShares = List<String>.from(config.fileShares);
        _fileShareInputController.clear();
        _dockerSubnetController.text = displayDockerSubnet(config.dockerSubnet);
        _noProxyController.text = config.noProxy;
        _httpProxyError = null;
        _httpsProxyError = null;
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

  /// Saves changed settings to the daemon.
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
          httpProxy: _proxyMode == _ProxyMode.none
              ? ''
              : _httpProxyController.text.trim(),
          httpsProxy: _proxyMode == _ProxyMode.none
              ? ''
              : _httpsProxyController.text.trim(),
          noProxy: _proxyMode == _ProxyMode.none
              ? ''
              : _noProxyController.text.trim(),
          resourceSaverEnabled: _draftResourceSaverEnabled,
          resourceSaverTimeoutSec: _draftResourceSaverTimeoutSec,
          daemonJSON: normalizeDaemonJsonForSave(_daemonJsonController.text),
          dockerSubnet: normalizeDockerSubnetForSave(
            _dockerSubnetController.text,
          ),
          fileShares: List<String>.from(_fileShares),
          dockerContextManaged: _dockerContextManaged,
          shellCompletions: _draftShellCompletions,
          enableAmd64Emulation: _draftEnableAmd64Emulation,
          hostNetworking: _draftHostNetworking,
          bindLocalhostOnly: _draftBindLocalhostOnly,
          defaultDockerSocket: _draftDefaultDockerSocket,
          privilegedPorts: _draftPrivilegedPorts,
          logLevel: _draftDebug ? 'debug' : 'info',
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
        _dockerContextManaged = updated.dockerContextManaged;
        _draftShellCompletions = updated.shellCompletions;
        _draftEnableAmd64Emulation = updated.enableAmd64Emulation;
        _draftHostNetworking = updated.hostNetworking;
        _draftBindLocalhostOnly = updated.bindLocalhostOnly;
        _draftDefaultDockerSocket = updated.defaultDockerSocket;
        _draftPrivilegedPorts = updated.privilegedPorts;
        _draftDebug = updated.logLevel == 'debug';
        _diskImageController.text = updated.diskImage;
        _httpProxyController.text = updated.httpProxy;
        _httpsProxyController.text = updated.httpsProxy;
        _proxyMode =
            proxyConfigIsEmpty(
              updated.httpProxy,
              updated.httpsProxy,
              updated.noProxy,
            )
            ? _ProxyMode.none
            : _ProxyMode.manual;
        _daemonJsonController.text = displayDaemonJson(updated.daemonJSON);
        _fileShares = List<String>.from(updated.fileShares);
        _fileShareInputController.clear();
        _dockerSubnetController.text = displayDockerSubnet(
          updated.dockerSubnet,
        );
        _noProxyController.text = updated.noProxy;
        _httpProxyError = null;
        _httpsProxyError = null;
        _saving = false;
      });
      widget.onDebugChanged?.call(updated.logLevel == 'debug');
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

  /// Sidebar categories matching the current search query, with nested option hits.
  List<_SettingsSearchGroup> get _visibleGroups {
    final query = _searchQuery.trim();
    if (query.isEmpty) {
      return [for (final item in _navItems) _SettingsSearchGroup(item: item)];
    }
    final q = query.toLowerCase();
    final groups = <_SettingsSearchGroup>[];
    for (final item in _navItems) {
      final hits = matchingSettingTitles(item.entries, query);
      final categoryMatch =
          item.label.toLowerCase().contains(q) ||
          item.keywords.any((keyword) => keyword.contains(q));
      if (hits.isNotEmpty || categoryMatch) {
        groups.add(_SettingsSearchGroup(item: item, hits: hits));
      }
    }
    return groups;
  }

  /// Builds the widget tree.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canApply =
        _dirty &&
        !_saving &&
        (_proxyMode == _ProxyMode.none ||
            (_httpProxyError == null && _httpsProxyError == null));

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
                              padding: const EdgeInsets.fromLTRB(
                                28,
                                20,
                                28,
                                28,
                              ),
                              child: _pageForTab(theme),
                            ),
                    ),
                    Divider(height: 1, color: theme.colorScheme.outlineVariant),
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
    final groups = _visibleGroups;
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
                for (final group in groups) ...[
                  _navTile(theme, group.item, tight: group.hits.isNotEmpty),
                  for (final hit in group.hits)
                    _searchHitTile(theme, group.item, hit),
                ],
                if (groups.isEmpty)
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
      final visible = _visibleGroups;
      if (visible.isEmpty) {
        return;
      }
      if (!visible.any((group) => group.item.tab == _tab)) {
        _tab = visible.first.item.tab;
      }
      final selected = visible.firstWhere((group) => group.item.tab == _tab);
      if (selected.item.tab == _SettingsTab.resources &&
          selected.hits.isNotEmpty) {
        _resourcesPane = resourcesPaneForSetting(selected.hits.first);
      }
    });
  }

  /// Builds one sidebar category row.
  Widget _navTile(
    ThemeData theme,
    _SettingsNavItem item, {
    bool tight = false,
  }) {
    final selected = item.tab == _tab;
    final searching = _searchQuery.trim().isNotEmpty;
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;
    return Padding(
      padding: EdgeInsets.only(bottom: tight ? 2 : 8),
      child: Material(
        animationDuration: CalfTheme.materialAnimationDuration,
        color: selected
            ? theme.colorScheme.secondaryContainer
            : Colors.transparent,
        borderRadius: CalfTheme.radius,
        child: InkWell(
          borderRadius: CalfTheme.radius,
          onTap: () => _openSetting(item),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(item.icon, size: 16, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: theme.textTheme.bodyMedium!.copyWith(
                        color: color,
                        fontWeight: selected || searching
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                      children: highlightSearchQuery(item.label, _searchQuery),
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

  /// Builds one nested option hit under a Settings category.
  Widget _searchHitTile(ThemeData theme, _SettingsNavItem item, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 0, 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: CalfTheme.radius,
          onTap: () => _openSetting(item, title),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Text.rich(
              TextSpan(
                style: theme.textTheme.bodyMedium!.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
                children: highlightSearchQuery(title, _searchQuery),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Opens a Settings category, and a Resources sub-pane when [title] is set.
  void _openSetting(_SettingsNavItem item, [String? title]) {
    setState(() {
      _tab = item.tab;
      if (item.tab == _SettingsTab.resources && title != null) {
        _resourcesPane = resourcesPaneForSetting(title);
      }
    });
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
              'Uses calf for docker and docker compose in the terminal and in apps. Your password may be required once.',
          value: _dockerContextManaged,
          onChanged: (value) => setState(() => _dockerContextManaged = value),
        ),
        if (_config != null) ...[
          if (!_config!.dockerContextActive)
            Padding(
              padding: const EdgeInsets.only(left: 40, bottom: 8),
              child: Text(
                _config!.dockerContextName.isEmpty
                    ? 'docker is not using calf yet'
                    : 'docker is using ${_config!.dockerContextName}',
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
        ],
        _option(
          title: 'Configure shell completions',
          description:
              'Edits your shell configuration so Tab completes docker commands, flags, and objects.',
          value: _draftShellCompletions,
          onChanged: (value) => setState(() => _draftShellCompletions = value),
        ),
        if (theme.platform == TargetPlatform.macOS)
          _option(
            title: 'Use Rosetta for x86_64/amd64 emulation on Apple Silicon',
            description:
                'Accelerate x86/AMD64 binary emulation on Apple Silicon.',
            value: _draftEnableAmd64Emulation,
            onChanged: (value) =>
                setState(() => _draftEnableAmd64Emulation = value),
          )
        else
          _option(
            title: 'Enable amd64 emulation',
            description: 'Run images built for x86_64/amd64 on this machine.',
            value: _draftEnableAmd64Emulation,
            onChanged: (value) =>
                setState(() => _draftEnableAmd64Emulation = value),
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

  /// Builds the Resources pane with Advanced / File sharing / Proxies / Network tabs.
  Widget _resourcesPage(ThemeData theme) {
    if (_config == null) {
      return Text('Loading config...', style: CalfTheme.muted(theme));
    }
    const panes = ResourcesPane.values;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pageTitle(theme, 'Resources', bottom: 12),
        CalfTabBar(
          theme: theme,
          labels: const ['Advanced', 'File sharing', 'Proxies', 'Network'],
          selectedIndex: panes.indexOf(_resourcesPane),
          onSelected: (index) => setState(() => _resourcesPane = panes[index]),
        ),
        const SizedBox(height: 20),
        switch (_resourcesPane) {
          ResourcesPane.advanced => _resourcesAdvancedPage(theme),
          ResourcesPane.fileSharing => _fileSharingSection(theme),
          ResourcesPane.proxies => _resourcesProxiesPage(theme),
          ResourcesPane.network => _resourcesNetworkPage(theme),
        },
      ],
    );
  }

  /// Builds CPU, memory, disk, and Resource Saver controls.
  Widget _resourcesAdvancedPage(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
        const SizedBox(height: 28),
        _resourceSaverSection(theme),
      ],
    );
  }

  /// Builds calf and container proxy sections.
  Widget _resourcesProxiesPage(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _groupLabel(theme, 'calf proxy'),
        Text(
          'Used for calf host-level traffic: signing in to Docker Hub, software updates, and the calf application.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 16),
        Text(
          'Proxy mode',
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text('System proxy', style: theme.textTheme.bodyLarge),
        const SizedBox(height: 2),
        Text(
          'Use the proxy configured on the host. calf reads this automatically.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 28),
        _groupLabel(theme, 'Containers proxy'),
        Text(
          'Used for docker image pull and outbound traffic from running containers.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 16),
        Text(
          'Proxy mode',
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        RadioGroup<_ProxyMode>(
          groupValue: _proxyMode,
          onChanged: (mode) {
            if (_saving || mode == null) {
              return;
            }
            setState(() => _proxyMode = mode);
          },
          child: Wrap(
            spacing: 24,
            runSpacing: 4,
            children: [
              _proxyModeOption('No proxy', _ProxyMode.none),
              _proxyModeOption('Manual configuration', _ProxyMode.manual),
            ],
          ),
        ),
        if (_proxyMode == _ProxyMode.manual) ...[
          const SizedBox(height: 16),
          _proxyField(
            controller: _httpProxyController,
            placeholder: 'Web Server (HTTP)',
            theme: theme,
            error: _httpProxyError,
            onChanged: _validateHttpProxy,
          ),
          const SizedBox(height: 12),
          _proxyField(
            controller: _httpsProxyController,
            placeholder: 'Secure Web Server (HTTPS)',
            theme: theme,
            error: _httpsProxyError,
            onChanged: _validateHttpsProxy,
          ),
          const SizedBox(height: 12),
          _proxyField(
            controller: _noProxyController,
            placeholder: 'Bypass proxy settings for these hosts & domains',
            theme: theme,
            helper: 'Example: registry-1.docker.com,*.docker.com,10.0.0.0/8',
            onChanged: (_) {},
          ),
        ],
      ],
    );
  }

  /// Builds one proxy-mode radio plus label.
  Widget _proxyModeOption(String title, _ProxyMode value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Radio<_ProxyMode>(
          value: value,
          enabled: !_saving,
          visualDensity: VisualDensity.compact,
        ),
        InkWell(
          onTap: _saving ? null : () => setState(() => _proxyMode = value),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(title, style: Theme.of(context).textTheme.bodyLarge),
          ),
        ),
      ],
    );
  }

  /// Builds Docker subnet, host networking, and port binding.
  Widget _resourcesNetworkPage(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Configure the way Docker containers interact with the network.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: TextField(
              controller: _dockerSubnetController,
              enabled: !_saving,
              decoration: const InputDecoration(
                labelText: 'Docker subnet',
                floatingLabelBehavior: FloatingLabelBehavior.always,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text('default: $defaultDockerSubnet', style: CalfTheme.muted(theme)),
        const SizedBox(height: 20),
        _option(
          title: 'Enable host networking',
          description:
              'Host networking allows containers that are started with --net=host use localhost to connect to TCP and UDP services on the host. '
              'It automatically allows software on the host to use localhost to connect to TCP and UDP services in the container.',
          value: _draftHostNetworking,
          onChanged: (value) => setState(() => _draftHostNetworking = value),
        ),
        const SizedBox(height: 8),
        Text('Port binding behavior', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: InputDecorator(
              decoration: const InputDecoration(),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<bool>(
                  value: _draftBindLocalhostOnly,
                  isExpanded: true,
                  isDense: true,
                  items: const [
                    DropdownMenuItem(
                      value: false,
                      child: Text('Open (Default)'),
                    ),
                    DropdownMenuItem(
                      value: true,
                      child: Text('Localhost only'),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) {
                          if (value != null) {
                            setState(() => _draftBindLocalhostOnly = value);
                          }
                        },
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Controls how ports are bound to containers, either making them available on the local network (default) or only on localhost.',
          style: CalfTheme.muted(theme),
        ),
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
          'Configure the Docker daemon using a JSON configuration file.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 8),
        Text(
          'Proxy settings and the Docker subnet are configured under Resources and merged separately. '
          'calf also enables BuildKit and default DNS on engine start.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 8),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'For the full list of daemon.json options, see the ',
              style: CalfTheme.muted(theme),
            ),
            InkWell(
              onTap: () => openExternalUrl(dockerdReferenceUrl),
              child: Text(
                'dockerd command reference',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            Text('.', style: CalfTheme.muted(theme)),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _daemonJsonController,
          enabled: !_saving,
          maxLines: 16,
          style: const TextStyle(fontFamily: CalfFonts.mono, fontSize: 13),
          decoration: const InputDecoration(
            alignLabelWithHint: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Text(
          'Invalid JSON prevents the engine from starting. Select Apply, then restart the engine.',
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
                child: Text('To check for updates, select Check for updates.'),
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
                child: Text('Download ${_updateCheckResult!.latest!.version}'),
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
          title:
              'Allow the default Docker socket to be used (requires password)',
          description:
              'Lets editors and other apps talk to calf. Your password may be required once.',
          value: _draftDefaultDockerSocket,
          onChanged: (value) =>
              setState(() => _draftDefaultDockerSocket = value),
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
          value: _draftPrivilegedPorts,
          onChanged: (value) => setState(() => _draftPrivilegedPorts = value),
        ),
        _option(
          title: 'Debug',
          description:
              'Shows a bug button in the top bar so you can copy or clear daemon logs when something goes wrong.',
          value: _draftDebug,
          onChanged: (value) => setState(() => _draftDebug = value),
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

  /// Builds a large pane heading.
  Widget _pageTitle(ThemeData theme, String title, {double bottom = 20}) {
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
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
  Widget _radioOption({required String title, required ThemeMode value}) {
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

  /// Builds the extra file-share list with per-path rows and an add field.
  Widget _fileSharingSection(ThemeData theme) {
    final draft = _fileShareInputController.text.trim();
    final normalizedDraft = draft.isEmpty ? '' : normalizeFileSharePath(draft);
    final draftValid = isValidFileSharePath(normalizedDraft);
    final canAdd =
        !_saving && draftValid && !_fileShares.contains(normalizedDraft);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'These locations will be made available to containers. '
          'Apply, then restart the engine.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 12),
        for (final path in _fileShares)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _fileShareRow(
              theme: theme,
              path: path,
              onRemove: _saving ? null : () => _removeFileShare(path),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _fileShareInputController,
                enabled: !_saving,
                decoration: InputDecoration(
                  hintText: '/path/to/exported/directory',
                  suffixIconConstraints: const BoxConstraints(
                    minHeight: 0,
                    minWidth: 0,
                  ),
                  suffixIcon: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: _saving ? null : _browseFileShareDirectory,
                      child: const Text('Browse'),
                    ),
                  ),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: _addFileShare,
              ),
            ),
            const SizedBox(width: 4),
            _fileShareIconButton(
              theme: theme,
              icon: LucideIcons.plus,
              tooltip: 'Add file share',
              onPressed: canAdd ? () => _addFileShare(draft) : null,
            ),
          ],
        ),
        if (draft.isNotEmpty && !draftValid)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Must be an absolute path',
              style: CalfTheme.muted(theme).copyWith(fontSize: 12),
            ),
          ),
      ],
    );
  }

  /// Builds one existing file-share path with a remove control.
  Widget _fileShareRow({
    required ThemeData theme,
    required String path,
    required VoidCallback? onRemove,
  }) {
    return Row(
      children: [
        Expanded(
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: fileShareLabel(path),
              floatingLabelBehavior: FloatingLabelBehavior.always,
            ),
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
        const SizedBox(width: 4),
        _fileShareIconButton(
          theme: theme,
          icon: LucideIcons.minus,
          tooltip: 'Remove $path',
          onPressed: onRemove,
        ),
      ],
    );
  }

  /// Builds the plus/minus control next to a file-share field.
  Widget _fileShareIconButton({
    required ThemeData theme,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      icon: Icon(
        icon,
        size: 18,
        color: onPressed == null
            ? theme.colorScheme.outline
            : theme.colorScheme.primary,
      ),
    );
  }

  /// Adds a validated extra file-share path to the draft list.
  void _addFileShare(String rawValue) {
    final path = normalizeFileSharePath(rawValue);
    if (!isValidFileSharePath(path) || _fileShares.contains(path)) {
      return;
    }
    setState(() {
      _fileShares.add(path);
      _fileShareInputController.clear();
    });
  }

  /// Removes [path] from the draft file-share list.
  void _removeFileShare(String path) {
    setState(() => _fileShares.remove(path));
  }

  /// Opens a folder picker and adds the chosen directory as a file share.
  Future<void> _browseFileShareDirectory() async {
    try {
      final directory = await getDirectoryPath(confirmButtonText: 'Select');
      if (directory == null || !mounted) {
        return;
      }
      setState(() => _fileShareInputController.text = directory);
      _addFileShare(directory);
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

  /// Builds a proxy URL or bypass input field.
  Widget _proxyField({
    required TextEditingController controller,
    required String placeholder,
    required ThemeData theme,
    String? error,
    String? helper,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          enabled: !_saving,
          decoration: InputDecoration(hintText: placeholder),
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
          )
        else if (helper != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              helper,
              style: CalfTheme.muted(theme).copyWith(fontSize: 12),
            ),
          ),
      ],
    );
  }
}
