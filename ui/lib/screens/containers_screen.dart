import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/screens/compose_group_detail_screen.dart';
import 'package:ui/screens/container_detail_screen.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/poll_interval_mixin.dart';
import 'package:ui/widgets/running_filter_switch.dart';
import 'package:ui/storage/container_groups.dart';

class ContainersScreen extends StatefulWidget {
  /// Creates a [ContainersScreen] widget.
  const ContainersScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

  /// Creates the mutable state for [ContainersScreen].
  @override
  State<ContainersScreen> createState() => _ContainersScreenState();
}

class _ContainersScreenState extends State<ContainersScreen>
    with PollIntervalMixin {
  List<ContainerItem> _containers = [];
  RuntimeStatus? _runtime;
  String? _error;
  bool _loading = true;
  bool _refreshInFlight = false;
  String? _selectedId;
  ContainerItem? _detailContainer;
  String? _detailProject;
  List<ContainerItem>? _detailGroupContainers;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  bool _runningOnly = false;
  final Map<String, bool> _expandedGroups = {};

  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    _loadGroupPreferences();
    _loadContainers();
    startPollInterval(widget.apiClient, _loadContainers);
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

  /// Fetches runtime status and containers, optionally skipping the loading indicator.
  Future<void> _loadContainers({bool silent = false}) async {
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
        if (_detailProject != null) {
          _detailGroupContainers = containers
              .where((container) => container.composeProject == _detailProject)
              .toList();
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
    } finally {
      _refreshInFlight = false;
    }
  }

  /// Runs the given async action and refreshes the list on success.
  Future<void> _runAction(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) {
        setState(() => _error = null);
      }
      await _loadContainers();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  /// Runs an action across the given containers, filtered by running state.
  Future<void> _runGroupAction(
    List<ContainerItem> containers,
    Future<void> Function(String id) action, {
    bool runningOnly = false,
    bool stoppedOnly = false,
  }) async {
    try {
      for (final container in containers) {
        if (runningOnly && !container.isRunning) {
          continue;
        }
        if (stoppedOnly && container.isRunning) {
          continue;
        }
        await action(container.id);
      }
      if (mounted) {
        setState(() => _error = null);
      }
      await _loadContainers();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  /// Navigates to or opens the selected container.
  void _openContainer(ContainerItem container) {
    setState(() {
      _detailContainer = container;
      _selectedId = container.id;
    });
  }

  /// Opens the compose project group detail view.
  void _openComposeGroup(String project, List<ContainerItem> containers) {
    setState(() {
      _detailProject = project;
      _detailGroupContainers = List<ContainerItem>.from(containers);
      _detailContainer = null;
      _selectedId = null;
    });
  }

  /// Closes the current detail view and returns to the list.
  void _closeContainerDetail() {
    setState(() {
      _detailContainer = null;
      _selectedId = null;
    });
  }

  /// Closes the current detail view and returns to the list.
  void _closeComposeGroup() {
    setState(() {
      _detailProject = null;
      _detailGroupContainers = null;
    });
  }

  /// Loads persisted compose-group expand/collapse state.
  Future<void> _loadGroupPreferences() async {
    final saved = await ContainerGroupPreferences.loadExpanded();
    if (!mounted) {
      return;
    }
    setState(() => _expandedGroups.addAll(saved));
  }

  /// Returns whether the compose group [project] is expanded in the list.
  bool _isGroupExpanded(String project) => _expandedGroups[project] ?? false;

  /// Toggles the corresponding UI state.
  void _toggleGroup(String project) {
    setState(() {
      _expandedGroups[project] = !(_expandedGroups[project] ?? false);
    });
    ContainerGroupPreferences.saveExpanded(_expandedGroups);
  }

  /// Returns items matching the active search and filter criteria.
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

  /// Groups containers into compose projects and standalone rows.
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
      groups: sortedProjects
          .map(
            (project) => MapEntry(
              project,
              groups[project]!
                ..sort((a, b) => a.displayName.compareTo(b.displayName)),
            ),
          )
          .toList(),
      standalone: standalone,
    );
  }

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    if (_detailContainer != null) {
      return ContainerDetailView(
        key: ValueKey(_detailContainer!.id),
        container: _detailContainer!,
        apiClient: widget.apiClient,
        onBack: _closeContainerDetail,
        onChanged: _loadContainers,
      );
    }

    if (_detailProject != null && _detailGroupContainers != null) {
      return ComposeGroupDetailView(
        key: ValueKey(_detailProject),
        project: _detailProject!,
        containers: _detailGroupContainers!,
        apiClient: widget.apiClient,
        onBack: _closeComposeGroup,
        onChanged: _loadContainers,
        onOpenContainer: _openContainer,
      );
    }

    final theme = ShadTheme.of(context);
    final filtered = _filteredContainers();
    final layout = _buildLayout(filtered);
    final runningCount = _containers
        .where((container) => container.isRunning)
        .length;
    final isEmpty = layout.groups.isEmpty && layout.standalone.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Containers', style: theme.textTheme.h3),

            /// Creates a [_ContainersScreenState] widget.
            const SizedBox(width: 12),
            Text(
              '$runningCount running / ${_containers.length} total',
              style: theme.textTheme.muted,
            ),
          ],
        ),

        /// Creates a [_ContainersScreenState] widget.
        const SizedBox(height: 16),
        ShadInput(
          controller: _searchController,
          placeholder: const Text('Search'),
          leading: Icon(
            LucideIcons.search,
            size: 16,
            color: theme.colorScheme.mutedForeground,
          ),
        ),

        /// Creates a [_ContainersScreenState] widget.
        const SizedBox(height: 12),
        RunningFilterSwitch(
          value: _runningOnly,
          onChanged: (value) => setState(() => _runningOnly = value),
        ),

        /// Creates a [_ContainersScreenState] widget.
        const SizedBox(height: 16),
        if (_runtime?.portConflicts.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _runtime!.portConflicts
                  .map((conflict) => conflict.hint)
                  .join('\n'),
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.destructive,
              ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _error!,
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.destructive,
              ),
            ),
          ),
        if (_loading)
          Text('Loading...', style: theme.textTheme.large)
        else if (isEmpty)
          Expanded(
            child: Center(
              child: Text(
                _searchQuery.isNotEmpty
                    ? 'No containers match "$_searchQuery".'
                    : _runtime?.state == 'stopped'
                    ? 'No containers. Runtime is stopped.'
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
                    onOpenGroup: () =>
                        _openComposeGroup(group.key, group.value),
                    onStart: (id) =>
                        _runAction(() => widget.apiClient.startContainer(id)),
                    onStop: (id) =>
                        _runAction(() => widget.apiClient.stopContainer(id)),
                    onRemove: (id) =>
                        _runAction(() => widget.apiClient.removeContainer(id)),
                    onStopAll: () => _runGroupAction(
                      group.value,
                      widget.apiClient.stopContainer,
                      runningOnly: true,
                    ),
                    onRemoveAll: () => _runGroupAction(
                      group.value,
                      widget.apiClient.removeContainer,
                    ),
                    onOpen: _openContainer,
                    onOpenPort: openPort,
                  ),
                for (final container in layout.standalone)
                  _ContainerTile(
                    container: container,
                    theme: theme,
                    selected: _selectedId == container.id,
                    onStart: () => _runAction(
                      () => widget.apiClient.startContainer(container.id),
                    ),
                    onStop: () => _runAction(
                      () => widget.apiClient.stopContainer(container.id),
                    ),
                    onRemove: () => _runAction(
                      () => widget.apiClient.removeContainer(container.id),
                    ),
                    onOpen: () => _openContainer(container),
                    onOpenPort: openPort,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ContainerLayout {
  /// Creates a [_ContainerLayout] widget.
  const _ContainerLayout({required this.groups, required this.standalone});

  final List<MapEntry<String, List<ContainerItem>>> groups;
  final List<ContainerItem> standalone;
}

class _ComposeGroupTile extends StatelessWidget {
  /// Creates a [_ComposeGroupTile] widget.
  const _ComposeGroupTile({
    required this.project,
    required this.containers,
    required this.theme,
    required this.expanded,
    required this.selectedId,
    required this.onToggle,
    required this.onOpenGroup,
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
  final VoidCallback onOpenGroup;
  final Future<void> Function(String id) onStart;
  final Future<void> Function(String id) onStop;
  final Future<void> Function(String id) onRemove;
  final VoidCallback onStopAll;
  final VoidCallback onRemoveAll;
  final void Function(ContainerItem container) onOpen;
  final void Function(int port) onOpenPort;

  /// Builds the widget tree for the current screen state.
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
                child: Icon(
                  expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                  size: 16,
                ),
              ),

              /// Creates a [_ComposeGroupTile] widget.
              const SizedBox(width: 4),
              Expanded(
                child: GestureDetector(
                  onTap: onOpenGroup,
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: [
                      _ComposeStackIcon(containers: containers, theme: theme),

                      /// Creates a [_ComposeGroupTile] widget.
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(project, style: theme.textTheme.large),
                            Text(
                              '$running running / ${containers.length} total',
                              style: theme.textTheme.small.copyWith(
                                color: theme.colorScheme.mutedForeground,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _ActionIcon(
                icon: LucideIcons.square,
                tooltip: 'Stop all',
                onPressed: onStopAll,
              ),
              _ActionIcon(
                icon: LucideIcons.trash2,
                tooltip: 'Delete all',
                onPressed: onRemoveAll,
              ),
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
  /// Creates a [_ContainerTile] widget.
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

  /// Builds the widget tree for the current screen state.
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
                    Text(
                      container.displayName,
                      style: theme.textTheme.large,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      container.subtitle,
                      style: theme.textTheme.small.copyWith(
                        color: theme.colorScheme.mutedForeground,
                      ),
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
            _ActionIcon(
              icon: LucideIcons.square,
              tooltip: 'Stop',
              onPressed: onStop,
            )
          else
            _ActionIcon(
              icon: LucideIcons.play,
              tooltip: 'Start',
              onPressed: onStart,
            ),
          _ActionIcon(
            icon: LucideIcons.trash2,
            tooltip: 'Delete',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _ComposeStackIcon extends StatelessWidget {
  /// Creates a [_ComposeStackIcon] widget.
  const _ComposeStackIcon({required this.containers, required this.theme});

  final List<ContainerItem> containers;
  final ShadThemeData theme;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(LucideIcons.layers, size: 22, color: theme.colorScheme.primary),
          Positioned(
            right: 0,
            bottom: 0,
            child: _GroupStatusDot(
              state: _groupRunState(containers),
              theme: theme,
            ),
          ),
        ],
      ),
    );
  }
}

class _ContainerStatusIcon extends StatelessWidget {
  /// Creates a [_ContainerStatusIcon] widget.
  const _ContainerStatusIcon({required this.container, required this.theme});

  final ContainerItem container;
  final ShadThemeData theme;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return _StatusDotIcon(
      icon: LucideIcons.box,
      iconColor: theme.colorScheme.mutedForeground,
      fillColor: _containerStatusColor(container, theme),
      theme: theme,
    );
  }
}

class _StatusDotIcon extends StatelessWidget {
  /// Creates a [_StatusDotIcon] widget.
  const _StatusDotIcon({
    required this.icon,
    required this.iconColor,
    required this.fillColor,
    required this.theme,
  });

  final IconData icon;
  final Color iconColor;
  final Color? fillColor;
  final ShadThemeData theme;

  static const _dotSize = 9.0;
  static const _borderWidth = 1.5;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final borderColor = fillColor != null
        ? theme.colorScheme.background
        : theme.colorScheme.mutedForeground;

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
              width: _dotSize,
              height: _dotSize,
              decoration: BoxDecoration(
                color: fillColor,
                shape: BoxShape.circle,
                border: Border.all(color: borderColor, width: _borderWidth),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Returns the status color for the given container.
Color? _containerStatusColor(ContainerItem container, ShadThemeData theme) {
  if (container.isRunning) {
    return CalfColors.success;
  }
  if (container.state == 'created') {
    return CalfColors.warning;
  }
  return null;
}

enum _GroupRunState { allRunning, partial, stopped }

/// Returns whether the condition holds for the given input.
bool _isTransitionalContainer(ContainerItem container) {
  final state = container.state.toLowerCase();
  if (state == 'created' || state == 'restarting') {
    return true;
  }
  return container.status.toLowerCase().contains('restarting');
}

/// Returns whether the condition holds for the given input.
bool _isStoppedContainer(ContainerItem container) {
  return !container.isRunning && !_isTransitionalContainer(container);
}

/// Derives the aggregate run state for a compose group.
_GroupRunState _groupRunState(List<ContainerItem> containers) {
  final runningCount = containers
      .where((container) => container.isRunning)
      .length;
  if (runningCount == containers.length) {
    return _GroupRunState.allRunning;
  }

  final hasStopped = containers.any(_isStoppedContainer);
  final hasTransitional = containers.any(_isTransitionalContainer);

  if (runningCount > 0 || (hasStopped && hasTransitional)) {
    return _GroupRunState.partial;
  }

  return _GroupRunState.stopped;
}

class _GroupStatusDot extends StatelessWidget {
  /// Creates a [_GroupStatusDot] widget.
  const _GroupStatusDot({required this.state, required this.theme});

  final _GroupRunState state;
  final ShadThemeData theme;

  static const _dotSize = 9.0;
  static const _borderWidth = 1.5;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final background = theme.colorScheme.background;
    final borderColor = theme.colorScheme.mutedForeground;

    return SizedBox(
      width: _dotSize,
      height: _dotSize,
      child: switch (state) {
        _GroupRunState.allRunning => Container(
          decoration: BoxDecoration(
            color: CalfColors.success,
            shape: BoxShape.circle,
            border: Border.all(color: background, width: _borderWidth),
          ),
        ),
        _GroupRunState.stopped => Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: borderColor, width: _borderWidth),
          ),
        ),
        _GroupRunState.partial => CustomPaint(
          painter: _HalfFilledCirclePainter(
            fillColor: theme.colorScheme.primary,
            borderColor: borderColor,
            borderWidth: _borderWidth,
          ),
        ),
      },
    );
  }
}

class _HalfFilledCirclePainter extends CustomPainter {
  /// Creates a [_HalfFilledCirclePainter] widget.
  const _HalfFilledCirclePainter({
    required this.fillColor,
    required this.borderColor,
    required this.borderWidth,
  });

  final Color fillColor;
  final Color borderColor;
  final double borderWidth;

  /// Draws the custom painter content onto [canvas].
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - borderWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    canvas.drawArc(rect, math.pi / 2, math.pi, true, fillPaint);

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;
    canvas.drawCircle(center, radius, borderPaint);
  }

  /// Returns whether this painter should repaint.
  @override
  bool shouldRepaint(covariant _HalfFilledCirclePainter oldDelegate) {
    return fillColor != oldDelegate.fillColor ||
        borderColor != oldDelegate.borderColor ||
        borderWidth != oldDelegate.borderWidth;
  }
}

class _ActionIcon extends StatelessWidget {
  /// Creates a [_ActionIcon] widget.
  const _ActionIcon({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  /// Builds the widget tree for the current screen state.
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
