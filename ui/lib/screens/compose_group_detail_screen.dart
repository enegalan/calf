import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/confirm_dialog.dart';
import 'package:ui/widgets/detail_breadcrumb.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/logs_panel.dart';
import 'package:ui/theme/calf_theme.dart';

const _maxLogLines = 2000;

const _mixedLogColors = [
  Color(0xFFE91E8C),
  Color(0xFF9B5DE5),
  Color(0xFF00BBF9),
  Color(0xFF00F5D4),
  Color(0xFFFEE440),
  Color(0xFFF15BB5),
];

class ComposeGroupDetailView extends StatefulWidget {
  /// Creates a [ComposeGroupDetailView] widget.
  const ComposeGroupDetailView({
    super.key,
    required this.project,
    required this.containers,
    required this.apiClient,
    required this.onBack,
    required this.onChanged,
    required this.onOpenContainer,
  });

  final String project;
  final List<ContainerItem> containers;
  final CalfClient apiClient;
  final VoidCallback onBack;
  final Future<void> Function() onChanged;
  final void Function(ContainerItem container) onOpenContainer;

  /// Creates the mutable state for [ComposeGroupDetailView].
  @override
  State<ComposeGroupDetailView> createState() => _ComposeGroupDetailViewState();
}

class _ComposeGroupDetailViewState extends State<ComposeGroupDetailView> {
  late List<ContainerItem> _containers;
  final List<MixedLogBlock> _mixedLogBlocks = [];
  final Map<String, StreamSubscription<String>> _logSubscriptions = {};
  final Set<String> _subscribedContainerIds = {};
  final Map<String, Color> _containerColors = {};
  final _logsScrollController = ScrollController();
  String? _error;
  bool _busy = false;

  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    _containers = List<ContainerItem>.from(widget.containers)
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    _assignColors();
    _syncMixedLogs();
  }

  /// Refreshes local state when the parent widget changes.
  @override
  void didUpdateWidget(covariant ComposeGroupDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _containers = List<ContainerItem>.from(widget.containers)
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    _assignColors();

    final oldRunning = oldWidget.containers
        .where((container) => container.isRunning)
        .map((container) => container.id)
        .toSet();
    final newRunning = _containers
        .where((container) => container.isRunning)
        .map((container) => container.id)
        .toSet();
    if (oldRunning != newRunning) {
      _syncMixedLogs();
    }
  }

  /// Releases controllers, timers, and stream subscriptions.
  @override
  void dispose() {
    _stopMixedLogs();
    _logsScrollController.dispose();
    super.dispose();
  }

  /// Assigns display colors to child containers.
  void _assignColors() {
    _containerColors.clear();
    for (var index = 0; index < _containers.length; index++) {
      _containerColors[_containers[index].id] =
          _mixedLogColors[index % _mixedLogColors.length];
    }
  }

  /// Stops background polling or streaming work.
  void _stopMixedLogs() {
    for (final subscription in _logSubscriptions.values) {
      subscription.cancel();
    }
    _logSubscriptions.clear();
    _subscribedContainerIds.clear();
  }

  /// Synchronizes subscriptions with currently running containers.
  void _syncMixedLogs() {
    final running = _containers
        .where((container) => container.isRunning)
        .toList();
    final runningIds = running.map((container) => container.id).toSet();

    for (final id in _subscribedContainerIds.toList()) {
      if (runningIds.contains(id)) {
        continue;
      }
      _logSubscriptions[id]?.cancel();
      _logSubscriptions.remove(id);
      _subscribedContainerIds.remove(id);
    }

    for (final container in running) {
      if (_subscribedContainerIds.contains(container.id)) {
        continue;
      }

      final color = _containerColors[container.id] ?? _mixedLogColors.first;
      final logsStream = widget.apiClient.streamContainerLogs(container.id);
      _subscribedContainerIds.add(container.id);
      _logSubscriptions[container.id] = logsStream.listen(
        (line) => _appendLogLine(container, color, line),
        onError: (error) =>
            _appendLogLine(container, color, 'Failed to stream logs: $error'),
        onDone: () {
          _subscribedContainerIds.remove(container.id);
          _logSubscriptions.remove(container.id);
        },
      );
    }
  }

  /// Drops oldest log lines when the mixed buffer exceeds [_maxLogLines].
  void _trimMixedLogBlocks() {
    var total = 0;
    for (final block in _mixedLogBlocks) {
      total += block.lines.length;
    }
    if (total <= _maxLogLines) {
      return;
    }

    var toRemove = total - _maxLogLines;
    while (toRemove > 0 && _mixedLogBlocks.isNotEmpty) {
      final first = _mixedLogBlocks.first;
      if (first.lines.length <= toRemove) {
        toRemove -= first.lines.length;
        _mixedLogBlocks.removeAt(0);
      } else {
        _mixedLogBlocks[0] = first.copyWith(
          lines: first.lines.sublist(toRemove),
        );
        toRemove = 0;
      }
    }
  }

  /// Appends a value to the rolling history buffer.
  void _appendLogLine(ContainerItem container, Color color, String line) {
    if (!mounted) {
      return;
    }

    setState(() {
      final entry = LogLine(text: line, receivedAt: DateTime.now());
      if (_mixedLogBlocks.isNotEmpty &&
          _mixedLogBlocks.last.containerId == container.id &&
          _mixedLogBlocks.last.color == color) {
        final last = _mixedLogBlocks.last;
        _mixedLogBlocks[_mixedLogBlocks.length - 1] = last.copyWith(
          lines: [...last.lines, entry],
        );
      } else {
        _mixedLogBlocks.add(
          MixedLogBlock(
            containerId: container.id,
            containerName: container.displayName,
            color: color,
            lines: [entry],
          ),
        );
      }
      _trimMixedLogBlocks();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logsScrollController.hasClients) {
        _logsScrollController.jumpTo(
          _logsScrollController.position.maxScrollExtent,
        );
      }
    });
  }

  /// Runs the given async action and refreshes the list on success.
  Future<bool> _runAction(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await action();
      await widget.onChanged();
      if (!mounted) {
        return false;
      }
      setState(() => _busy = false);
      return true;
    } catch (error) {
      if (!mounted) {
        return false;
      }
      setState(() {
        _busy = false;
        _error = error.toString();
      });
      return false;
    }
  }

  /// Runs an action across compose group containers, filtered by running state.
  Future<bool> _runGroupAction(
    Future<void> Function(String id) action, {
    bool runningOnly = false,
    bool stoppedOnly = false,
  }) async {
    return _runAction(() async {
      for (final container in _containers) {
        if (runningOnly && !container.isRunning) {
          continue;
        }
        if (stoppedOnly && container.isRunning) {
          continue;
        }
        await action(container.id);
      }
    });
  }

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = _containers
        .where((container) => container.isRunning)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailBreadcrumb(
          segments: ['Containers', widget.project],
          onBack: widget.onBack,
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              LucideIcons.layers,
              size: 28,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.project, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text(
                    '$running running / ${_containers.length} total',
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            CalfButtonGroup(
              actions: [
                CalfGroupAction(
                  icon: LucideIcons.square,
                  tooltip: 'Stop all',
                  enabled: !_busy && running > 0,
                  onPressed: () => _runGroupAction(
                    widget.apiClient.stopContainer,
                    runningOnly: true,
                  ),
                ),
                CalfGroupAction(
                  icon: LucideIcons.play,
                  tooltip: 'Start all',
                  enabled: !_busy && running < _containers.length,
                  onPressed: () => _runGroupAction(
                    widget.apiClient.startContainer,
                    stoppedOnly: true,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 8),
            CalfButton.destructive(
              enabled: !_busy,
              width: 40,
              height: 40,
              onPressed: () async {
                final confirmed = await confirmDialog(
                  context,
                  title: 'Delete all containers',
                  description:
                      'Delete ${_containers.length} containers in "${widget.project}"? This cannot be undone.',
                  confirmLabel: 'Delete all',
                  destructive: true,
                );
                if (!confirmed || !mounted) {
                  return;
                }
                final ok = await _runGroupAction(
                  widget.apiClient.removeContainer,
                );
                if (mounted && ok) {
                  widget.onBack();
                }
              },
              child: Icon(
                LucideIcons.trash2,
                size: 16,
                color: theme.colorScheme.onError,
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          /// Creates a [_ComposeGroupDetailViewState] widget.
          const SizedBox(height: 12),
          Text(
            _error!,
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],

        /// Creates a [_ComposeGroupDetailViewState] widget.
        const SizedBox(height: 16),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 320,
                child: _ComposeContainerList(
                  theme: theme,
                  containers: _containers,
                  colors: _containerColors,
                  onOpen: widget.onOpenContainer,
                  onStart: (id) =>
                      _runAction(() => widget.apiClient.startContainer(id)),
                  onStop: (id) =>
                      _runAction(() => widget.apiClient.stopContainer(id)),
                  onRemove: (id) async {
                    final match = _containers
                        .where((c) => c.id == id)
                        .firstOrNull;
                    if (match == null) {
                      return;
                    }
                    final confirmed = await confirmDialog(
                      context,
                      title: 'Delete container',
                      description:
                          'Delete "${match.name}"? This cannot be undone.',
                      confirmLabel: 'Delete',
                      destructive: true,
                    );
                    if (!confirmed || !mounted) {
                      return;
                    }
                    await _runAction(
                      () => widget.apiClient.removeContainer(id),
                    );
                  },
                  onOpenPort: openPort,
                  busy: _busy,
                ),
              ),

              /// Creates a [_ComposeGroupDetailViewState] widget.
              const SizedBox(width: 16),
              Expanded(
                child: MixedLogsPanel(
                  blocks: _mixedLogBlocks,
                  scrollController: _logsScrollController,
                  runningCount: running,
                  onClear: () => setState(_mixedLogBlocks.clear),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ComposeContainerList extends StatelessWidget {
  /// Creates a [_ComposeContainerList] widget.
  const _ComposeContainerList({
    required this.theme,
    required this.containers,
    required this.colors,
    required this.onOpen,
    required this.onStart,
    required this.onStop,
    required this.onRemove,
    required this.onOpenPort,
    required this.busy,
  });

  final ThemeData theme;
  final List<ContainerItem> containers;
  final Map<String, Color> colors;
  final void Function(ContainerItem container) onOpen;
  final Future<void> Function(String id) onStart;
  final Future<void> Function(String id) onStop;
  final Future<void> Function(String id) onRemove;
  final void Function(int port) onOpenPort;
  final bool busy;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: CalfTheme.radius,
        color: logsPanelBackground(theme),
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (final container in containers)
            _ComposeContainerRow(
              theme: theme,
              container: container,
              accentColor: colors[container.id] ?? theme.colorScheme.primary,
              onOpen: () => onOpen(container),
              onStart: () => onStart(container.id),
              onStop: () => onStop(container.id),
              onRemove: () => onRemove(container.id),
              onOpenPort: onOpenPort,
              busy: busy,
            ),
        ],
      ),
    );
  }
}

class _ComposeContainerRow extends StatelessWidget {
  /// Creates a [_ComposeContainerRow] widget.
  const _ComposeContainerRow({
    required this.theme,
    required this.container,
    required this.accentColor,
    required this.onOpen,
    required this.onStart,
    required this.onStop,
    required this.onRemove,
    required this.onOpenPort,
    required this.busy,
  });

  final ThemeData theme;
  final ContainerItem container;
  final Color accentColor;
  final VoidCallback onOpen;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onRemove;
  final void Function(int port) onOpenPort;
  final bool busy;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final port = container.primaryHostPort;

    return HoverListRow(
      theme: theme,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: container.isRunning
                  ? accentColor
                  : theme.colorScheme.onSurfaceVariant,
              shape: BoxShape.circle,
              border: container.isRunning
                  ? null
                  : Border.all(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),

          /// Creates a [_ComposeContainerRow] widget.
          const SizedBox(width: 10),
          Icon(
            LucideIcons.box,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),

          /// Creates a [_ComposeContainerRow] widget.
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: onOpen,
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    container.displayName,
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    container.subtitle,
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (port != null) ...[
                    /// Creates a [_ComposeContainerRow] widget.
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () => onOpenPort(port),
                      child: Text(
                        'localhost:$port',
                        style: theme.textTheme.bodySmall!.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (container.isRunning)
            _ComposeActionIcon(
              icon: LucideIcons.square,
              tooltip: 'Stop',
              enabled: !busy,
              onPressed: onStop,
            )
          else
            _ComposeActionIcon(
              icon: LucideIcons.play,
              tooltip: 'Start',
              enabled: !busy,
              onPressed: onStart,
            ),
          _ComposeActionIcon(
            icon: LucideIcons.trash2,
            tooltip: 'Delete',
            enabled: !busy,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _ComposeActionIcon extends StatelessWidget {
  /// Creates a [_ComposeActionIcon] widget.
  const _ComposeActionIcon({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool enabled;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: CalfButton.ghost(
        enabled: enabled,
        width: 32,
        height: 32,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        child: Icon(icon, size: 16),
      ),
    );
  }
}
