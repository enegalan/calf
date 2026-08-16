import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/widgets/error_text.dart';
import 'package:ui/screens/volume_detail_screen.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/calf_snack_bar.dart';
import 'package:ui/widgets/confirm_dialog.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/poll_interval_mixin.dart';
import 'package:ui/widgets/resource_list_scaffold.dart';
import 'package:ui/widgets/running_filter_switch.dart';
import 'package:ui/widgets/status_dot.dart';
import 'package:ui/theme/calf_theme.dart';

class VolumesScreen extends StatefulWidget {
  /// Creates a screen that lists Docker volumes and supports search and actions.
  const VolumesScreen({
    super.key,
    required this.apiClient,
    this.onOpenContainer,
    this.initialVolumeName,
    this.onInitialVolumeConsumed,
  });

  final CalfClient apiClient;
  final void Function(String containerId)? onOpenContainer;
  final String? initialVolumeName;
  final VoidCallback? onInitialVolumeConsumed;

  /// Creates the mutable state for [VolumesScreen].
  @override
  State<VolumesScreen> createState() => _VolumesScreenState();
}

class _VolumesScreenState extends State<VolumesScreen>
    with PollIntervalMixin, ResourceListPollMixin {
  List<VolumeItem> _volumes = [];
  RuntimeStatus? _runtime;
  bool _resourceSaverActive = false;
  bool _runningOnly = false;
  String? _selectedVolume;

  /// Loads volumes and wires the search field to filter updates.
  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    initListSearchListener();
    _loadVolumes();
    startPollInterval(widget.apiClient, _loadVolumes);
  }

  /// Re-arms the pending deep link when [initialVolumeName] changes.
  @override
  void didUpdateWidget(covariant VolumesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialVolumeName != oldWidget.initialVolumeName &&
        widget.initialVolumeName != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _openInitialVolumeIfNeeded(_volumes);
      });
    }
  }

  /// Disposes the search controller and poll timer.
  /// Releases controllers, timers, and stream subscriptions.
  @override
  void dispose() {
    disposePollInterval();
    disposeListSearch();
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
    await runListLoad(
      silent: silent,
      body: () async {
        final status = await widget.apiClient.fetchStatus();
        final volumes = _sortedVolumes(await widget.apiClient.fetchVolumes());
        if (!mounted) {
          return;
        }

        final hadSilentFailure = consecutiveSilentFailures > 0;
        if (!silent ||
            _volumesChanged(_volumes, volumes) ||
            _runtime?.state != status.runtime.state ||
            hadSilentFailure) {
          setState(() {
            _runtime = status.runtime;
            _resourceSaverActive = status.resourceSaverActive;
            _volumes = volumes;
            listLoading = false;
            listError = null;
          });
        }
        _openInitialVolumeIfNeeded(volumes);
      },
    );
  }

  /// Navigates to the detail view for [volume].
  void _openVolume(VolumeItem volume) {
    setState(() => _selectedVolume = volume.name);
  }

  /// Opens [initialVolumeName] once volumes are loaded, if provided.
  void _openInitialVolumeIfNeeded(List<VolumeItem> volumes) {
    final name = widget.initialVolumeName?.trim() ?? '';
    if (name.isEmpty) {
      return;
    }
    for (final volume in volumes) {
      if (volume.name == name) {
        widget.onInitialVolumeConsumed?.call();
        _openVolume(volume);
        return;
      }
    }
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

    if (listSearchQuery.isEmpty) {
      return items;
    }

    return items
        .where(
          (volume) =>
              volume.name.toLowerCase().contains(listSearchQuery) ||
              volume.driver.toLowerCase().contains(listSearchQuery),
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
      showCalfSnackBar(context, 'Cloned volume to "$destination"');
      await _loadVolumes();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => listError = formatAsyncError(error));
    }
  }

  /// Removes [volume] via the API and refreshes the list.
  Future<void> _removeVolume(VolumeItem volume) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Remove volume',
      description: 'Remove "${volume.name}"? This cannot be undone.',
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
      showCalfSnackBar(context, 'Deleted volume "${volume.name}"');
      await _loadVolumes();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => listError = formatAsyncError(error));
    }
  }

  /// Builds the volume list or the selected volume detail view.
  @override
  Widget build(BuildContext context) {
    if (_selectedVolume != null) {
      return VolumeDetailView(
        key: ValueKey(_selectedVolume!),
        volumeName: _selectedVolume!,
        apiClient: widget.apiClient,
        onBack: _closeVolume,
        onRemoved: _loadVolumes,
        onOpenContainer: widget.onOpenContainer,
      );
    }

    final theme = Theme.of(context);
    final filtered = _filteredVolumes();
    final runtimeStopped = showStoppedEngineEmpty(
      _runtime,
      resourceSaverActive: _resourceSaverActive,
    );
    final runtimeStarting = _runtime?.isStarting == true;

    return ResourceListScaffold(
      title: 'Volumes',
      searchController: listSearchController,
      loading: listLoading,
      error: listError,
      empty: filtered.isEmpty,
      emptyMessage: listSearchQuery.isNotEmpty
          ? 'No volumes match "$listSearchQuery".'
          : runtimeStarting
          ? 'Engine is starting…'
          : runtimeStopped
          ? 'No volumes. Runtime is stopped.'
          : _runningOnly
          ? 'No volumes in use.'
          : 'No volumes.',
      emptyAction: filtered.isEmpty && runtimeStopped && listSearchQuery.isEmpty
          ? CalfButton(
              onPressed: _startEngine,
              child: const Text('Start engine'),
            )
          : null,
      filter: RunningFilterSwitch(
        value: _runningOnly,
        onChanged: (value) => setState(() => _runningOnly = value),
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
      setState(() => listError = formatAsyncError(error));
    }
  }
}
