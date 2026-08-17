import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/storage/logs_viewer_preferences.dart';
import 'package:ui/theme/calf_theme.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/calf_snack_bar.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/logs_panel.dart';
import 'package:ui/widgets/poll_interval_mixin.dart';
import 'package:ui/widgets/running_filter_switch.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _maxLogLines = 4000;
const _filterListMaxHeight = 220.0;
const _menuWidth = 320.0;

const _mixedLogColors = [
  Color(0xFFE91E8C),
  Color(0xFF9B5DE5),
  Color(0xFF00BBF9),
  Color(0xFF00F5D4),
  Color(0xFFFEE440),
  Color(0xFFF15BB5),
];

enum _LogsMenu { none, filter, save, settings }

/// Fan-in log viewer for every running container.
class UnifiedLogsScreen extends StatefulWidget {
  /// Creates a [UnifiedLogsScreen] widget.
  const UnifiedLogsScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

  @override
  State<UnifiedLogsScreen> createState() => _UnifiedLogsScreenState();
}

class _UnifiedLogsScreenState extends State<UnifiedLogsScreen>
    with PollIntervalMixin, LogViewerPreferencesMixin {
  final List<MixedLogBlock> _blocks = [];
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  final _containerSearchController = TextEditingController();
  final _saveNameController = TextEditingController();
  final Set<String> _selectedNames = {};
  final List<ContainerItem> _running = [];
  final List<SavedLogFilter> _savedFilters = [];
  StreamSubscription<dynamic>? _subscription;
  WebSocketChannel? _channel;
  _LogsMenu _menu = _LogsMenu.none;
  bool _matchCase = false;
  bool _stickToBottom = true;

  /// Connects to the log stream and starts container-list polling.
  @override
  void initState() {
    super.initState();
    initLogViewerPreferences();
    _connect();
    unawaited(_loadContainers());
    unawaited(_loadSavedFilters());
    unawaited(startPollInterval(widget.apiClient, _loadContainers));
  }

  /// Closes the log stream, poll timer, and controllers.
  @override
  void dispose() {
    _subscription?.cancel();
    _channel?.sink.close();
    _scrollController.dispose();
    _searchController.dispose();
    _containerSearchController.dispose();
    _saveNameController.dispose();
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
      _scrollToBottomIfStuck();
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

  /// Loads named saved filters from disk.
  Future<void> _loadSavedFilters() async {
    final filters = await SavedLogFilters.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _savedFilters
        ..clear()
        ..addAll(filters);
    });
  }

  /// Scrolls to the latest line when Stick to bottom is on.
  void _scrollToBottomIfStuck() {
    if (!_stickToBottom) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
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

  /// Selects or clears every container in [entries].
  void _toggleGroup(List<_LogFilterEntry> entries) {
    final allSelected = entries.every(
      (entry) => _selectedNames.contains(entry.name),
    );
    setState(() {
      if (allSelected) {
        for (final entry in entries) {
          _selectedNames.remove(entry.name);
        }
      } else {
        for (final entry in entries) {
          _selectedNames.add(entry.name);
        }
      }
    });
  }

  /// Selects every container currently listed in the filter menu.
  void _selectAllVisible() {
    setState(() {
      for (final entry in _matching(_entries())) {
        _selectedNames.add(entry.name);
      }
    });
  }

  /// Shows logs from every container again.
  void _clearContainerFilter() {
    setState(() {
      _selectedNames.clear();
      _containerSearchController.clear();
    });
  }

  /// Opens [menu], or closes it when it is already open.
  void _toggleMenu(_LogsMenu menu) {
    setState(() {
      _menu = _menu == menu ? _LogsMenu.none : menu;
    });
  }

  /// Closes any open toolbar menu.
  void _closeMenu() {
    if (_menu == _LogsMenu.none) {
      return;
    }
    setState(() => _menu = _LogsMenu.none);
  }

  /// Persists the current search and container filter under [name].
  Future<void> _saveCurrentFilter() async {
    final name = _saveNameController.text.trim();
    if (name.isEmpty) {
      return;
    }
    final filter = SavedLogFilter(
      name: name,
      query: _searchController.text,
      matchCase: _matchCase,
      containerNames: _selectedNames.toList(),
    );
    setState(() {
      _savedFilters.removeWhere((item) => item.name == name);
      _savedFilters.add(filter);
      _saveNameController.clear();
    });
    await SavedLogFilters.save(_savedFilters);
  }

  /// Applies a previously saved search and container filter.
  void _applySavedFilter(SavedLogFilter filter) {
    setState(() {
      _searchController.text = filter.query;
      _matchCase = filter.matchCase;
      _selectedNames
        ..clear()
        ..addAll(filter.containerNames);
      _menu = _LogsMenu.none;
    });
  }

  /// Removes a saved filter from disk.
  Future<void> _deleteSavedFilter(SavedLogFilter filter) async {
    setState(() {
      _savedFilters.removeWhere((item) => item.name == filter.name);
    });
    await SavedLogFilters.save(_savedFilters);
  }

  /// Writes visible log lines to a user-chosen CSV file.
  Future<void> _exportCsv() async {
    final blocks = _visibleBlocks();
    var lineCount = 0;
    for (final block in blocks) {
      lineCount += block.lines.length;
    }
    if (lineCount == 0) {
      if (!mounted) {
        return;
      }
      showCalfSnackBar(context, 'No log lines to export');
      return;
    }

    final now = DateTime.now();
    final stamp =
        '${now.year}${_two(now.month)}${_two(now.day)}-'
        '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
    final location = await getSaveLocation(
      suggestedName: 'calf-logs-$stamp.csv',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'CSV', extensions: ['csv']),
      ],
    );
    if (location == null) {
      return;
    }

    try {
      await File(location.path).writeAsString(logsToCsv(blocks));
    } on FileSystemException catch (error) {
      if (!mounted) {
        return;
      }
      showCalfSnackBar(
        context,
        'Failed to write CSV: ${error.message}',
        kind: CalfToastKind.error,
      );
      return;
    }
    if (!mounted) {
      return;
    }
    showCalfSnackBar(context, 'Exported $lineCount lines');
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
        final project = a.project.toLowerCase().compareTo(
          b.project.toLowerCase(),
        );
        if (project != 0) {
          return project;
        }
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
    return list;
  }

  /// Entries whose name, service, or project contains the container search.
  List<_LogFilterEntry> _matching(List<_LogFilterEntry> entries) {
    final query = _containerSearchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return entries;
    }
    return entries.where((entry) => entry.matches(query)).toList();
  }

  /// Groups matching entries by compose project for the filter menu.
  List<_LogFilterGroup> _groups(List<_LogFilterEntry> entries) {
    final standalone = <_LogFilterEntry>[];
    final byProject = <String, List<_LogFilterEntry>>{};
    for (final entry in entries) {
      if (entry.project.isEmpty) {
        standalone.add(entry);
      } else {
        byProject.putIfAbsent(entry.project, () => []).add(entry);
      }
    }
    final groups = <_LogFilterGroup>[
      if (standalone.isNotEmpty)
        _LogFilterGroup(title: '', entries: standalone),
    ];
    final projects = byProject.keys.toList()..sort();
    for (final project in projects) {
      groups.add(_LogFilterGroup(title: project, entries: byProject[project]!));
    }
    return groups;
  }

  /// Blocks and lines that pass the current container and text filters.
  List<MixedLogBlock> _visibleBlocks() {
    final selected = _selectedNames.isEmpty
        ? _blocks
        : _blocks
              .where((block) => _selectedNames.contains(block.containerName))
              .toList();
    final query = _searchController.text;
    if (query.isEmpty) {
      return selected;
    }
    final visible = <MixedLogBlock>[];
    for (final block in selected) {
      final lines = block.lines
          .where(
            (line) =>
                logLineMatchesQuery(line.text, query, matchCase: _matchCase),
          )
          .toList();
      if (lines.isEmpty) {
        continue;
      }
      visible.add(block.copyWith(lines: lines));
    }
    return visible;
  }

  /// Counts lines across [blocks].
  int _lineCount(List<MixedLogBlock> blocks) {
    var total = 0;
    for (final block in blocks) {
      total += block.lines.length;
    }
    return total;
  }

  /// Builds the logs screen with search, container filters, and export.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries();
    final matches = _matching(entries);
    final groups = _groups(matches);
    final filtered = _visibleBlocks();
    final lineCount = _lineCount(filtered);
    final searchQuery = _searchController.text;
    final highlightPattern = searchQuery.isEmpty
        ? null
        : logSearchPattern(searchQuery, matchCase: _matchCase);

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
        Row(
          children: [
            Expanded(child: _buildSearchField(theme)),
            const SizedBox(width: 8),
            _LogsToolbarIcon(
              theme: theme,
              icon: LucideIcons.listFilter,
              tooltip: 'Container filters',
              selected: _menu == _LogsMenu.filter || _selectedNames.isNotEmpty,
              onPressed: () => _toggleMenu(_LogsMenu.filter),
            ),
            _LogsToolbarIcon(
              theme: theme,
              icon: LucideIcons.save,
              tooltip: 'Save current filters',
              selected: _menu == _LogsMenu.save,
              onPressed: () => _toggleMenu(_LogsMenu.save),
            ),
            _LogsToolbarIcon(
              theme: theme,
              icon: LucideIcons.slidersHorizontal,
              tooltip: 'Settings',
              selected: _menu == _LogsMenu.settings,
              onPressed: () => _toggleMenu(_LogsMenu.settings),
            ),
            _LogsToolbarIcon(
              theme: theme,
              icon: LucideIcons.download,
              tooltip: 'Export to CSV',
              onPressed: _exportCsv,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Stack(
            children: [
              Listener(
                onPointerDown: (_) => _closeMenu(),
                child: MixedLogsPanel(
                  blocks: filtered,
                  scrollController: _scrollController,
                  runningCount: entries.length,
                  onClear: () => setState(() => _blocks.clear()),
                  showChrome: false,
                  showTimestampOverride: showTimestamp,
                  wrapLinesOverride: wrapLines,
                  highlightPattern: highlightPattern,
                ),
              ),
              if (_menu == _LogsMenu.filter)
                Positioned(
                  top: 0,
                  right: 0,
                  child: _ContainerFilterMenu(
                    theme: theme,
                    searchController: _containerSearchController,
                    groups: groups,
                    selectedNames: _selectedNames,
                    colorFor: _colorFor,
                    onSearchChanged: (_) => setState(() {}),
                    onToggle: _toggleContainer,
                    onToggleGroup: _toggleGroup,
                    onSelectAll: _selectAllVisible,
                    onClear: _clearContainerFilter,
                  ),
                ),
              if (_menu == _LogsMenu.save)
                Positioned(
                  top: 0,
                  right: 0,
                  child: _SaveFilterMenu(
                    theme: theme,
                    nameController: _saveNameController,
                    savedFilters: _savedFilters,
                    onSave: _saveCurrentFilter,
                    onApply: _applySavedFilter,
                    onDelete: _deleteSavedFilter,
                  ),
                ),
              if (_menu == _LogsMenu.settings)
                Positioned(
                  top: 0,
                  right: 0,
                  child: _LogsSettingsMenu(
                    theme: theme,
                    wrapLines: wrapLines,
                    showTimestamp: showTimestamp,
                    onWrapLinesChanged: setLogViewerWrapLines,
                    onShowTimestampChanged: setLogViewerShowTimestamp,
                    onClearLogs: () => setState(() => _blocks.clear()),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              '$lineCount ${lineCount == 1 ? 'line' : 'lines'}',
              style: CalfTheme.muted(theme).copyWith(fontSize: 13),
            ),
            const Spacer(),
            RunningFilterSwitch(
              value: _stickToBottom,
              onChanged: (value) {
                setState(() => _stickToBottom = value);
                if (value) {
                  _scrollToBottomIfStuck();
                }
              },
              label: 'Stick to bottom',
            ),
          ],
        ),
      ],
    );
  }

  /// Builds the log-text search field with a match-case toggle.
  Widget _buildSearchField(ThemeData theme) {
    return TextField(
      controller: _searchController,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText: "Search logs (supports regex like '/error|warn/')",
        prefixIcon: Icon(
          LucideIcons.search,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        suffixIconConstraints: const BoxConstraints(
          minHeight: 20,
          maxHeight: 22,
          minWidth: 28,
        ),
        suffixIcon: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Tooltip(
            message: 'Match case',
            child: Material(
              color: _matchCase
                  ? theme.colorScheme.primary.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              child: InkWell(
                onTap: () => setState(() => _matchCase = !_matchCase),
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 28,
                  height: 20,
                  child: Center(
                    child: Text(
                      'Aa',
                      style: theme.textTheme.labelSmall!.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1,
                        color: _matchCase
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One icon button in the Logs header toolbar.
class _LogsToolbarIcon extends StatelessWidget {
  /// Creates a tooltip-wrapped Logs toolbar icon button.
  const _LogsToolbarIcon({
    required this.theme,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  final ThemeData theme;
  final IconData icon;
  final String tooltip;
  final FutureOr<void> Function() onPressed;
  final bool selected;

  /// Builds one header toolbar icon.
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: CalfButton.ghost(
        width: 36,
        height: 36,
        padding: EdgeInsets.zero,
        backgroundColor: selected
            ? theme.colorScheme.surfaceContainerHighest
            : null,
        onPressed: onPressed,
        child: Icon(icon, size: 16, color: theme.colorScheme.primary),
      ),
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

/// Compose project group, or standalone containers when [title] is empty.
class _LogFilterGroup {
  /// Creates a filter group.
  const _LogFilterGroup({required this.title, required this.entries});

  final String title;
  final List<_LogFilterEntry> entries;
}

/// Contextual menu for selecting which containers appear in Logs.
class _ContainerFilterMenu extends StatelessWidget {
  /// Creates the container filter popover.
  const _ContainerFilterMenu({
    required this.theme,
    required this.searchController,
    required this.groups,
    required this.selectedNames,
    required this.colorFor,
    required this.onSearchChanged,
    required this.onToggle,
    required this.onToggleGroup,
    required this.onSelectAll,
    required this.onClear,
  });

  final ThemeData theme;
  final TextEditingController searchController;
  final List<_LogFilterGroup> groups;
  final Set<String> selectedNames;
  final Color Function(String name) colorFor;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onToggle;
  final ValueChanged<List<_LogFilterEntry>> onToggleGroup;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;

  /// Builds the searchable, grouped container filter popover.
  @override
  Widget build(BuildContext context) {
    var rowCount = 0;
    for (final group in groups) {
      if (group.title.isNotEmpty) {
        rowCount++;
      }
      rowCount += group.entries.length;
    }

    return _LogsPopover(
      theme: theme,
      width: _menuWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: searchController,
            onChanged: onSearchChanged,
            decoration: InputDecoration(
              hintText: 'Search container',
              isDense: true,
              prefixIcon: Icon(
                LucideIcons.search,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: rowCount == 0
                ? 44
                : (rowCount * 32.0).clamp(32.0, _filterListMaxHeight),
            child: rowCount == 0
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'No matching containers',
                      style: CalfTheme.muted(theme),
                    ),
                  )
                : ListView(
                    children: [
                      for (final group in groups) ...[
                        if (group.title.isNotEmpty)
                          _FilterRow(
                            theme: theme,
                            label: group.title,
                            selected: _groupSelected(group.entries),
                            tristate: true,
                            onTap: () => onToggleGroup(group.entries),
                          ),
                        for (final entry in group.entries)
                          _FilterRow(
                            theme: theme,
                            label: entry.label,
                            indent: group.title.isNotEmpty,
                            selected: selectedNames.contains(entry.name)
                                ? true
                                : false,
                            color: colorFor(entry.name),
                            onTap: () => onToggle(entry.name),
                          ),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              TextButton(
                onPressed: onSelectAll,
                child: const Text('Select all'),
              ),
              const Spacer(),
              TextButton(
                onPressed: onClear,
                child: const Text('Clear container filter'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Returns the checkbox value for a project group.
  bool? _groupSelected(List<_LogFilterEntry> entries) {
    var selected = 0;
    for (final entry in entries) {
      if (selectedNames.contains(entry.name)) {
        selected++;
      }
    }
    if (selected == 0) {
      return false;
    }
    if (selected == entries.length) {
      return true;
    }
    return null;
  }
}

/// One checkbox row in the container filter menu.
class _FilterRow extends StatelessWidget {
  /// Creates a filter checkbox row.
  const _FilterRow({
    required this.theme,
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
    this.indent = false,
    this.tristate = false,
  });

  final ThemeData theme;
  final String label;
  final bool? selected;
  final VoidCallback onTap;
  final Color? color;
  final bool indent;
  final bool tristate;

  /// Builds a hoverable checkbox row.
  @override
  Widget build(BuildContext context) {
    return HoverListRow(
      theme: theme,
      selected: selected == true,
      padding: EdgeInsets.only(left: indent ? 24 : 8, right: 8),
      onTap: onTap,
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            IgnorePointer(
              child: SizedBox(
                width: 18,
                height: 18,
                child: Checkbox(
                  value: selected,
                  tristate: tristate,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (_) {},
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (color != null) ...[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Popover for naming and reusing the current Logs filters.
class _SaveFilterMenu extends StatelessWidget {
  /// Creates the save-filter popover.
  const _SaveFilterMenu({
    required this.theme,
    required this.nameController,
    required this.savedFilters,
    required this.onSave,
    required this.onApply,
    required this.onDelete,
  });

  final ThemeData theme;
  final TextEditingController nameController;
  final List<SavedLogFilter> savedFilters;
  final FutureOr<void> Function() onSave;
  final ValueChanged<SavedLogFilter> onApply;
  final ValueChanged<SavedLogFilter> onDelete;

  /// Builds the save-filter popover.
  @override
  Widget build(BuildContext context) {
    return _LogsPopover(
      theme: theme,
      width: _menuWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Save current filter', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(
              style: CalfTheme.muted(theme).copyWith(fontSize: 12),
              children: const [
                TextSpan(text: 'Tip: use regex like '),
                TextSpan(
                  text: '/pattern/flags',
                  style: TextStyle(fontFamily: CalfFonts.mono),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: nameController,
                  onSubmitted: (_) => onSave(),
                  decoration: const InputDecoration(isDense: true),
                ),
              ),
              const SizedBox(width: 8),
              CalfButton(onPressed: onSave, child: const Text('Save')),
            ],
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          if (savedFilters.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text('No saved searches', style: CalfTheme.muted(theme)),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: savedFilters.length,
                itemBuilder: (context, index) {
                  final filter = savedFilters[index];
                  return HoverListRow(
                    theme: theme,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    onTap: () => onApply(filter),
                    child: SizedBox(
                      height: 32,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              filter.name,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Delete saved filter',
                            visualDensity: VisualDensity.compact,
                            iconSize: 14,
                            onPressed: () => onDelete(filter),
                            icon: Icon(
                              LucideIcons.x,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Settings popover for wrap, timestamps, and clearing logs.
class _LogsSettingsMenu extends StatelessWidget {
  /// Creates the Logs settings popover.
  const _LogsSettingsMenu({
    required this.theme,
    required this.wrapLines,
    required this.showTimestamp,
    required this.onWrapLinesChanged,
    required this.onShowTimestampChanged,
    required this.onClearLogs,
  });

  final ThemeData theme;
  final bool wrapLines;
  final bool showTimestamp;
  final ValueChanged<bool> onWrapLinesChanged;
  final ValueChanged<bool> onShowTimestampChanged;
  final VoidCallback onClearLogs;

  /// Builds wrap, timestamp, and clear-log controls.
  @override
  Widget build(BuildContext context) {
    return _LogsPopover(
      theme: theme,
      width: 240,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SettingsToggleRow(
            theme: theme,
            label: 'Wrap lines',
            value: wrapLines,
            onChanged: onWrapLinesChanged,
          ),
          _SettingsToggleRow(
            theme: theme,
            label: 'Show timestamps',
            value: showTimestamp,
            onChanged: onShowTimestampChanged,
          ),
          HoverListRow(
            theme: theme,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            onTap: onClearLogs,
            child: SizedBox(
              height: 36,
              child: Row(
                children: [
                  Expanded(
                    child: Text('Clear logs', style: theme.textTheme.bodySmall),
                  ),
                  Icon(
                    LucideIcons.trash2,
                    size: 16,
                    color: theme.colorScheme.error,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One switch row with the control on the left.
class _SettingsToggleRow extends StatelessWidget {
  /// Creates a left-aligned settings switch row.
  const _SettingsToggleRow({
    required this.theme,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final ThemeData theme;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// Builds the switch and label.
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            Switch(value: value, onChanged: onChanged),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          ],
        ),
      ),
    );
  }
}

/// Shared bordered popover chrome for Logs toolbar menus.
class _LogsPopover extends StatelessWidget {
  /// Creates a Logs popover panel.
  const _LogsPopover({
    required this.theme,
    required this.width,
    required this.child,
  });

  final ThemeData theme;
  final double width;
  final Widget child;

  /// Builds the bordered popover surface.
  @override
  Widget build(BuildContext context) {
    return Material(
      color: theme.colorScheme.surface,
      shape: CalfTheme.popupMenuShape(theme.colorScheme),
      clipBehavior: Clip.antiAlias,
      elevation: 8,
      shadowColor: const Color(0x26000000),
      child: SizedBox(
        width: width,
        child: Padding(padding: const EdgeInsets.all(12), child: child),
      ),
    );
  }
}

/// Pads [value] to two digits.
String _two(int value) => value.toString().padLeft(2, '0');

/// Returns whether [line] matches the Logs search [query].
///
/// Slash-delimited values (`/error|warn/i`) are regular expressions.
/// Anything else is a literal substring. Invalid regex never matches.
bool logLineMatchesQuery(String line, String query, {required bool matchCase}) {
  if (query.isEmpty) {
    return true;
  }
  final pattern = logSearchPattern(query, matchCase: matchCase);
  if (pattern == null) {
    return false;
  }
  return pattern.hasMatch(line);
}

/// Builds a [RegExp] for [query], or null when the pattern is invalid.
RegExp? logSearchPattern(String query, {required bool matchCase}) {
  if (query.isEmpty) {
    return null;
  }

  var source = query;
  var caseSensitive = matchCase;
  var multiLine = false;
  var dotAll = false;
  if (query.startsWith('/') && query.length >= 2) {
    final last = query.lastIndexOf('/');
    if (last > 0) {
      source = query.substring(1, last);
      final flags = query.substring(last + 1);
      if (source.isEmpty) {
        return null;
      }
      if (flags.contains('i')) {
        caseSensitive = false;
      }
      multiLine = flags.contains('m');
      dotAll = flags.contains('s');
    } else {
      source = RegExp.escape(query);
    }
  } else {
    source = RegExp.escape(query);
  }

  try {
    return RegExp(
      source,
      caseSensitive: caseSensitive,
      multiLine: multiLine,
      dotAll: dotAll,
    );
  } on FormatException {
    return null;
  }
}

/// Serializes [blocks] to CSV with timestamp, container, and message columns.
String logsToCsv(List<MixedLogBlock> blocks) {
  final buffer = StringBuffer('timestamp,container,message\n');
  for (final block in blocks) {
    for (final line in block.lines) {
      buffer.writeln(
        '${_csvField(formatLogTimestamp(line.receivedAt))},'
        '${_csvField(block.containerName)},'
        '${_csvField(line.text)}',
      );
    }
  }
  return buffer.toString();
}

/// Quotes a CSV field when it contains commas, quotes, or newlines.
String _csvField(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}
