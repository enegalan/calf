import 'dart:async';
import 'dart:io' show Platform, Process;

import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/screens/container_detail_screen.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/storage/container_groups.dart';

class ContainersScreen extends StatefulWidget {
  const ContainersScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

  @override
  State<ContainersScreen> createState() => _ContainersScreenState();
}

class _ContainersScreenState extends State<ContainersScreen> {
  List<ContainerItem> _containers = [];
  RuntimeStatus? _runtime;
  String? _error;
  bool _loading = true;
  String? _selectedId;
  ContainerItem? _detailContainer;
  Timer? _timer;
  int _pollIntervalMs = 3000;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  bool _runningOnly = false;
  final Map<String, bool> _expandedGroups = {};

  @override
  void initState() {
    super.initState();
    _loadGroupPreferences();
    _loadContainers();
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
      if (mounted) {
        _pollIntervalMs = config.pollIntervalMs;
        _timer?.cancel();
        _timer = Timer.periodic(Duration(milliseconds: _pollIntervalMs), (_) => _loadContainers(silent: true));
      }
    } catch (_) {
      if (mounted) {
        _timer?.cancel();
        _timer = Timer.periodic(Duration(milliseconds: _pollIntervalMs), (_) => _loadContainers(silent: true));
      }
    }
  }

  Future<void> _loadContainers({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final status = await widget.apiClient.fetchStatus();
      final containers = await widget.apiClient.fetchContainers();
      if (!mounted) {
        return;
      }
      setState(() {
        _runtime = status.runtime;
        _containers = containers;
        _loading = false;
        if (_detailContainer != null) {
          for (final container in containers) {
            if (container.id == _detailContainer!.id) {
              _detailContainer = container;
              break;
            }
          }
        }
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

  Future<void> _runAction(Future<void> Function() action) async {
    try {
      await action();
      await _loadContainers();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  Future<void> _runGroupAction(List<ContainerItem> containers, Future<void> Function(String id) action) async {
    try {
      for (final container in containers) {
        await action(container.id);
      }
      await _loadContainers();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  void _openContainer(ContainerItem container) {
    setState(() {
      _detailContainer = container;
      _selectedId = container.id;
    });
  }

  void _closeContainerDetail() {
    setState(() {
      _detailContainer = null;
      _selectedId = null;
    });
  }

  void _openPort(int port) {
    if (!Platform.isMacOS) {
      return;
    }
    Process.run('open', ['http://localhost:$port']);
  }

  Future<void> _loadGroupPreferences() async {
    final saved = await ContainerGroupPreferences.loadExpanded();
    if (!mounted) {
      return;
    }
    setState(() => _expandedGroups.addAll(saved));
  }

  bool _isGroupExpanded(String project) => _expandedGroups[project] ?? false;

  void _toggleGroup(String project) {
    setState(() {
      _expandedGroups[project] = !(_expandedGroups[project] ?? false);
    });
    ContainerGroupPreferences.saveExpanded(_expandedGroups);
  }

  List<ContainerItem> _filteredContainers() {
    var items = _containers;

    if (_runningOnly) {
      items = items.where((container) => container.isRunning).toList();
    }

    if (_searchQuery.isEmpty) {
      return items;
    }

    return items.where((container) {
      return container.name.toLowerCase().contains(_searchQuery) ||
          container.displayName.toLowerCase().contains(_searchQuery) ||
          container.composeProject.toLowerCase().contains(_searchQuery) ||
          container.image.toLowerCase().contains(_searchQuery) ||
          container.subtitle.toLowerCase().contains(_searchQuery) ||
          container.id.toLowerCase().contains(_searchQuery) ||
          container.status.toLowerCase().contains(_searchQuery) ||
          container.ports.toLowerCase().contains(_searchQuery);
    }).toList();
  }

  _ContainerLayout _buildLayout(List<ContainerItem> items) {
    final groups = <String, List<ContainerItem>>{};
    final standalone = <ContainerItem>[];

    for (final container in items) {
      if (container.isCompose) {
        groups.putIfAbsent(container.composeProject, () => []).add(container);
      } else {
        standalone.add(container);
      }
    }

    final sortedProjects = groups.keys.toList()..sort();
    standalone.sort((a, b) => a.displayName.compareTo(b.displayName));

    return _ContainerLayout(
      groups: sortedProjects.map((project) => MapEntry(project, groups[project]!..sort((a, b) => a.displayName.compareTo(b.displayName)))).toList(),
      standalone: standalone,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_detailContainer != null) {
      return ContainerDetailView(
        container: _detailContainer!,
        apiClient: widget.apiClient,
        onBack: _closeContainerDetail,
        onChanged: _loadContainers,
      );
    }

    final theme = ShadTheme.of(context);
    final filtered = _filteredContainers();
    final layout = _buildLayout(filtered);
    final runningCount = _containers.where((container) => container.isRunning).length;
    final isEmpty = layout.groups.isEmpty && layout.standalone.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Containers', style: theme.textTheme.h3),
            const SizedBox(width: 12),
            Text(
              '$runningCount running / ${_containers.length} total',
              style: theme.textTheme.muted,
            ),
          ],
        ),
        const SizedBox(height: 16),
        ShadInput(
          controller: _searchController,
          placeholder: const Text('Search'),
          leading: Icon(LucideIcons.search, size: 16, color: theme.colorScheme.mutedForeground),
        ),
        const SizedBox(height: 12),
        ShadCheckbox(
          value: _runningOnly,
          onChanged: (value) => setState(() => _runningOnly = value),
          label: const Text('Running only'),
        ),
        const SizedBox(height: 16),
        if (_runtime?.portConflicts.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _runtime!.portConflicts.map((conflict) => conflict.hint).join('\n'),
              style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive),
            ),
          ),
        if (_loading)
          Text('Loading...', style: theme.textTheme.large)
        else if (_error != null)
          Text(_error!, style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive))
        else if (isEmpty)
          Expanded(
            child: Center(
              child: Text(
                _searchQuery.isNotEmpty
                    ? 'No containers match "$_searchQuery".'
                    : _runtime?.state == 'stopped'
                        ? 'No containers. Runtime is stopped — run make dev-backend first.'
                        : _runningOnly
                            ? 'No running containers.'
                            : 'No containers.',
                style: theme.textTheme.muted,
              ),
            ),
          )
        else
          Expanded(
            child: ListView(
              children: [
                for (final group in layout.groups)
                  _ComposeGroupTile(
                    project: group.key,
                    containers: group.value,
                    theme: theme,
                    expanded: _isGroupExpanded(group.key),
                    selectedId: _selectedId,
                    onToggle: () => _toggleGroup(group.key),
                    onStart: (id) => _runAction(() => widget.apiClient.startContainer(id)),
                    onStop: (id) => _runAction(() => widget.apiClient.stopContainer(id)),
                    onRemove: (id) => _runAction(() => widget.apiClient.removeContainer(id)),
                    onStopAll: () => _runGroupAction(group.value, widget.apiClient.stopContainer),
                    onRemoveAll: () => _runGroupAction(group.value, widget.apiClient.removeContainer),
                    onOpen: _openContainer,
                    onOpenPort: _openPort,
                  ),
                for (final container in layout.standalone)
                  _ContainerTile(
                    container: container,
                    theme: theme,
                    selected: _selectedId == container.id,
                    onStart: () => _runAction(() => widget.apiClient.startContainer(container.id)),
                    onStop: () => _runAction(() => widget.apiClient.stopContainer(container.id)),
                    onRemove: () => _runAction(() => widget.apiClient.removeContainer(container.id)),
                    onOpen: () => _openContainer(container),
                    onOpenPort: _openPort,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ContainerLayout {
  const _ContainerLayout({
    required this.groups,
    required this.standalone,
  });

  final List<MapEntry<String, List<ContainerItem>>> groups;
  final List<ContainerItem> standalone;
}

class _ComposeGroupTile extends StatelessWidget {
  const _ComposeGroupTile({
    required this.project,
    required this.containers,
    required this.theme,
    required this.expanded,
    required this.selectedId,
    required this.onToggle,
    required this.onStart,
    required this.onStop,
    required this.onRemove,
    required this.onStopAll,
    required this.onRemoveAll,
    required this.onOpen,
    required this.onOpenPort,
  });

  final String project;
  final List<ContainerItem> containers;
  final ShadThemeData theme;
  final bool expanded;
  final String? selectedId;
  final VoidCallback onToggle;
  final Future<void> Function(String id) onStart;
  final Future<void> Function(String id) onStop;
  final Future<void> Function(String id) onRemove;
  final VoidCallback onStopAll;
  final VoidCallback onRemoveAll;
  final void Function(ContainerItem container) onOpen;
  final void Function(int port) onOpenPort;

  @override
  Widget build(BuildContext context) {
    final running = containers.where((container) => container.isRunning).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HoverListRow(
          theme: theme,
          selected: false,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              CalfButton.ghost(
                width: 28,
                height: 28,
                padding: EdgeInsets.zero,
                onPressed: onToggle,
                child: Icon(expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 16),
              ),
              const SizedBox(width: 4),
              _ComposeStackIcon(containers: containers, theme: theme),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(project, style: theme.textTheme.large),
                    Text(
                      '$running running / ${containers.length} total',
                      style: theme.textTheme.small.copyWith(color: theme.colorScheme.mutedForeground),
                    ),
                  ],
                ),
              ),
              _ActionIcon(icon: LucideIcons.square, tooltip: 'Stop all', onPressed: onStopAll),
              _ActionIcon(icon: LucideIcons.trash2, tooltip: 'Delete all', onPressed: onRemoveAll),
            ],
          ),
        ),
        if (expanded)
          for (final container in containers)
            _ContainerTile(
              container: container,
              theme: theme,
              selected: selectedId == container.id,
              indented: true,
              onStart: () => onStart(container.id),
              onStop: () => onStop(container.id),
              onRemove: () => onRemove(container.id),
              onOpen: () => onOpen(container),
              onOpenPort: onOpenPort,
            ),
      ],
    );
  }
}

class _ContainerTile extends StatelessWidget {
  const _ContainerTile({
    required this.container,
    required this.theme,
    required this.selected,
    required this.onStart,
    required this.onStop,
    required this.onRemove,
    required this.onOpen,
    required this.onOpenPort,
    this.indented = false,
  });

  final ContainerItem container;
  final ShadThemeData theme;
  final bool selected;
  final bool indented;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onRemove;
  final VoidCallback onOpen;
  final void Function(int port) onOpenPort;

  @override
  Widget build(BuildContext context) {
    final port = container.primaryHostPort;

    return HoverListRow(
      theme: theme,
      selected: selected,
      padding: EdgeInsets.fromLTRB(indented ? 52 : 8, 10, 8, 10),
      child: Row(
        children: [
          _ContainerStatusIcon(container: container, theme: theme),
          SizedBox(width: indented ? 16 : 12),
          Expanded(
            child: GestureDetector(
              onTap: onOpen,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: EdgeInsets.only(left: indented ? 12 : 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(container.displayName, style: theme.textTheme.large, overflow: TextOverflow.ellipsis),
                    Text(
                      container.subtitle,
                      style: theme.textTheme.small.copyWith(color: theme.colorScheme.mutedForeground),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (port != null)
            _ActionIcon(
              icon: LucideIcons.externalLink,
              tooltip: 'Open localhost:$port',
              onPressed: () => onOpenPort(port),
            ),
          if (container.isRunning)
            _ActionIcon(icon: LucideIcons.square, tooltip: 'Stop', onPressed: onStop)
          else
            _ActionIcon(icon: LucideIcons.play, tooltip: 'Start', onPressed: onStart),
          _ActionIcon(icon: LucideIcons.trash2, tooltip: 'Delete', onPressed: onRemove),
        ],
      ),
    );
  }
}

class _ComposeStackIcon extends StatelessWidget {
  const _ComposeStackIcon({
    required this.containers,
    required this.theme,
  });

  final List<ContainerItem> containers;
  final ShadThemeData theme;

  @override
  Widget build(BuildContext context) {
    return _StatusDotIcon(
      icon: LucideIcons.layers,
      iconColor: theme.colorScheme.primary,
      statusColor: _groupStatusColor(containers, theme),
      theme: theme,
    );
  }
}

class _ContainerStatusIcon extends StatelessWidget {
  const _ContainerStatusIcon({
    required this.container,
    required this.theme,
  });

  final ContainerItem container;
  final ShadThemeData theme;

  @override
  Widget build(BuildContext context) {
    return _StatusDotIcon(
      icon: LucideIcons.box,
      iconColor: theme.colorScheme.mutedForeground,
      statusColor: _containerStatusColor(container, theme),
      theme: theme,
    );
  }
}

class _StatusDotIcon extends StatelessWidget {
  const _StatusDotIcon({
    required this.icon,
    required this.iconColor,
    required this.statusColor,
    required this.theme,
  });

  final IconData icon;
  final Color iconColor;
  final Color statusColor;
  final ShadThemeData theme;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(icon, size: 22, color: iconColor),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
                border: Border.all(color: theme.colorScheme.background, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Color _containerStatusColor(ContainerItem container, ShadThemeData theme) {
  if (container.isRunning) {
    return const Color(0xFF2DBE60);
  }
  if (container.state == 'created') {
    return const Color(0xFFF0A500);
  }
  return theme.colorScheme.mutedForeground;
}

Color _groupStatusColor(List<ContainerItem> containers, ShadThemeData theme) {
  if (containers.any((container) => container.isRunning)) {
    return const Color(0xFF2DBE60);
  }
  if (containers.any((container) => container.state == 'created')) {
    return const Color(0xFFF0A500);
  }
  return theme.colorScheme.mutedForeground;
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: CalfButton.ghost(
        width: 32,
        height: 32,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        child: Icon(icon, size: 16),
      ),
    );
  }
}
