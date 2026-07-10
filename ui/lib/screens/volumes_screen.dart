import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/screens/volume_detail_screen.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/running_filter_switch.dart';
import 'package:ui/widgets/status_dot.dart';

class VolumesScreen extends StatefulWidget {
  const VolumesScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

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

  @override
  void initState() {
    super.initState();
    _loadVolumes();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

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

  List<VolumeItem> _sortedVolumes(List<VolumeItem> volumes) {
    return List<VolumeItem>.from(volumes)..sort((a, b) => a.name.compareTo(b.name));
  }

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

      if (!silent || _volumesChanged(_volumes, volumes) || _runtime?.state != status.runtime.state) {
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

  void _openVolume(VolumeItem volume) {
    setState(() => _selectedVolume = volume.name);
  }

  void _closeVolume() {
    setState(() => _selectedVolume = null);
  }

  List<VolumeItem> _filteredVolumes() {
    var items = _volumes;

    if (_runningOnly) {
      items = items.where((volume) => volume.inUse).toList();
    }

    if (_searchQuery.isEmpty) {
      return items;
    }

    return items.where((volume) =>
        volume.name.toLowerCase().contains(_searchQuery) ||
        volume.driver.toLowerCase().contains(_searchQuery)).toList();
  }

  Future<void> _cloneVolume(VolumeItem volume) async {
    final nameController = TextEditingController(text: '${volume.name}-copy');
    final theme = ShadTheme.of(context);

    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: const Text('Clone volume'),
        description: Text('Create a copy of "${volume.name}".'),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Volume name', style: theme.textTheme.small.copyWith(color: theme.colorScheme.mutedForeground)),
            const SizedBox(height: 8),
            ShadInput(
              controller: nameController,
              placeholder: const Text('Volume name'),
            ),
          ],
        ),
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
      await _loadVolumes();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

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

    final theme = ShadTheme.of(context);
    final filtered = _filteredVolumes();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Volumes', style: theme.textTheme.h3),
        const SizedBox(height: 16),
        ShadInput(
          controller: _searchController,
          placeholder: const Text('Search'),
        ),
        const SizedBox(height: 12),
        RunningFilterSwitch(
          value: _runningOnly,
          onChanged: (value) => setState(() => _runningOnly = value),
        ),
        const SizedBox(height: 16),
        if (_loading)
          Text('Loading...', style: theme.textTheme.large)
        else if (_error != null)
          Text(_error!, style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive))
        else if (filtered.isEmpty)
          Text(
            _searchQuery.isNotEmpty
                ? 'No volumes match "$_searchQuery".'
                : _runtime?.state == 'stopped'
                    ? 'No volumes. Runtime is stopped.'
                    : _runningOnly
                        ? 'No volumes in use.'
                        : 'No volumes.',
            style: theme.textTheme.muted,
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final volume = filtered[index];

                return HoverListRow(
                  theme: theme,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  onTap: () => _openVolume(volume),
                  child: Row(
                    children: [
                      StatusDot(active: volume.inUse, hollow: !volume.inUse),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(volume.name, style: theme.textTheme.large),
                            if (volume.subtitle.isNotEmpty)
                              Text(volume.subtitle, style: theme.textTheme.muted),
                          ],
                        ),
                      ),
                      Tooltip(
                        message: 'Clone',
                        child: CalfButton.outline(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          onPressed: () => _cloneVolume(volume),
                          child: Icon(LucideIcons.copy, size: 16, color: theme.colorScheme.foreground),
                        ),
                      ),
                      const SizedBox(width: 8),
                      CalfButton.outline(
                        onPressed: () async {
                          await widget.apiClient.removeVolume(volume.name);
                          await _loadVolumes();
                        },
                        child: const Text('Remove'),
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

