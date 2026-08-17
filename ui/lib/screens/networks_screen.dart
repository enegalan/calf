import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/calf_snack_bar.dart';
import 'package:ui/widgets/confirm_dialog.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/poll_interval_mixin.dart';
import 'package:ui/widgets/resource_list_scaffold.dart';
import 'package:ui/theme/calf_theme.dart';

class NetworksScreen extends StatefulWidget {
  /// Creates a [NetworksScreen] widget.
  const NetworksScreen({
    super.key,
    required this.apiClient,
    this.initialNetworkName,
    this.onInitialNetworkConsumed,
  });

  final CalfClient apiClient;
  final String? initialNetworkName;
  final VoidCallback? onInitialNetworkConsumed;

  /// Creates the mutable state for [NetworksScreen].
  @override
  State<NetworksScreen> createState() => _NetworksScreenState();
}

class _NetworksScreenState extends State<NetworksScreen>
    with PollIntervalMixin, ResourceListPollMixin {
  List<NetworkItem> _networks = [];
  RuntimeStatus? _runtime;
  bool _resourceSaverActive = false;
  String? _selectedNetwork;
  final Set<String> _lockedNames = {};

  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    initListSearchListener();
    _loadNetworks();
    startPollInterval(widget.apiClient, _loadNetworks);
  }

  /// Re-arms the pending deep link when [initialNetworkName] changes.
  @override
  void didUpdateWidget(covariant NetworksScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialNetworkName != oldWidget.initialNetworkName &&
        widget.initialNetworkName != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _openInitialNetworkIfNeeded(_networks);
      });
    }
  }

  /// Releases controllers, timers, and stream subscriptions.
  @override
  void dispose() {
    disposePollInterval();
    disposeListSearch();
    super.dispose();
  }

  /// Fetches networks from the API, optionally skipping the loading indicator.
  Future<void> _loadNetworks({bool silent = false}) async {
    await runListLoad(
      silent: silent,
      body: () async {
        final status = await widget.apiClient.fetchStatus();
        final networks = List<NetworkItem>.from(
          await widget.apiClient.fetchNetworks(),
        )..sort((a, b) => a.name.compareTo(b.name));
        if (!mounted) {
          return;
        }
        setState(() {
          _runtime = status.runtime;
          _resourceSaverActive = status.resourceSaverActive;
          _networks = networks;
          listLoading = false;
        });
        _openInitialNetworkIfNeeded(networks);
      },
    );
  }

  /// Navigates to or opens the selected network.
  void _openNetwork(NetworkItem network) {
    setState(() => _selectedNetwork = network.name);
  }

  /// Opens [initialNetworkName] once networks are loaded, if provided.
  void _openInitialNetworkIfNeeded(List<NetworkItem> networks) {
    final name = widget.initialNetworkName?.trim() ?? '';
    if (name.isEmpty) {
      return;
    }
    for (final network in networks) {
      if (network.name == name) {
        widget.onInitialNetworkConsumed?.call();
        _openNetwork(network);
        return;
      }
    }
  }

  /// Closes the current detail view and returns to the list.
  void _closeNetwork() {
    setState(() => _selectedNetwork = null);
  }

  /// Returns items matching the active search and filter criteria.
  List<NetworkItem> _filteredNetworks() {
    if (listSearchQuery.isEmpty) {
      return _networks;
    }

    return _networks
        .where(
          (network) =>
              network.name.toLowerCase().contains(listSearchQuery) ||
              network.subnet.toLowerCase().contains(listSearchQuery) ||
              network.driver.toLowerCase().contains(listSearchQuery),
        )
        .toList();
  }

  /// Removes the selected resource via the API after confirmation.
  Future<void> _removeNetwork(NetworkItem network) async {
    if (_lockedNames.contains(network.name)) {
      return;
    }
    setState(() => _lockedNames.add(network.name));
    try {
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
      final ok = await runCalfToastAction(
        pending: 'Deleting "${network.name}"...',
        done: 'Deleted network "${network.name}"',
        action: () => widget.apiClient.removeNetwork(network.name),
      );
      if (!ok || !mounted) {
        return;
      }
      if (_selectedNetwork == network.name) {
        _closeNetwork();
      }
      await _loadNetworks();
    } finally {
      if (mounted) {
        setState(() => _lockedNames.remove(network.name));
      }
    }
  }

  /// Prompts for a name and creates a user-defined network.
  Future<void> _createNetwork() async {
    final nameController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => CalfAlertDialog(
        title: const Text('Create network'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'Network name',
          ),
        ),
        actions: [
          CalfButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          CalfButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    final name = nameController.text.trim();
    nameController.dispose();
    if (confirmed != true || name.isEmpty || !mounted) {
      return;
    }
    final ok = await runCalfToastAction(
      pending: 'Creating "$name"...',
      done: 'Created network "$name"',
      action: () => widget.apiClient.createNetwork(name),
    );
    if (ok && mounted) {
      await _loadNetworks();
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
    final runtimeStopped = showStoppedEngineEmpty(
      _runtime,
      resourceSaverActive: _resourceSaverActive,
    );
    final runtimeStarting = _runtime?.isStarting == true;

    return ResourceListScaffold(
      title: 'Networks',
      searchController: listSearchController,
      loading: listLoading,
      headerActions: CalfButton(
        onPressed: _createNetwork,
        child: const Text('Create'),
      ),
      empty: filtered.isEmpty,
      emptyMessage: listSearchQuery.isNotEmpty
          ? 'No networks match "$listSearchQuery".'
          : runtimeStarting
          ? 'Engine is starting…'
          : runtimeStopped
          ? 'No networks. Runtime is stopped.'
          : 'No networks.',
      emptyAction: filtered.isEmpty && runtimeStopped && listSearchQuery.isEmpty
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
                enabled: !_lockedNames.contains(network.name),
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
    final ok = await runCalfToastAction(
      pending: 'Starting engine...',
      done: 'Engine started',
      action: widget.apiClient.startRuntime,
    );
    if (ok && mounted) {
      await _loadNetworks();
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
  bool _loading = true;

  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  /// Fetches Detail from the API and updates state.
  Future<void> _loadDetail() async {
    setState(() => _loading = true);

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
      setState(() => _loading = false);
      showCalfErrorSnackBar(context, error);
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
    final ok = await runCalfToastAction(
      pending: 'Deleting "${widget.networkName}"...',
      done: 'Deleted network "${widget.networkName}"',
      action: () => widget.apiClient.removeNetwork(widget.networkName),
    );
    if (!ok || !mounted) {
      return;
    }
    await widget.onRemoved();
    widget.onBack();
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
