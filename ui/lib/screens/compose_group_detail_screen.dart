import 'dart:async';
import 'dart:io' show Platform, Process;

import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
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

  @override
  void initState() {
    super.initState();
    _containers = List<ContainerItem>.from(widget.containers)
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    _assignColors();
    _syncMixedLogs();
  }

  @override
  void didUpdateWidget(covariant ComposeGroupDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _containers = List<ContainerItem>.from(widget.containers)
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    _assignColors();

    final oldRunning = oldWidget.containers.where((container) => container.isRunning).map((container) => container.id).toSet();
    final newRunning = _containers.where((container) => container.isRunning).map((container) => container.id).toSet();
    if (oldRunning != newRunning) {
      _syncMixedLogs();
    }
  }

  @override
  void dispose() {
    _stopMixedLogs();
    _logsScrollController.dispose();
    super.dispose();
  }

  void _assignColors() {
    _containerColors.clear();
    for (var index = 0; index < _containers.length; index++) {
      _containerColors[_containers[index].id] = _mixedLogColors[index % _mixedLogColors.length];
    }
  }

  void _stopMixedLogs() {
    for (final subscription in _logSubscriptions.values) {
      subscription.cancel();
    }
    _logSubscriptions.clear();
    _subscribedContainerIds.clear();
  }

  void _syncMixedLogs() {
    final running = _containers.where((container) => container.isRunning).toList();
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
        onError: (error) => _appendLogLine(
          container,
          color,
          'Failed to stream logs: $error',
        ),
        onDone: () {
          _subscribedContainerIds.remove(container.id);
          _logSubscriptions.remove(container.id);
        },
      );
    }
  }

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
        _mixedLogBlocks[_mixedLogBlocks.length - 1] = last.copyWith(lines: [...last.lines, entry]);
      } else {
        _mixedLogBlocks.add(MixedLogBlock(
          containerId: container.id,
          containerName: container.displayName,
          color: color,
          lines: [entry],
        ));
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logsScrollController.hasClients) {
        _logsScrollController.jumpTo(_logsScrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _runAction(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await action();
      await widget.onChanged();
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _runGroupAction(Future<void> Function(String id) action) async {
    await _runAction(() async {
      for (final container in _containers) {
        await action(container.id);
      }
    });
  }

  void _openPort(int port) {
    if (!Platform.isMacOS) {
      return;
    }
    Process.run('open', ['http://localhost:$port']);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final running = _containers.where((container) => container.isRunning).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CalfButton.ghost(
              onPressed: widget.onBack,
              child: Icon(LucideIcons.chevronLeft, size: 18, color: theme.colorScheme.foreground),
            ),
            const SizedBox(width: 4),
            Text('Containers', style: theme.textTheme.muted),
            Text(' / ', style: theme.textTheme.muted),
            Icon(LucideIcons.layers, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.project, style: theme.textTheme.h3),
                  Text(
                    '$running running / ${_containers.length} total',
                    style: theme.textTheme.small.copyWith(color: theme.colorScheme.mutedForeground),
                  ),
                ],
              ),
            ),
            CalfButton.outline(
              enabled: !_busy && running > 0,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: running > 0 ? () => _runGroupAction(widget.apiClient.stopContainer) : null,
              child: Icon(LucideIcons.square, size: 16, color: theme.colorScheme.foreground),
            ),
            const SizedBox(width: 8),
            CalfButton(
              enabled: !_busy && running < _containers.length,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: running < _containers.length
                  ? () => _runGroupAction(widget.apiClient.startContainer)
                  : null,
              child: Icon(LucideIcons.play, size: 16, color: theme.colorScheme.primaryForeground),
            ),
            const SizedBox(width: 8),
            CalfButton.destructive(
              enabled: !_busy,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: () async {
                await _runGroupAction(widget.apiClient.removeContainer);
                if (mounted) {
                  widget.onBack();
                }
              },
              child: Icon(LucideIcons.trash2, size: 16, color: theme.colorScheme.destructiveForeground),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive)),
        ],
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
                  onStart: (id) => _runAction(() => widget.apiClient.startContainer(id)),
                  onStop: (id) => _runAction(() => widget.apiClient.stopContainer(id)),
                  onRemove: (id) => _runAction(() => widget.apiClient.removeContainer(id)),
                  onOpenPort: _openPort,
                  busy: _busy,
                ),
              ),
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

  @override
  Widget build(BuildContext context) {
    final port = container.primaryHostPort;

    return HoverListRow(
      theme: theme,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: onOpen,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: container.isRunning ? accentColor : theme.colorScheme.mutedForeground,
              shape: BoxShape.circle,
              border: container.isRunning ? null : Border.all(color: theme.colorScheme.mutedForeground),
            ),
          ),
          const SizedBox(width: 10),
          Icon(LucideIcons.box, size: 18, color: theme.colorScheme.mutedForeground),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(container.displayName, style: theme.textTheme.large, overflow: TextOverflow.ellipsis),
                Text(
                  container.subtitle,
                  style: theme.textTheme.small.copyWith(color: theme.colorScheme.mutedForeground),
                  overflow: TextOverflow.ellipsis,
                ),
                if (port != null) ...[
                  const SizedBox(height: 4),
                  GestureDetector(
                    onTap: () => onOpenPort(port),
                    child: Text(
                      '$port:$port',
                      style: theme.textTheme.small.copyWith(color: theme.colorScheme.primary),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (container.isRunning)
            _ComposeActionIcon(icon: LucideIcons.square, tooltip: 'Stop', enabled: !busy, onPressed: onStop)
          else
            _ComposeActionIcon(icon: LucideIcons.play, tooltip: 'Start', enabled: !busy, onPressed: onStart),
          _ComposeActionIcon(icon: LucideIcons.trash2, tooltip: 'Delete', enabled: !busy, onPressed: onRemove),
        ],
      ),
    );
  }
}

class _ComposeActionIcon extends StatelessWidget {
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
