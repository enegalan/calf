import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:ui/api/client.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/logs_panel.dart';
import 'package:ui/widgets/poll_interval_mixin.dart';
import 'package:ui/theme/calf_theme.dart';

const _maxLogLines = 4000;
const _filterListMaxHeight = 220.0;

const _mixedLogColors = [
  Color(0xFFE91E8C),
  Color(0xFF9B5DE5),
  Color(0xFF00BBF9),
  Color(0xFF00F5D4),
  Color(0xFFFEE440),
  Color(0xFFF15BB5),
];

/// Fan-in log viewer for every running container.
class UnifiedLogsScreen extends StatefulWidget {
  /// Creates a [UnifiedLogsScreen] widget.
  const UnifiedLogsScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

  @override
  State<UnifiedLogsScreen> createState() => _UnifiedLogsScreenState();
}

class _UnifiedLogsScreenState extends State<UnifiedLogsScreen>
    with PollIntervalMixin {
  final List<MixedLogBlock> _blocks = [];
  final _scrollController = ScrollController();
  final _filterController = TextEditingController();
  final _filterFocus = FocusNode();
  final Set<String> _selectedNames = {};
  final List<ContainerItem> _running = [];
  StreamSubscription<dynamic>? _subscription;
  WebSocketChannel? _channel;
  bool _filterOpen = false;

  /// Connects to the log stream and starts container-list polling.
  @override
  void initState() {
    super.initState();
    _connect();
    unawaited(_loadContainers());
    unawaited(startPollInterval(widget.apiClient, _loadContainers));
  }

  /// Closes the log stream, poll timer, and controllers.
  @override
  void dispose() {
    _subscription?.cancel();
    _channel?.sink.close();
    _scrollController.dispose();
    _filterController.dispose();
    _filterFocus.dispose();
    disposePollInterval();
    super.dispose();
  }

  /// Opens the unified logs WebSocket and appends incoming lines.
  void _connect() {
    _channel = WebSocketChannel.connect(
      widget.apiClient.unifiedLogsWebSocketUri(),
    );
    _subscription = _channel!.stream.listen((event) {
      final text = event.toString();
      if (text.isEmpty) {
        return;
      }
      final split = text.indexOf(' | ');
      final name = split > 0 ? text.substring(0, split) : 'container';
      final line = split > 0 ? text.substring(split + 3) : text;
      if (!mounted) {
        return;
      }
      setState(() {
        final color = _colorFor(name);
        if (_blocks.isEmpty || _blocks.last.containerName != name) {
          _blocks.add(
            MixedLogBlock(
              containerId: name,
              containerName: name,
              color: color,
              lines: [LogLine(text: line, receivedAt: DateTime.now())],
            ),
          );
        } else {
          final last = _blocks.last;
          _blocks[_blocks.length - 1] = last.copyWith(
            lines: [
              ...last.lines,
              LogLine(text: line, receivedAt: DateTime.now()),
            ],
          );
        }
        var total = 0;
        for (final block in _blocks) {
          total += block.lines.length;
        }
        while (total > _maxLogLines && _blocks.isNotEmpty) {
          final first = _blocks.first;
          if (first.lines.length <= 1) {
            _blocks.removeAt(0);
          } else {
            _blocks[0] = first.copyWith(lines: first.lines.sublist(1));
          }
          total--;
        }
      });
    }, onError: (_) {});
  }

  /// Refreshes running containers used by the filter list.
  Future<void> _loadContainers({bool silent = false}) async {
    try {
      final containers = await widget.apiClient.fetchContainers();
      if (!mounted) {
        return;
      }
      setState(() {
        _running
          ..clear()
          ..addAll(containers.where((container) => container.isRunning));
      });
    } on ApiException {
      return;
    } on TimeoutException {
      return;
    }
  }

  /// Adds or removes [name] from the include filter.
  void _toggleContainer(String name) {
    setState(() {
      if (_selectedNames.contains(name)) {
        _selectedNames.remove(name);
      } else {
        _selectedNames.add(name);
      }
    });
  }

  /// Shows logs from every container again.
  void _clearFilter() {
    setState(() {
      _selectedNames.clear();
      _filterController.clear();
    });
  }

  /// Opens the searchable container list.
  void _openFilter() {
    if (_filterOpen) {
      return;
    }
    setState(() => _filterOpen = true);
  }

  /// Closes the container list and drops search focus.
  void _closeFilter() {
    if (!_filterOpen && !_filterFocus.hasFocus) {
      return;
    }
    _filterFocus.unfocus();
    setState(() => _filterOpen = false);
  }

  /// Returns the mixed-log color for [name].
  Color _colorFor(String name) {
    return _mixedLogColors[name.hashCode.abs() % _mixedLogColors.length];
  }

  /// Running and recently logged containers, sorted for the filter list.
  List<_LogFilterEntry> _entries() {
    final byName = <String, _LogFilterEntry>{};
    for (final container in _running) {
      if (container.name.isEmpty) {
        continue;
      }
      byName[container.name] = _LogFilterEntry(
        name: container.name,
        service: container.composeService,
        project: container.composeProject,
      );
    }
    for (final block in _blocks) {
      byName.putIfAbsent(
        block.containerName,
        () => _LogFilterEntry(name: block.containerName),
      );
    }
    final list = byName.values.toList()
      ..sort((a, b) {
        final aSelected = _selectedNames.contains(a.name);
        final bSelected = _selectedNames.contains(b.name);
        if (aSelected != bSelected) {
          return aSelected ? -1 : 1;
        }
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
    return list;
  }

  /// Entries whose name, service, or project contains the search query.
  List<_LogFilterEntry> _matching(List<_LogFilterEntry> entries) {
    final query = _filterController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return entries;
    }
    return entries.where((entry) => entry.matches(query)).toList();
  }

  /// Builds the logs screen with a searchable multi-select container filter.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries();
    final matches = _matching(entries);
    final filtered = _selectedNames.isEmpty
        ? _blocks
        : _blocks
              .where((block) => _selectedNames.contains(block.containerName))
              .toList();
    final selectedCount = _selectedNames.length;
    final hint = selectedCount == 0
        ? 'Filter containers'
        : '$selectedCount selected';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Logs', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'Live output from running containers.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 16),
        TapRegion(
          onTapOutside: (_) => _closeFilter(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _filterController,
                focusNode: _filterFocus,
                onTap: _openFilter,
                onChanged: (_) {
                  setState(() {
                    _filterOpen = true;
                  });
                },
                decoration: InputDecoration(
                  hintText: hint,
                  prefixIcon: Icon(
                    LucideIcons.search,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  suffixIcon: selectedCount == 0
                      ? null
                      : IconButton(
                          tooltip: 'Clear filter',
                          icon: Icon(
                            LucideIcons.x,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          onPressed: _clearFilter,
                        ),
                ),
              ),
              if (_filterOpen) ...[
                const SizedBox(height: 8),
                _ContainerFilterList(
                  theme: theme,
                  entries: matches,
                  selectedNames: _selectedNames,
                  colorFor: _colorFor,
                  onToggle: _toggleContainer,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: MixedLogsPanel(
            blocks: filtered,
            scrollController: _scrollController,
            runningCount: entries.length,
            onClear: () => setState(() => _blocks.clear()),
          ),
        ),
      ],
    );
  }
}

/// One container or compose service shown in the logs filter list.
class _LogFilterEntry {
  /// Creates a filter row for [name], optionally labeled by compose service.
  const _LogFilterEntry({
    required this.name,
    this.service = '',
    this.project = '',
  });

  final String name;
  final String service;
  final String project;

  /// Compose service name when set, otherwise the container name.
  String get label => service.isNotEmpty ? service : name;

  /// Whether [query] matches name, service, or project.
  bool matches(String query) {
    return name.toLowerCase().contains(query) ||
        service.toLowerCase().contains(query) ||
        project.toLowerCase().contains(query);
  }
}

/// Scrollable checkbox list of containers matching the current search.
class _ContainerFilterList extends StatelessWidget {
  /// Creates the filter dropdown list.
  const _ContainerFilterList({
    required this.theme,
    required this.entries,
    required this.selectedNames,
    required this.colorFor,
    required this.onToggle,
  });

  final ThemeData theme;
  final List<_LogFilterEntry> entries;
  final Set<String> selectedNames;
  final Color Function(String name) colorFor;
  final ValueChanged<String> onToggle;

  /// Builds the bordered, height-capped filter list.
  @override
  Widget build(BuildContext context) {
    return Material(
      color: theme.colorScheme.surface,
      shape: CalfTheme.popupMenuShape(theme.colorScheme),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: entries.isEmpty
            ? 44
            : (entries.length * 32.0).clamp(32.0, _filterListMaxHeight),
        child: entries.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'No matching containers',
                  style: CalfTheme.muted(theme),
                ),
              )
            : ListView.builder(
                itemExtent: 32,
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final selected = selectedNames.contains(entry.name);
                  final color = colorFor(entry.name);
                  return HoverListRow(
                    theme: theme,
                    selected: selected,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    onTap: () => onToggle(entry.name),
                    child: Row(
                      children: [
                        IgnorePointer(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: Checkbox(
                              value: selected,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: (_) {},
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            entry.project.isNotEmpty &&
                                    entry.label != entry.project
                                ? '${entry.project} / ${entry.label}'
                                : entry.label,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}
