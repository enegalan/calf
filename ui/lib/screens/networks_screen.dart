import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/hover_list_row.dart';

class NetworksScreen extends StatefulWidget {
  const NetworksScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

  @override
  State<NetworksScreen> createState() => _NetworksScreenState();
}

class _NetworksScreenState extends State<NetworksScreen> {
  List<NetworkItem> _networks = [];
  RuntimeStatus? _runtime;
  String? _error;
  bool _loading = true;
  Timer? _timer;
  int _pollIntervalMs = 3000;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  String? _selectedNetwork;

  @override
  void initState() {
    super.initState();
    _loadNetworks();
    _loadConfig();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final config = await widget.apiClient.fetchConfig();
      if (!mounted) {
        return;
      }
      _pollIntervalMs = config.pollIntervalMs;
      _timer = Timer.periodic(Duration(milliseconds: _pollIntervalMs), (_) => _loadNetworks(silent: true));
    } catch (_) {
      if (!mounted) {
        return;
      }
      _timer = Timer.periodic(Duration(milliseconds: _pollIntervalMs), (_) => _loadNetworks(silent: true));
    }
  }

  Future<void> _loadNetworks({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final status = await widget.apiClient.fetchStatus();
      final networks = List<NetworkItem>.from(await widget.apiClient.fetchNetworks())
        ..sort((a, b) => a.name.compareTo(b.name));
      if (!mounted) {
        return;
      }
      setState(() {
        _runtime = status.runtime;
        _networks = networks;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      if (!silent) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  void _openNetwork(NetworkItem network) {
    setState(() => _selectedNetwork = network.name);
  }

  void _closeNetwork() {
    setState(() => _selectedNetwork = null);
  }

  List<NetworkItem> _filteredNetworks() {
    if (_searchQuery.isEmpty) {
      return _networks;
    }

    return _networks
        .where((network) =>
            network.name.toLowerCase().contains(_searchQuery) ||
            network.subnet.toLowerCase().contains(_searchQuery) ||
            network.driver.toLowerCase().contains(_searchQuery))
        .toList();
  }

  Future<void> _removeNetwork(NetworkItem network) async {
    try {
      await widget.apiClient.removeNetwork(network.name);
      if (_selectedNetwork == network.name) {
        _closeNetwork();
      }
      await _loadNetworks();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedNetwork != null) {
      return NetworkDetailView(
        networkName: _selectedNetwork!,
        apiClient: widget.apiClient,
        onBack: _closeNetwork,
        onRemoved: _loadNetworks,
      );
    }

    final theme = ShadTheme.of(context);
    final filtered = _filteredNetworks();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Networks', style: theme.textTheme.h3),
        const SizedBox(height: 16),
        ShadInput(
          controller: _searchController,
          placeholder: const Text('Search'),
        ),
        const SizedBox(height: 16),
        if (_loading)
          Text('Loading...', style: theme.textTheme.large)
        else if (_error != null)
          Text(
            _error!.replaceAll(r'\n', ' ').trim(),
            style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive),
          )
        else if (filtered.isEmpty)
          Text(
            _searchQuery.isNotEmpty
                ? 'No networks match "$_searchQuery".'
                : _runtime?.state == 'stopped'
                    ? 'No networks. Runtime is stopped.'
                    : 'No networks.',
            style: theme.textTheme.muted,
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final network = filtered[index];

                return HoverListRow(
                  theme: theme,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  onTap: () => _openNetwork(network),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(network.name, style: theme.textTheme.large),
                            if (network.subnet.isNotEmpty)
                              Text(network.subnet, style: theme.textTheme.muted),
                          ],
                        ),
                      ),
                      CalfButton.ghost(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        onPressed: () => _removeNetwork(network),
                        child: Icon(
                          LucideIcons.trash2,
                          size: 16,
                          color: theme.colorScheme.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class NetworkDetailView extends StatefulWidget {
  const NetworkDetailView({
    super.key,
    required this.networkName,
    required this.apiClient,
    required this.onBack,
    required this.onRemoved,
  });

  final String networkName;
  final CalfClient apiClient;
  final VoidCallback onBack;
  final Future<void> Function() onRemoved;

  @override
  State<NetworkDetailView> createState() => _NetworkDetailViewState();
}

class _NetworkDetailViewState extends State<NetworkDetailView> {
  NetworkDetail? _detail;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final detail = await widget.apiClient.fetchNetworkDetail(widget.networkName);
      if (!mounted) {
        return;
      }
      setState(() {
        _detail = detail;
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

  Future<void> _removeNetwork() async {
    try {
      await widget.apiClient.removeNetwork(widget.networkName);
      if (!mounted) {
        return;
      }
      await widget.onRemoved();
      widget.onBack();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
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
            CalfButton.ghost(
              onPressed: widget.onBack,
              child: Icon(LucideIcons.chevronLeft, size: 18, color: theme.colorScheme.foreground),
            ),
            const SizedBox(width: 4),
            Text('Networks', style: theme.textTheme.muted),
            Text(' / ', style: theme.textTheme.muted),
            Expanded(
              child: Text(
                widget.networkName,
                style: theme.textTheme.muted,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            CalfButton.outline(
              onPressed: _removeNetwork,
              child: const Text('Remove'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (_loading)
          Text('Loading...', style: theme.textTheme.large)
        else if (_error != null)
          Text(
            _error!.replaceAll(r'\n', ' ').trim(),
            style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive),
          )
        else if (_detail != null)
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoCard(
                    theme: theme,
                    rows: [
                      _InfoRow(label: 'Name', value: _detail!.name),
                      _InfoRow(label: 'ID', value: _detail!.id),
                      _InfoRow(label: 'Created', value: _displayValue(_detail!.created)),
                      _InfoRow(label: 'Subnet', value: _displayValue(_detail!.subnet)),
                      _InfoRow(label: 'Gateway', value: _displayValue(_detail!.gateway)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _InfoCard(
                    theme: theme,
                    rows: [
                      _InfoRow(label: 'Driver', value: _displayValue(_detail!.driver)),
                      _InfoRow(label: 'Scope', value: _displayValue(_detail!.scope)),
                    ],
                  ),
                  if (_detail!.options.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text('Options', style: theme.textTheme.h4),
                    const SizedBox(height: 12),
                    _OptionsTable(theme: theme, options: _detail!.options),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  String _displayValue(String value) {
    return value.isEmpty ? '—' : value;
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.theme, required this.rows});

  final ShadThemeData theme;
  final List<_InfoRow> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.border),
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.card,
      ),
      child: Column(
        children: [
          for (var index = 0; index < rows.length; index++) ...[
            if (index > 0) const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: Text(rows[index].label, style: theme.textTheme.large)),
                Expanded(
                  child: Text(
                    rows[index].value,
                    textAlign: TextAlign.end,
                    style: theme.textTheme.muted,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoRow {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;
}

class _OptionsTable extends StatelessWidget {
  const _OptionsTable({required this.theme, required this.options});

  final ShadThemeData theme;
  final Map<String, String> options;

  @override
  Widget build(BuildContext context) {
    final entries = options.entries.toList()..sort((a, b) => a.key.compareTo(b.key));

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.muted,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Row(
              children: [
                Expanded(child: Text('Key', style: theme.textTheme.small)),
                Expanded(child: Text('Value', style: theme.textTheme.small)),
              ],
            ),
          ),
          for (var index = 0; index < entries.length; index++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                border: index < entries.length - 1
                    ? Border(bottom: BorderSide(color: theme.colorScheme.border))
                    : null,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entries[index].key,
                      style: theme.textTheme.muted,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entries[index].value,
                      style: theme.textTheme.small,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
