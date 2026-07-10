import 'dart:async';

import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/logs_panel.dart';

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
    final theme = ShadTheme.of(context);
    final running = _containers
        .where((container) => container.isRunning)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CalfButton.ghost(
              onPressed: widget.onBack,
              child: Icon(
                LucideIcons.chevronLeft,
                size: 18,
                color: theme.colorScheme.foreground,
              ),
            ),
            /// Creates a [_ComposeGroupDetailViewState] widget.
            const SizedBox(width: 4),
            Text('Containers', style: theme.textTheme.muted),
            Text(' / ', style: theme.textTheme.muted),
            Icon(
              LucideIcons.layers,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            /// Creates a [_ComposeGroupDetailViewState] widget.
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.project, style: theme.textTheme.h3),
                  Text(
                    '$running running / ${_containers.length} total',
                    style: theme.textTheme.small.copyWith(
                      color: theme.colorScheme.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
            CalfButton.outline(
              enabled: !_busy && running > 0,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: running > 0
                  ? () => _runGroupAction(
                      widget.apiClient.stopContainer,
                      runningOnly: true,
                    )
                  : null,
              child: Icon(
                LucideIcons.square,
                size: 16,
                color: theme.colorScheme.foreground,
              ),
            ),
            /// Creates a [_ComposeGroupDetailViewState] widget.
            const SizedBox(width: 8),
            CalfButton(
              enabled: !_busy && running < _containers.length,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: running < _containers.length
                  ? () => _runGroupAction(
                      widget.apiClient.startContainer,
                      stoppedOnly: true,
                    )
                  : null,
              child: Icon(
                LucideIcons.play,
                size: 16,
                color: theme.colorScheme.primaryForeground,
              ),
            ),
            /// Creates a [_ComposeGroupDetailViewState] widget.
            const SizedBox(width: 8),
            CalfButton.destructive(
              enabled: !_busy,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: () async {
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
                color: theme.colorScheme.destructiveForeground,
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          /// Creates a [_ComposeGroupDetailViewState] widget.
          const SizedBox(height: 12),
          Text(
            _error!,
            style: theme.textTheme.small.copyWith(
              color: theme.colorScheme.destructive,
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
                  onRemove: (id) =>
                      _runAction(() => widget.apiClient.removeContainer(id)),
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

  final ShadThemeData theme;
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
        border: Border.all(color: theme.colorScheme.border),
        borderRadius: theme.radius,
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

  final ShadThemeData theme;
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
                  : theme.colorScheme.mutedForeground,
              shape: BoxShape.circle,
              border: container.isRunning
                  ? null
                  : Border.all(color: theme.colorScheme.mutedForeground),
            ),
          ),
          /// Creates a [_ComposeContainerRow] widget.
          const SizedBox(width: 10),
          Icon(
            LucideIcons.box,
            size: 18,
            color: theme.colorScheme.mutedForeground,
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
                  if (port != null) ...[
                    /// Creates a [_ComposeContainerRow] widget.
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () => onOpenPort(port),
                      child: Text(
                        '$port:$port',
                        style: theme.textTheme.small.copyWith(
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
