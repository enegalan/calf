import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/screens/containers_screen.dart';
import 'package:ui/screens/networks_screen.dart';
import 'package:ui/screens/resources_screen.dart';
import 'package:ui/widgets/app_top_bar.dart';
import 'package:ui/widgets/calf_button.dart';

class AppShell extends StatefulWidget {
  AppShell({
    super.key,
    CalfClient? apiClient,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
  }) : apiClient = apiClient ?? ApiClient();

  final CalfClient apiClient;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  bool _showSettings = false;
  RegistryLoginStatus? _registryStatus;
  bool _registryLoading = true;
  bool _registryBrowserLoginPending = false;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    loadRegistryStatus();
    loadAppVersion();
  }

  Future<void> loadAppVersion() async {
    try {
      final status = await widget.apiClient.fetchStatus();
      if (!mounted) return;
      setState(() => _appVersion = status.version);
    } catch (_) {}
  }

  Future<void> loadRegistryStatus() async {
    setState(() => _registryLoading = true);

    try {
      final status = await widget.apiClient.fetchRegistryStatus();
      if (!mounted) return;
      setState(() {
        _registryStatus = status;
        _registryLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _registryLoading = false);
    }
  }

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
          await loadRegistryStatus();
        },
        onFailed: (_) {
          if (!mounted) return;
          setState(() => _registryBrowserLoginPending = false);
        },
      );

      if (!mounted) return;
      setState(() => _registryBrowserLoginPending = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _registryBrowserLoginPending = false);
    }
  }

  Future<void> logoutRegistry() async {
    try {
      await widget.apiClient.logoutRegistry();
      if (!mounted) return;
      await loadRegistryStatus();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    const navItems = [
      (label: 'Containers', icon: LucideIcons.box),
      (label: 'Images', icon: LucideIcons.layers),
      (label: 'Volumes', icon: LucideIcons.hardDrive),
      (label: 'Networks', icon: LucideIcons.network),
      (label: 'Builds', icon: LucideIcons.wrench),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppTopBar(
          registryStatus: _registryStatus,
          registryLoading: _registryLoading,
          signInPending: _registryBrowserLoginPending,
          onOpenSettings: () => setState(() => _showSettings = true),
          onSignIn: startRegistryBrowserLogin,
          onSignOut: logoutRegistry,
          onOpenWhatsNew: () => showWhatsNewDialog(context, _appVersion),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 220,
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(color: theme.colorScheme.border),
                  ),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var index = 0; index < navItems.length; index++) ...[
                      if (index > 0) const SizedBox(height: 8),
                      _NavItem(
                        label: navItems[index].label,
                        icon: navItems[index].icon,
                        selected: !_showSettings && _selectedIndex == index,
                        onTap: () => setState(() {
                          _selectedIndex = index;
                          _showSettings = false;
                        }),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: _showSettings
                      ? SettingsScreen(
                          apiClient: widget.apiClient,
                          themeMode: widget.themeMode,
                          onThemeModeChanged: widget.onThemeModeChanged,
                        )
                      : switch (_selectedIndex) {
                          0 => ContainersScreen(apiClient: widget.apiClient),
                          1 => ImagesScreen(apiClient: widget.apiClient),
                          2 => VolumesScreen(apiClient: widget.apiClient),
                          3 => NetworksScreen(apiClient: widget.apiClient),
                          _ => BuildsScreen(apiClient: widget.apiClient),
                        },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final color = selected ? theme.colorScheme.accentForeground : theme.colorScheme.foreground;

    return CalfButton.ghost(
      width: double.infinity,
      onPressed: onTap,
      backgroundColor: selected ? theme.colorScheme.accent : null,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.small.copyWith(color: color),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.apiClient,
    required this.themeMode,
    this.onThemeModeChanged,
  });

  final CalfClient apiClient;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _startAtLogin = false;
  Config? _config;
  bool _configLoading = true;
  String? _configError;
  bool _saving = false;
  double _draftCpus = 4;
  double _draftMemory = 4;
  double _draftSwap = 1;
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

  bool get _dirty => _config != null &&
      (_draftCpus.toInt() != _config!.cpus ||
          _draftMemory.toInt() != _config!.memoryGB ||
          _draftSwap.toInt() != _config!.memorySwapGB ||
          _httpProxyController.text.trim() != _config!.httpProxy ||
          _httpsProxyController.text.trim() != _config!.httpsProxy ||
          _noProxyEntries.join(',') != _config!.noProxy);

  @override
  void dispose() {
    _httpProxyController.dispose();
    _httpsProxyController.dispose();
    _noProxyInputController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    loadConfig();
  }

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
          httpProxy: _httpProxyController.text.trim(),
          httpsProxy: _httpsProxyController.text.trim(),
          noProxy: _noProxyEntries.join(','),
        ),
      );
      if (!mounted) return;
      setState(() {
        _config = updated;
        _draftCpus = updated.cpus.toDouble();
        _draftMemory = updated.memoryGB.toDouble();
        _draftSwap = updated.memorySwapGB.toDouble();
        _httpProxyController.text = updated.httpProxy;
        _httpsProxyController.text = updated.httpsProxy;
        _noProxyEntries = updated.noProxy
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        _httpProxyError = null;
        _httpsProxyError = null;
        _saving = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
    }
  }

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

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Settings', style: theme.textTheme.h3),
          const SizedBox(height: 24),
          _sectionHeader('General', theme),
          const SizedBox(height: 12),
          _settingRow(
            'Start Calf when you sign in to your computer',
            ShadSwitch(
              value: _startAtLogin,
              onChanged: (value) => setState(() => _startAtLogin = value),
            ),
          ),
          const SizedBox(height: 12),
          _settingRow(
            'Use Calf for Docker CLI',
            ShadSwitch(
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
              style: theme.textTheme.muted,
            ),
          ],
          const SizedBox(height: 16),
          Text('Theme', style: theme.textTheme.large),
          const SizedBox(height: 8),
          Row(
            children: [
              _themeCheckbox(ThemeMode.light, 'Light'),
              const SizedBox(width: 20),
              _themeCheckbox(ThemeMode.dark, 'Dark'),
              const SizedBox(width: 20),
              _themeCheckbox(ThemeMode.system, 'System'),
            ],
          ),
          const SizedBox(height: 24),
          _sectionHeader('Migration', theme),
          const SizedBox(height: 12),
          Text(
            'Import settings, images, volumes, containers and build history from Docker Desktop.',
            style: theme.textTheme.muted,
          ),
          const SizedBox(height: 12),
          CalfButton(
            onPressed: _migrating ? null : startDockerDesktopMigration,
            enabled: !_migrating,
            child: Text(_migrating ? 'Migrating...' : 'Migrate from Docker Desktop'),
          ),
          if (_migrationStatus != null) ...[
            const SizedBox(height: 16),
            ShadProgress(value: _migrationStatus!.progress / 100),
            const SizedBox(height: 8),
            Text(_migrationStatus!.message, style: theme.textTheme.large),
            if (_migrationStatus!.error != null && _migrationStatus!.error!.isNotEmpty)
              Text(
                _migrationStatus!.error!,
                style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive),
              ),
            if (_migrationStatus!.phase == 'completed') ...[
              const SizedBox(height: 8),
              Text(
                'Images: ${_migrationStatus!.summary.imagesOK}/${_migrationStatus!.summary.imagesTotal} · '
                'Volumes: ${_migrationStatus!.summary.volumesOK}/${_migrationStatus!.summary.volumesTotal} · '
                'Containers: ${_migrationStatus!.summary.containersOK}/${_migrationStatus!.summary.containersTotal} · '
                'Builds: ${_migrationStatus!.summary.buildsOK}/${_migrationStatus!.summary.buildsTotal}',
                style: theme.textTheme.muted,
              ),
            ],
          ],
          const SizedBox(height: 24),
          ShadCard(
            padding: const EdgeInsets.all(20),
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Proxy'),
                if (_config != null &&
                    (_config!.httpProxy.isNotEmpty ||
                        _config!.httpsProxy.isNotEmpty ||
                        _config!.noProxy.isNotEmpty))
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: ShadBadge.secondary(
                      child: Text('Configured'),
                    ),
                  ),
              ],
            ),
            description: const Text(
              'HTTP and HTTPS proxy settings for image pulls inside the VM.',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
          const SizedBox(height: 24),
          _sectionHeader('System', theme),
          const SizedBox(height: 12),
          if (_configLoading)
            Text('Loading config...', style: theme.textTheme.muted)
          else if (_configError != null)
            Text(
              _configError!,
              style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive),
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
            const SizedBox(height: 24),
            CalfButton(
              onPressed: _dirty && !_saving && _httpProxyError == null && _httpsProxyError == null
                  ? applyConfig
                  : null,
              enabled: _dirty && _httpProxyError == null && _httpsProxyError == null,
              child: Text(_saving ? 'Saving...' : 'Apply'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _themeCheckbox(ThemeMode option, String label) {
    return ShadCheckbox(
      value: widget.themeMode == option,
      onChanged: widget.onThemeModeChanged == null
          ? null
          : (checked) {
              if (checked) {
                widget.onThemeModeChanged!(option);
              }
            },
      label: Text(label),
    );
  }

  Widget _sectionHeader(String label, ShadThemeData theme) {
    return Text(label, style: theme.textTheme.h4.copyWith(color: theme.colorScheme.mutedForeground));
  }

  Widget _settingRow(String label, Widget control) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(child: Text(label, style: ShadTheme.of(context).textTheme.large)),
        control,
      ],
    );
  }

  Widget _sliderRow(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    Widget? trailing,
  }) {
    final theme = ShadTheme.of(context);
    final primary = theme.colorScheme.primary;
    final divisions = (max - min).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.large),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ShadSlider(
                key: ValueKey('$label-$value'),
                initialValue: value,
                min: min,
                max: max,
                divisions: divisions > 0 ? divisions : null,
                enabled: !_saving,
                onChanged: onChanged,
                activeTrackColor: primary,
                thumbColor: primary,
                thumbBorderColor: primary,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing,
            ],
          ],
        ),
      ],
    );
  }

  void _validateHttpProxy(String value) {
    setState(() => _httpProxyError = _validateProxyUrl(value, ['http']));
  }

  void _validateHttpsProxy(String value) {
    setState(() => _httpsProxyError = _validateProxyUrl(value, ['http', 'https']));
  }

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

  Widget _noProxySection(ShadThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('No proxy', style: theme.textTheme.small.copyWith(color: theme.colorScheme.mutedForeground)),
        const SizedBox(height: 8),
        if (_noProxyEntries.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _noProxyEntries.map((entry) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.muted,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(entry, style: theme.textTheme.small),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () {
                        setState(() => _noProxyEntries.remove(entry));
                      },
                      child: Icon(LucideIcons.x, size: 12, color: theme.colorScheme.mutedForeground),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: ShadInput(
                controller: _noProxyInputController,
                placeholder: const Text('localhost'),
                leading: Icon(LucideIcons.ban, size: 16, color: theme.colorScheme.mutedForeground),
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
              style: theme.textTheme.muted.copyWith(fontSize: 12),
            ),
          ),
      ],
    );
  }

  void _addNoProxyEntry(String rawValue, ShadThemeData theme) {
    final value = rawValue.trim();
    if (value.isEmpty || _noProxyEntries.contains(value)) return;
    if (!_isValidNoProxyEntry(value)) return;
    setState(() {
      _noProxyEntries.add(value);
      _noProxyInputController.clear();
    });
  }

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

  bool _isIpAddress(String host) {
    return RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(host);
  }

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

  Widget _proxyField({
    required String label,
    required TextEditingController controller,
    required String placeholder,
    required IconData icon,
    required ShadThemeData theme,
    String? error,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.small.copyWith(color: theme.colorScheme.mutedForeground)),
        const SizedBox(height: 8),
        ShadInput(
          controller: controller,
          placeholder: Text(placeholder),
          leading: Icon(icon, size: 16, color: theme.colorScheme.mutedForeground),
          trailing: controller.text.isNotEmpty
              ? GestureDetector(
                  onTap: () {
                    controller.clear();
                    onChanged('');
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(LucideIcons.x, size: 14, color: theme.colorScheme.mutedForeground),
                  ),
                )
              : null,
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
              style: theme.textTheme.muted.copyWith(
                fontSize: 12,
                color: theme.colorScheme.destructive,
              ),
            ),
          ),
      ],
    );
  }
}
