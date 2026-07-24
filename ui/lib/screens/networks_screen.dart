import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/confirm_dialog.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/poll_interval_mixin.dart';
import 'package:ui/widgets/resource_list_scaffold.dart';
import 'package:ui/theme/calf_theme.dart';

class NetworksScreen extends StatefulWidget {
  /// Creates a [NetworksScreen] widget.
  const NetworksScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

  /// Creates the mutable state for [NetworksScreen].
  @override
  State<NetworksScreen> createState() => _NetworksScreenState();
}

class _NetworksScreenState extends State<NetworksScreen>
    with PollIntervalMixin {
  List<NetworkItem> _networks = [];
  RuntimeStatus? _runtime;
  String? _error;
  bool _loading = true;
  bool _refreshInFlight = false;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  String? _selectedNetwork;

  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    _loadNetworks();
    startPollInterval(widget.apiClient, _loadNetworks);
    _searchController.addListener(() {
      setState(
        () => _searchQuery = _searchController.text.trim().toLowerCase(),
      );
    });
  }

  /// Releases controllers, timers, and stream subscriptions.
  @override
  void dispose() {
    disposePollInterval();
    _searchController.dispose();
    super.dispose();
  }

  /// Fetches networks from the API, optionally skipping the loading indicator.
  Future<void> _loadNetworks({bool silent = false}) async {
    if (_refreshInFlight) {
      return;
    }

    _refreshInFlight = true;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final status = await widget.apiClient.fetchStatus();
      final networks = List<NetworkItem>.from(
        await widget.apiClient.fetchNetworks(),
      )..sort((a, b) => a.name.compareTo(b.name));
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
    } finally {
      _refreshInFlight = false;
    }
  }

  /// Navigates to or opens the selected network.
  void _openNetwork(NetworkItem network) {
    setState(() => _selectedNetwork = network.name);
  }

  /// Closes the current detail view and returns to the list.
  void _closeNetwork() {
    setState(() => _selectedNetwork = null);
  }

  /// Returns items matching the active search and filter criteria.
  List<NetworkItem> _filteredNetworks() {
    if (_searchQuery.isEmpty) {
      return _networks;
    }

    return _networks
        .where(
          (network) =>
              network.name.toLowerCase().contains(_searchQuery) ||
              network.subnet.toLowerCase().contains(_searchQuery) ||
              network.driver.toLowerCase().contains(_searchQuery),
        )
        .toList();
  }

  /// Removes the selected resource via the API after confirmation.
  Future<void> _removeNetwork(NetworkItem network) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Remove network',
      description: 'Remove "${network.name}"? This cannot be undone.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
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

  /// Builds the widget tree for the current screen state.
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

    final filtered = _filteredNetworks();
    final theme = Theme.of(context);
    final runtimeStopped = _runtime?.state == 'stopped';

    return ResourceListScaffold(
      title: 'Networks',
      searchController: _searchController,
      loading: _loading,
      error: _error,
      empty: filtered.isEmpty,
      emptyMessage: _searchQuery.isNotEmpty
          ? 'No networks match "$_searchQuery".'
          : runtimeStopped
          ? 'No networks. Runtime is stopped.'
          : 'No networks.',
      emptyAction: filtered.isEmpty && runtimeStopped && _searchQuery.isEmpty
          ? CalfButton(
              onPressed: _startEngine,
              child: const Text('Start engine'),
            )
          : null,
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
                    Text(network.name, style: theme.textTheme.titleMedium),
                    if (network.subnet.isNotEmpty)
                      Text(network.subnet, style: CalfTheme.muted(theme)),
                  ],
                ),
              ),
              CalfButton.outline(
                onPressed: () => _removeNetwork(network),
                child: const Text('Remove'),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Starts the container engine when the list is empty and runtime is stopped.
  Future<void> _startEngine() async {
    try {
      await widget.apiClient.startRuntime();
      if (!mounted) {
        return;
      }
      await _loadNetworks();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }
}

class NetworkDetailView extends StatefulWidget {
  /// Creates a [NetworkDetailView] widget.
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

  /// Creates the mutable state for [NetworkDetailView].
  @override
  State<NetworkDetailView> createState() => _NetworkDetailViewState();
}

class _NetworkDetailViewState extends State<NetworkDetailView> {
  NetworkDetail? _detail;
  String? _error;
  bool _loading = true;

  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  /// Fetches Detail from the API and updates state.
  Future<void> _loadDetail() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final detail = await widget.apiClient.fetchNetworkDetail(
        widget.networkName,
      );
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

  /// Removes the selected resource via the API after confirmation.
  Future<void> _removeNetwork() async {
    final confirmed = await confirmDialog(
      context,
      title: 'Remove network',
      description: 'Remove "${widget.networkName}"? This cannot be undone.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
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

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CalfButton.ghost(
              width: 36,
              height: 36,
              onPressed: widget.onBack,
              child: Icon(
                LucideIcons.chevronLeft,
                size: 18,
                color: theme.colorScheme.onSurface,
              ),
            ),

            /// Creates a [_NetworkDetailViewState] widget.
            const SizedBox(width: 4),
            Text('Networks', style: CalfTheme.muted(theme)),
            Text(' / ', style: CalfTheme.muted(theme)),
            Expanded(
              child: Text(
                widget.networkName,
                style: CalfTheme.muted(theme),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            CalfButton.outline(
              onPressed: _removeNetwork,
              child: const Text('Remove'),
            ),
          ],
        ),

        /// Creates a [_NetworkDetailViewState] widget.
        const SizedBox(height: 24),
        if (_loading)
          Text('Loading...', style: theme.textTheme.titleMedium)
        else if (_error != null)
          Text(
            _error!.replaceAll(r'\n', ' ').trim(),
            style: theme.textTheme.titleMedium!.copyWith(
              color: theme.colorScheme.error,
            ),
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
                      _InfoRow(
                        label: 'Created',
                        value: _displayValue(_detail!.created),
                      ),
                      _InfoRow(
                        label: 'Subnet',
                        value: _displayValue(_detail!.subnet),
                      ),
                      _InfoRow(
                        label: 'Gateway',
                        value: _displayValue(_detail!.gateway),
                      ),
                    ],
                  ),

                  /// Creates a [_NetworkDetailViewState] widget.
                  const SizedBox(height: 16),
                  _InfoCard(
                    theme: theme,
                    rows: [
                      _InfoRow(
                        label: 'Driver',
                        value: _displayValue(_detail!.driver),
                      ),
                      _InfoRow(
                        label: 'Scope',
                        value: _displayValue(_detail!.scope),
                      ),
                    ],
                  ),
                  if (_detail!.options.isNotEmpty) ...[
                    /// Creates a [_NetworkDetailViewState] widget.
                    const SizedBox(height: 24),
                    Text('Options', style: theme.textTheme.titleLarge),

                    /// Creates a [_NetworkDetailViewState] widget.
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

  /// Returns a display-friendly string, using a placeholder when empty.
  String _displayValue(String value) {
    return value.isEmpty ? '—' : value;
  }
}

class _InfoCard extends StatelessWidget {
  /// Creates a [_InfoCard] widget.
  const _InfoCard({required this.theme, required this.rows});

  final ThemeData theme;
  final List<_InfoRow> rows;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surface,
      ),
      child: Column(
        children: [
          for (var index = 0; index < rows.length; index++) ...[
            if (index > 0) const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    rows[index].label,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Expanded(
                  child: Text(
                    rows[index].value,
                    textAlign: TextAlign.end,
                    style: CalfTheme.muted(theme),
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
  /// Creates a [_InfoRow] widget.
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;
}

class _OptionsTable extends StatelessWidget {
  /// Creates a [_OptionsTable] widget.
  const _OptionsTable({required this.theme, required this.options});

  final ThemeData theme;
  final Map<String, String> options;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final entries = options.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(7),
              ),
            ),
            child: Row(
              children: [
                Expanded(child: Text('Key', style: theme.textTheme.bodySmall)),
                Expanded(
                  child: Text('Value', style: theme.textTheme.bodySmall),
                ),
              ],
            ),
          ),
          for (var index = 0; index < entries.length; index++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                border: index < entries.length - 1
                    ? Border(
                        bottom: BorderSide(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      )
                    : null,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entries[index].key,
                      style: CalfTheme.muted(theme),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entries[index].value,
                      style: theme.textTheme.bodySmall,
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
