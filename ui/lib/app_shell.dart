import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  final _apiClient = const ApiClient();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Row(
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
              Text('Calf', style: theme.textTheme.h3),
              const SizedBox(height: 24),
              _NavItem(
                label: 'Status',
                selected: _selectedIndex == 0,
                onTap: () => setState(() => _selectedIndex = 0),
              ),
              const SizedBox(height: 8),
              _NavItem(
                label: 'Settings',
                selected: _selectedIndex == 1,
                onTap: () => setState(() => _selectedIndex = 1),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _selectedIndex == 0
                ? StatusScreen(apiClient: _apiClient)
                : SettingsScreen(apiClient: _apiClient),
          ),
        ),
      ],
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return ShadButton.ghost(
      width: double.infinity,
      onPressed: onTap,
      backgroundColor: selected ? theme.colorScheme.accent : null,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(label),
      ),
    );
  }
}

class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key, required this.apiClient});

  final ApiClient apiClient;

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  DaemonStatus? _status;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final status = await widget.apiClient.fetchStatus();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = status;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Daemon status', style: theme.textTheme.h3),
            const Spacer(),
            ShadButton.outline(
              onPressed: _loading ? null : _loadStatus,
              child: const Text('Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (_loading)
          Text('Loading...', style: theme.textTheme.large)
        else if (_error != null)
          Text(_error!, style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive))
        else if (_status != null)
          _StatusDetails(status: _status!),
      ],
    );
  }
}

class _StatusDetails extends StatelessWidget {
  const _StatusDetails({required this.status});

  final DaemonStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final items = <MapEntry<String, String>>[
      MapEntry('Version', status.version),
      MapEntry('Uptime', '${status.uptimeSeconds}s'),
      MapEntry('Listen address', status.listenAddr),
      MapEntry('Log level', status.logLevel),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items) ...[
          Text(item.key, style: theme.textTheme.muted),
          const SizedBox(height: 4),
          Text(item.value, style: theme.textTheme.large),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.apiClient});

  final ApiClient apiClient;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  DaemonStatus? _status;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final status = await widget.apiClient.fetchStatus();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = status;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Settings', style: theme.textTheme.h3),
        const SizedBox(height: 8),
        Text(
          'Read-only view of the active daemon configuration.',
          style: theme.textTheme.muted,
        ),
        const SizedBox(height: 24),
        if (_loading)
          Text('Loading...', style: theme.textTheme.large)
        else if (_error != null)
          Text(_error!, style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive))
        else if (_status != null) ...[
          Text('Config file', style: theme.textTheme.muted),
          const SizedBox(height: 4),
          Text('~/.config/calf/config.yaml', style: theme.textTheme.large),
          const SizedBox(height: 16),
          Text('Listen address', style: theme.textTheme.muted),
          const SizedBox(height: 4),
          Text(_status!.listenAddr, style: theme.textTheme.large),
          const SizedBox(height: 16),
          Text('Log level', style: theme.textTheme.muted),
          const SizedBox(height: 4),
          Text(_status!.logLevel, style: theme.textTheme.large),
        ],
      ],
    );
  }
}
