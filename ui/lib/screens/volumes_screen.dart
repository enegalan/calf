import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/screens/volume_detail_screen.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/confirm_dialog.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/resource_list_scaffold.dart';
import 'package:ui/widgets/running_filter_switch.dart';
import 'package:ui/widgets/status_dot.dart';
import 'package:ui/theme/calf_theme.dart';

class VolumesScreen extends StatefulWidget {
  /// Creates a screen that lists Docker volumes and supports search and actions.
  const VolumesScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

  /// Creates the mutable state for [VolumesScreen].
  @override
  State<VolumesScreen> createState() => _VolumesScreenState();
}

class _VolumesScreenState extends State<VolumesScreen> {
  List<VolumeItem> _volumes = [];
  RuntimeStatus? _runtime;
  String? _error;
  bool _loading = true;
  bool _refreshInFlight = false;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  bool _runningOnly = false;
  String? _selectedVolume;

  /// Loads volumes and wires the search field to filter updates.
  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    _loadVolumes();
    _searchController.addListener(() {
      setState(
        () => _searchQuery = _searchController.text.trim().toLowerCase(),
      );
    });
  }

  /// Disposes the search controller.
  /// Releases controllers, timers, and stream subscriptions.
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Returns whether two volume lists differ in any displayed field.
  bool _volumesChanged(List<VolumeItem> current, List<VolumeItem> next) {
    if (current.length != next.length) {
      return true;
    }

    for (var index = 0; index < current.length; index++) {
      final before = current[index];
      final after = next[index];
      if (before.name != after.name ||
          before.driver != after.driver ||
          before.inUse != after.inUse ||
          before.size != after.size ||
          before.created != after.created) {
        return true;
      }
    }

    return false;
  }

  /// Returns a copy of [volumes] sorted alphabetically by name.
  List<VolumeItem> _sortedVolumes(List<VolumeItem> volumes) {
    return List<VolumeItem>.from(volumes)
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  /// Fetches runtime status and volumes, optionally skipping the loading indicator.
  Future<void> _loadVolumes({bool silent = false}) async {
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
      final volumes = _sortedVolumes(await widget.apiClient.fetchVolumes());
      if (!mounted) {
        return;
      }

      if (!silent ||
          _volumesChanged(_volumes, volumes) ||
          _runtime?.state != status.runtime.state) {
        setState(() {
          _runtime = status.runtime;
          _volumes = volumes;
          _loading = false;
        });
      }
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

  /// Navigates to the detail view for [volume].
  void _openVolume(VolumeItem volume) {
    setState(() => _selectedVolume = volume.name);
  }

  /// Returns from the volume detail view to the list.
  void _closeVolume() {
    setState(() => _selectedVolume = null);
  }

  /// Returns volumes matching the search query and running-only filter.
  List<VolumeItem> _filteredVolumes() {
    var items = _volumes;

    if (_runningOnly) {
      items = items.where((volume) => volume.inUse).toList();
    }

    if (_searchQuery.isEmpty) {
      return items;
    }

    return items
        .where(
          (volume) =>
              volume.name.toLowerCase().contains(_searchQuery) ||
              volume.driver.toLowerCase().contains(_searchQuery),
        )
        .toList();
  }

  /// Prompts for a destination name and clones [volume] via the API.
  Future<void> _cloneVolume(VolumeItem volume) async {
    final nameController = TextEditingController(text: '${volume.name}-copy');
    final theme = Theme.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clone volume'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Create a copy of "${volume.name}".'),
            const SizedBox(height: 16),
            Text(
              'Volume name',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),

            /// Creates a [_VolumesScreenState] widget.
            const SizedBox(height: 8),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(hintText: 'Volume name'),
            ),
          ],
        ),
        actions: [
          CalfButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          CalfButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clone'),
          ),
        ],
      ),
    );

    final destination = nameController.text.trim();
    nameController.dispose();

    if (confirmed != true || destination.isEmpty || !mounted) {
      return;
    }

    try {
      await widget.apiClient.cloneVolume(volume.name, destination);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cloned volume to "$destination"')),
      );
      await _loadVolumes();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  /// Removes [volume] via the API and refreshes the list.
  Future<void> _removeVolume(VolumeItem volume) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Remove volume',
      description:
          'Remove "${volume.name}"? This cannot be undone.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    try {
      await widget.apiClient.removeVolume(volume.name);
      if (!mounted) {
        return;
      }
      await _loadVolumes();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  /// Builds the volume list or the selected volume detail view.
  @override
  Widget build(BuildContext context) {
    if (_selectedVolume != null) {
      return VolumeDetailView(
        volumeName: _selectedVolume!,
        apiClient: widget.apiClient,
        onBack: _closeVolume,
        onRemoved: _loadVolumes,
      );
    }

    final theme = Theme.of(context);
    final filtered = _filteredVolumes();
    final runtimeStopped = _runtime?.state == 'stopped';

    return ResourceListScaffold(
      title: 'Volumes',
      searchController: _searchController,
      loading: _loading,
      error: _error,
      empty: filtered.isEmpty,
      emptyMessage: _searchQuery.isNotEmpty
          ? 'No volumes match "$_searchQuery".'
          : runtimeStopped
          ? 'No volumes. Runtime is stopped.'
          : _runningOnly
          ? 'No volumes in use.'
          : 'No volumes.',
      emptyAction: filtered.isEmpty && runtimeStopped && _searchQuery.isEmpty
          ? CalfButton(
              onPressed: _startEngine,
              child: const Text('Start engine'),
            )
          : null,
      filter: RunningFilterSwitch(
        value: _runningOnly,
        onChanged: (value) => setState(() => _runningOnly = value),
      ),
      headerActions: Tooltip(
        message: 'Refresh',
        child: CalfButton.ghost(
          width: 36,
          height: 36,
          enabled: !_loading && !_refreshInFlight,
          onPressed: _loadVolumes,
          child: Icon(
            LucideIcons.refreshCw,
            size: 16,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final volume = filtered[index];

        return HoverListRow(
          theme: theme,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          onTap: () => _openVolume(volume),
          child: Row(
            children: [
              StatusDot(
                active: volume.inUse,
                hollow: !volume.inUse,
                tooltip: volume.inUse ? 'In use' : 'Not in use',
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(volume.name, style: theme.textTheme.titleMedium),
                    if (volume.subtitle.isNotEmpty)
                      Text(volume.subtitle, style: CalfTheme.muted(theme)),
                  ],
                ),
              ),
              Tooltip(
                message: 'Clone',
                child: CalfButton.outline(
                  width: 36,
                  height: 36,
                  onPressed: () => _cloneVolume(volume),
                  child: Icon(
                    LucideIcons.copy,
                    size: 16,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              CalfButton.outline(
                onPressed: () => _removeVolume(volume),
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
      await _loadVolumes();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }
}
