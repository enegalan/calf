import 'dart:async';
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/calf_tab_bar.dart';
import 'package:ui/widgets/confirm_dialog.dart';
import 'package:ui/widgets/detail_breadcrumb.dart';
import 'package:ui/widgets/files_panel.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/logs_panel.dart';
import 'package:ui/theme/calf_theme.dart';

enum _ContainerDetailTab { logs, inspect, mounts, exec, files, stats }

const _maxLogLines = 2000;

class ContainerDetailView extends StatefulWidget {
  /// Creates a [ContainerDetailView] widget.
  const ContainerDetailView({
    super.key,
    required this.container,
    required this.apiClient,
    required this.onBack,
    required this.onChanged,
  });

  final ContainerItem container;
  final CalfClient apiClient;
  final VoidCallback onBack;
  final Future<void> Function() onChanged;

  /// Creates the mutable state for [ContainerDetailView].
  @override
  State<ContainerDetailView> createState() => _ContainerDetailViewState();
}

class _ContainerDetailViewState extends State<ContainerDetailView> {
  late ContainerItem _container;
  _ContainerDetailTab _tab = _ContainerDetailTab.logs;
  bool _busy = false;
  String? _error;

  final List<LogLine> _logLines = [];
  String? _logsError;
  StreamSubscription<String>? _logsSubscription;
  final _logsScrollController = ScrollController();

  String? _inspectRaw;
  Map<String, dynamic>? _inspectData;
  bool _inspectLoading = false;
  String? _inspectError;
  bool _inspectRawJson = false;

  List<ContainerMount> _mounts = [];
  bool _mountsLoading = false;
  String? _mountsError;

  ContainerStats? _stats;
  bool _statsLoading = false;
  String? _statsError;
  Timer? _statsTimer;
  final _statsHistory = _StatsHistory();
  bool _statsRefreshInFlight = false;
  int _statsRefreshGeneration = 0;

  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    _container = widget.container;
    _loadTabData();
  }

  /// Refreshes local state when the parent widget changes.
  @override
  void didUpdateWidget(covariant ContainerDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final idChanged = oldWidget.container.id != widget.container.id;
    final runningChanged =
        oldWidget.container.isRunning != widget.container.isRunning;

    setState(() {
      _container = widget.container;
    });

    if (idChanged || runningChanged) {
      if (_tab == _ContainerDetailTab.logs ||
          _tab == _ContainerDetailTab.stats) {
        _loadTabData();
      }
    }
  }

  /// Releases controllers, timers, and stream subscriptions.
  @override
  void dispose() {
    _logsSubscription?.cancel();
    _logsScrollController.dispose();
    _statsTimer?.cancel();
    super.dispose();
  }

  /// Runs the given async action and refreshes the list on success.
  Future<void> _runAction(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await action();
      await widget.onChanged();
      final containers = await widget.apiClient.fetchContainers();
      ContainerItem? updated;
      for (final item in containers) {
        if (item.id == _container.id) {
          updated = item;
          break;
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        if (updated != null) {
          _container = updated;
        }
      });
      _loadTabData();
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

  /// Switches the active tab and loads tab-specific data.
  void _selectTab(_ContainerDetailTab tab) {
    if (_tab == tab) {
      return;
    }
    setState(() => _tab = tab);
    _loadTabData();
  }

  /// Stops background polling or streaming work.
  void _stopTabBackgroundWork() {
    _logsSubscription?.cancel();
    _logsSubscription = null;
    if (_statsTimer != null) {
      _statsTimer?.cancel();
      _statsTimer = null;
      _statsRefreshGeneration++;
    }
  }

  /// Fetches TabData from the API and updates state.
  void _loadTabData() {
    _stopTabBackgroundWork();

    switch (_tab) {
      case _ContainerDetailTab.logs:
        _startLogs();
      case _ContainerDetailTab.inspect:
        _loadInspect();
      case _ContainerDetailTab.mounts:
        _loadMounts();
      case _ContainerDetailTab.exec:
        break;
      case _ContainerDetailTab.files:
        break;
      case _ContainerDetailTab.stats:
        _startStats();
    }
  }

  /// Starts background polling or streaming for the active tab.
  void _startLogs() {
    setState(() {
      _logLines.clear();
      _logsError = null;
    });

    _logsSubscription = widget.apiClient
        .streamContainerLogs(_container.id)
        .listen(
          (line) {
            if (!mounted) {
              return;
            }
            setState(() {
              _logsError = null;
              _logLines.add(LogLine(text: line, receivedAt: DateTime.now()));
              if (_logLines.length > _maxLogLines) {
                _logLines.removeRange(0, _logLines.length - _maxLogLines);
              }
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_logsScrollController.hasClients) {
                _logsScrollController.jumpTo(
                  _logsScrollController.position.maxScrollExtent,
                );
              }
            });
          },
          onError: (error) {
            if (!mounted) {
              return;
            }
            setState(() => _logsError = error.toString());
          },
        );
  }

  /// Fetches Inspect from the API and updates state.
  Future<void> _loadInspect() async {
    setState(() {
      _inspectLoading = true;
      _inspectError = null;
    });

    try {
      final raw = await widget.apiClient.fetchContainerInspect(_container.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _inspectRaw = raw;
        _inspectData = _decodeInspectMap(raw);
        _inspectLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _inspectError = error.toString();
        _inspectLoading = false;
      });
    }
  }

  /// Fetches Mounts from the API and updates state.
  Future<void> _loadMounts() async {
    _statsTimer?.cancel();
    setState(() {
      _mountsLoading = true;
      _mountsError = null;
    });

    try {
      final mounts = await widget.apiClient.fetchContainerMounts(_container.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _mounts = mounts;
        _mountsLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _mountsError = error.toString();
        _mountsLoading = false;
      });
    }
  }

  /// Starts background polling or streaming for the active tab.
  void _startStats() {
    _logsSubscription?.cancel();
    _statsTimer?.cancel();
    _statsTimer = null;

    if (!_container.isRunning) {
      if (!mounted) {
        return;
      }
      setState(() {
        _stats = null;
        _statsError = null;
        _statsLoading = false;
      });
      return;
    }

    _refreshStats();
    _statsTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshStats(),
    );
  }

  /// Refreshes the latest data from the API.
  Future<void> _refreshStats() async {
    if (_statsRefreshInFlight) {
      return;
    }

    if (!_container.isRunning) {
      _statsTimer?.cancel();
      _statsTimer = null;
      _statsRefreshGeneration++;
      if (!mounted) {
        return;
      }
      setState(() {
        _stats = null;
        _statsError = null;
        _statsLoading = false;
      });
      return;
    }

    _statsRefreshInFlight = true;
    final generation = _statsRefreshGeneration;

    setState(() {
      _statsLoading = _stats == null;
      _statsError = null;
    });

    try {
      final stats = await widget.apiClient.fetchContainerStats(_container.id);
      if (!mounted || generation != _statsRefreshGeneration) {
        return;
      }
      setState(() {
        _stats = stats;
        _statsHistory.replaceFrom(stats);
        _statsLoading = false;
      });
    } catch (error) {
      if (!mounted || generation != _statsRefreshGeneration) {
        return;
      }
      setState(() {
        _statsError = error.toString();
        _statsLoading = false;
      });
    } finally {
      _statsRefreshInFlight = false;
    }
  }

  /// Decodes raw API payload into a structured map.
  Map<String, dynamic>? _decodeInspectMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return null;
  }

  /// Whether or what value backs the `inspectText` UI state.
  String get _inspectText {
    final raw = _inspectRaw;
    if (raw == null || raw.isEmpty) {
      return '';
    }
    try {
      final decoded = jsonDecode(raw);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return raw;
    }
  }

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final port = _container.primaryHostPort;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailBreadcrumb(
          segments: ['Containers', _container.displayName],
          onBack: widget.onBack,
        ),

        /// Creates a [_ContainerDetailViewState] widget.
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              LucideIcons.box,
              size: 28,
              color: _containerIconColor(_container, theme),
            ),

            /// Creates a [_ContainerDetailViewState] widget.
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _container.displayName,
                    style: theme.textTheme.headlineSmall,
                  ),

                  /// Creates a [_ContainerDetailViewState] widget.
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(_container.shortId, style: CalfTheme.muted(theme)),
                      Text(
                        _container.displayImage,
                        style: CalfTheme.muted(theme),
                      ),
                      if (port != null)
                        GestureDetector(
                          onTap: () => openPort(port),
                          child: Text(
                            '$port:$port',
                            style: theme.textTheme.bodySmall!.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        )
                      else
                        Text(
                          _container.displayPorts,
                          style: CalfTheme.muted(theme),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'STATUS',
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(_container.status, style: theme.textTheme.bodySmall),

                /// Creates a [_ContainerDetailViewState] widget.
                const SizedBox(height: 8),
                Row(
                  children: [
                    CalfButtonGroup(
                      actions: [
                        CalfGroupAction(
                          icon: LucideIcons.square,
                          tooltip: 'Stop',
                          enabled: !_busy && _container.isRunning,
                          onPressed: () => _runAction(
                            () =>
                                widget.apiClient.stopContainer(_container.id),
                          ),
                        ),
                        CalfGroupAction(
                          icon: LucideIcons.play,
                          tooltip: 'Start',
                          enabled: !_busy && !_container.isRunning,
                          onPressed: () => _runAction(
                            () => widget.apiClient.startContainer(
                              _container.id,
                            ),
                          ),
                        ),
                        CalfGroupAction(
                          icon: LucideIcons.rotateCw,
                          tooltip: 'Restart',
                          enabled: !_busy,
                          onPressed: () => _runAction(
                            () =>
                                widget.apiClient.restartContainer(_container.id),
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
                          title: 'Delete container',
                          description:
                              'Delete "${_container.name}"? This cannot be undone.',
                          confirmLabel: 'Delete',
                          destructive: true,
                        );
                        if (!confirmed || !mounted) {
                          return;
                        }
                        await _runAction(
                          () =>
                              widget.apiClient.removeContainer(_container.id),
                        );
                        if (mounted) {
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
              ],
            ),
          ],
        ),
        if (_error != null) ...[
          /// Creates a [_ContainerDetailViewState] widget.
          const SizedBox(height: 12),
          Text(
            _error!,
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],

        /// Creates a [_ContainerDetailViewState] widget.
        const SizedBox(height: 16),
        CalfTabBar(
          theme: theme,
          labels: const [
            'Logs',
            'Inspect',
            'Mounts',
            'Exec',
            'Files',
            'Stats',
          ],
          selectedIndex: _tab.index,
          onSelected: (index) => _selectTab(_ContainerDetailTab.values[index]),
        ),

        /// Creates a [_ContainerDetailViewState] widget.
        const SizedBox(height: 12),
        Expanded(child: _buildTabContent(theme)),
      ],
    );
  }

  /// Builds the widget for the currently selected tab.
  Widget _buildTabContent(ThemeData theme) {
    switch (_tab) {
      case _ContainerDetailTab.logs:
        return LogsPanel(
          lines: _logLines,
          error: _logsError,
          scrollController: _logsScrollController,
          onClear: () => setState(_logLines.clear),
        );
      case _ContainerDetailTab.inspect:
        return _InspectTab(
          theme: theme,
          loading: _inspectLoading,
          error: _inspectError,
          inspect: _inspectData,
          text: _inspectText,
          rawJson: _inspectRawJson,
          onToggleRaw: (value) => setState(() => _inspectRawJson = value),
        );
      case _ContainerDetailTab.mounts:
        return _MountsTab(
          theme: theme,
          loading: _mountsLoading,
          error: _mountsError,
          mounts: _mounts,
        );
      case _ContainerDetailTab.exec:
        return _ExecTab(
          theme: theme,
          containerId: _container.id,
          apiClient: widget.apiClient,
          isRunning: _container.isRunning,
        );
      case _ContainerDetailTab.files:
        return FilesPanel(
          theme: theme,
          loadDirectory: (path) =>
              widget.apiClient.fetchContainerFiles(_container.id, path: path),
        );
      case _ContainerDetailTab.stats:
        return _StatsTab(
          theme: theme,
          isRunning: _container.isRunning,
          loading: _statsLoading,
          error: _statsError,
          stats: _stats,
          history: _statsHistory,
        );
    }
  }
}

class _Panel extends StatelessWidget {
  /// Creates a [_Panel] widget.
  const _Panel({required this.theme, required this.child});

  final ThemeData theme;
  final Widget child;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: CalfTheme.radius,
        color: _panelBackgroundColor(theme),
      ),
      padding: const EdgeInsets.all(12),
      child: child,
    );
  }
}

class _InspectTab extends StatelessWidget {
  /// Creates a [_InspectTab] widget.
  const _InspectTab({
    required this.theme,
    required this.loading,
    required this.error,
    required this.inspect,
    required this.text,
    required this.rawJson,
    required this.onToggleRaw,
  });

  final ThemeData theme;
  final bool loading;
  final String? error;
  final Map<String, dynamic>? inspect;
  final String text;
  final bool rawJson;
  final ValueChanged<bool> onToggleRaw;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            /// Creates a [_InspectTab] widget.
            const Spacer(),
            Text('Raw JSON', style: theme.textTheme.bodySmall),

            /// Creates a [_InspectTab] widget.
            const SizedBox(width: 8),
            Switch(value: rawJson, onChanged: onToggleRaw),
          ],
        ),

        /// Creates a [_InspectTab] widget.
        const SizedBox(height: 8),
        Expanded(
          child: _Panel(
            theme: theme,
            child: loading
                ? Text('Loading inspect data...', style: CalfTheme.muted(theme))
                : error != null
                ? Text(
                    error!,
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  )
                : rawJson
                ? SingleChildScrollView(
                    child: SelectableText(
                      text,
                      style: theme.textTheme.bodySmall!.copyWith(
                        fontFamily: 'Menlo',
                      ),
                    ),
                  )
                : _InspectFormattedView(theme: theme, inspect: inspect),
          ),
        ),
      ],
    );
  }
}

class _InspectFormattedView extends StatelessWidget {
  /// Creates a [_InspectFormattedView] widget.
  const _InspectFormattedView({required this.theme, required this.inspect});

  final ThemeData theme;
  final Map<String, dynamic>? inspect;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    if (inspect == null) {
      return Text('No inspect data available.', style: CalfTheme.muted(theme));
    }

    final sections = _buildInspectSections(inspect!);
    if (sections.isEmpty) {
      return Text(
        'No inspect sections available.',
        style: CalfTheme.muted(theme),
      );
    }

    return ListView.separated(
      itemCount: sections.length,
      separatorBuilder: (_, _) => const SizedBox(height: 20),
      itemBuilder: (context, index) {
        final section = sections[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              section.title,
              style: theme.textTheme.titleMedium!.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),

            /// Creates a [_InspectFormattedView] widget.
            const SizedBox(height: 12),
            for (
              var rowIndex = 0;
              rowIndex < section.rows.length;
              rowIndex++
            ) ...[
              if (rowIndex > 0)
                Divider(color: theme.colorScheme.outlineVariant, height: 1),

              /// Creates a [_InspectFormattedView] widget.
              const SizedBox(height: 10),
              _InspectRow(
                theme: theme,
                label: section.rows[rowIndex].label,
                value: section.rows[rowIndex].value,
              ),

              /// Creates a [_InspectFormattedView] widget.
              const SizedBox(height: 10),
            ],
          ],
        );
      },
    );
  }

  /// Extracts labeled inspect sections from raw JSON.
  List<_InspectSection> _buildInspectSections(Map<String, dynamic> payload) {
    final sections = <_InspectSection>[];

    final config = payload['Config'];
    if (config is Map<String, dynamic>) {
      final env = config['Env'];
      if (env is List) {
        final rows = <_InspectRowData>[];
        for (final item in env) {
          if (item is! String) {
            continue;
          }
          final separator = item.indexOf('=');
          if (separator <= 0) {
            rows.add(_InspectRowData(label: item, value: ''));
            continue;
          }
          rows.add(
            _InspectRowData(
              label: item.substring(0, separator),
              value: item.substring(separator + 1),
            ),
          );
        }
        if (rows.isNotEmpty) {
          sections.add(_InspectSection(title: 'Environment', rows: rows));
        }
      }

      final labels = config['Labels'];
      if (labels is Map) {
        final rows = labels.entries
            .map(
              (entry) => _InspectRowData(
                label: entry.key.toString(),
                value: entry.value.toString(),
              ),
            )
            .toList();
        if (rows.isNotEmpty) {
          sections.add(_InspectSection(title: 'Labels', rows: rows));
        }
      }
    }

    final network = payload['NetworkSettings'];
    if (network is Map<String, dynamic>) {
      final ports = network['Ports'];
      if (ports is Map) {
        final rows = ports.entries.map((entry) {
          final bindings = entry.value;
          var value = '';
          if (bindings is List &&
              bindings.isNotEmpty &&
              bindings.first is Map) {
            final host = bindings.first as Map;
            value = '${host['HostIp'] ?? ''}:${host['HostPort'] ?? ''}';
          }
          return _InspectRowData(label: entry.key.toString(), value: value);
        }).toList();
        if (rows.isNotEmpty) {
          sections.add(_InspectSection(title: 'Ports', rows: rows));
        }
      }
    }

    return sections;
  }
}

class _InspectSection {
  /// Creates a [_InspectSection] widget.
  const _InspectSection({required this.title, required this.rows});

  final String title;
  final List<_InspectRowData> rows;
}

class _InspectRowData {
  /// Creates a [_InspectRowData] widget.
  const _InspectRowData({required this.label, required this.value});

  final String label;
  final String value;
}

class _InspectRow extends StatelessWidget {
  /// Creates a [_InspectRow] widget.
  const _InspectRow({
    required this.theme,
    required this.label,
    required this.value,
  });

  final ThemeData theme;
  final String label;
  final String value;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: theme.textTheme.bodySmall!.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          flex: 4,
          child: SelectableText(value, style: theme.textTheme.bodySmall),
        ),
        CalfButton.ghost(
          width: 28,
          height: 28,
          onPressed: () => Clipboard.setData(ClipboardData(text: value)),
          child: Icon(
            LucideIcons.copy,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _MountsTab extends StatelessWidget {
  /// Creates a [_MountsTab] widget.
  const _MountsTab({
    required this.theme,
    required this.loading,
    required this.error,
    required this.mounts,
  });

  final ThemeData theme;
  final bool loading;
  final String? error;
  final List<ContainerMount> mounts;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    if (loading) {
      return _Panel(
        theme: theme,
        child: Text('Loading mounts...', style: CalfTheme.muted(theme)),
      );
    }
    if (error != null) {
      return _Panel(
        theme: theme,
        child: Text(
          error!,
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    }
    if (mounts.isEmpty) {
      return _Panel(
        theme: theme,
        child: Text('No mounts.', style: CalfTheme.muted(theme)),
      );
    }

    return _Panel(
      theme: theme,
      child: Column(
        children: [
          for (var index = 0; index < mounts.length; index++) ...[
            if (index > 0)
              Divider(color: theme.colorScheme.outlineVariant, height: 1),
            _MountRow(theme: theme, mount: mounts[index]),
          ],
        ],
      ),
    );
  }
}

class _MountRow extends StatelessWidget {
  /// Creates a single mount row with open and copy actions.
  const _MountRow({required this.theme, required this.mount});

  final ThemeData theme;
  final ContainerMount mount;

  /// Whether the host path can be opened in the system file manager.
  bool get _canOpenHostPath {
    if (mount.source.isEmpty) {
      return false;
    }
    final type = mount.type.toLowerCase();
    return type.isEmpty || type == 'bind';
  }

  /// Icon for the mount type (bind folder vs named volume).
  IconData get _typeIcon {
    final type = mount.type.toLowerCase();
    if (type == 'volume') {
      return LucideIcons.database;
    }
    return LucideIcons.folderSymlink;
  }

  /// Opens the host path in the system file manager when possible.
  Future<void> _openHostPath(BuildContext context) async {
    final opened = await openInFileExplorer(mount.source);
    if (!opened && context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (errorContext) => AlertDialog(
          title: const Text('Could not open path'),
          content: Text(
            'Your system could not open:\n${mount.source}',
          ),
          actions: [
            CalfButton(
              onPressed: () => Navigator.of(errorContext).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  /// Builds one mount mapping with open and copy actions.
  @override
  Widget build(BuildContext context) {
    final muted = theme.colorScheme.onSurfaceVariant;

    return HoverListRow(
      theme: theme,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(_typeIcon, size: 18, color: muted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (mount.name.isNotEmpty) ...[
                  Text(
                    mount.name,
                    style: CalfTheme.muted(theme).copyWith(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                ],
                MouseRegion(
                  cursor: _canOpenHostPath
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.basic,
                  child: GestureDetector(
                    onTap:
                        _canOpenHostPath ? () => _openHostPath(context) : null,
                    child: Text(
                      mount.source,
                      style: theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w500,
                        decoration: _canOpenHostPath
                            ? TextDecoration.underline
                            : TextDecoration.none,
                        decorationColor: theme.colorScheme.primary.withValues(
                          alpha: 0.35,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(LucideIcons.arrowDown, size: 12, color: muted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: SelectableText(
                        mount.destination,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          if (_canOpenHostPath)
            Tooltip(
              message: 'Open in file manager',
              child: CalfButton.ghost(
                width: 28,
                height: 28,
                onPressed: () => _openHostPath(context),
                child: Icon(LucideIcons.folderOpen, size: 16, color: muted),
              ),
            ),
          Tooltip(
            message: 'Copy host path',
            child: CalfButton.ghost(
              width: 28,
              height: 28,
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: mount.source)),
              child: Icon(LucideIcons.copy, size: 16, color: muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExecTab extends StatefulWidget {
  /// Creates a [_ExecTab] widget.
  const _ExecTab({
    required this.theme,
    required this.containerId,
    required this.apiClient,
    required this.isRunning,
  });

  final ThemeData theme;
  final String containerId;
  final CalfClient apiClient;
  final bool isRunning;

  /// Creates the mutable state for [_ExecTab].
  @override
  State<_ExecTab> createState() => _ExecTabState();
}

class _ExecTabState extends State<_ExecTab> {
  late final Terminal _terminal;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    _terminal = Terminal();
    if (widget.isRunning) {
      _connect();
    }
  }

  /// Refreshes local state when the parent widget changes.
  @override
  void didUpdateWidget(covariant _ExecTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRunning && !oldWidget.isRunning) {
      _connect();
    }
    if (!widget.isRunning && oldWidget.isRunning) {
      _disconnect();
    }
  }

  /// Opens the interactive exec WebSocket session.
  void _connect() {
    _disconnect();
    final uri = widget.apiClient.containerExecWebSocketUri(widget.containerId);
    _channel = WebSocketChannel.connect(uri);
    _terminal.onOutput = (data) {
      _channel?.sink.add(utf8.encode(data));
    };
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      final payload = jsonEncode({
        'type': 'resize',
        'rows': height,
        'cols': width,
      });
      _channel?.sink.add(payload);
    };
    _subscription = _channel!.stream.listen(
      (data) {
        if (data is String) {
          _terminal.write(data);
          return;
        }
        if (data is List<int>) {
          _terminal.write(utf8.decode(data, allowMalformed: true));
        }
      },
      onError: (error) {
        _terminal.write('\r\n[exec disconnected: $error]\r\n');
      },
      onDone: () {
        _terminal.write('\r\n[exec session closed]\r\n');
      },
    );
  }

  /// Closes the interactive exec WebSocket session.
  void _disconnect() {
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
  }

  /// Releases controllers, timers, and stream subscriptions.
  @override
  void dispose() {
    _disconnect();
    super.dispose();
  }

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    if (!widget.isRunning) {
      return _Panel(
        theme: widget.theme,
        child: Text(
          'Exec is available only for running containers.',
          style: CalfTheme.muted(widget.theme),
        ),
      );
    }

    final terminalTheme = _terminalThemeFor(widget.theme);

    return ExecPanel(
      terminal: _terminal,
      terminalTheme: terminalTheme,
      keyboardAppearance: widget.theme.brightness,
    );
  }
}

class _StatsTab extends StatelessWidget {
  /// Creates a [_StatsTab] widget.
  const _StatsTab({
    required this.theme,
    required this.isRunning,
    required this.loading,
    required this.error,
    required this.stats,
    required this.history,
  });

  final ThemeData theme;
  final bool isRunning;
  final bool loading;
  final String? error;
  final ContainerStats? stats;
  final _StatsHistory history;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    if (!isRunning) {
      return _Panel(
        theme: theme,
        child: Text(
          'Stats are available only for running containers.',
          style: CalfTheme.muted(theme),
        ),
      );
    }
    if (loading && stats == null) {
      return _Panel(
        theme: theme,
        child: Text('Loading stats...', style: CalfTheme.muted(theme)),
      );
    }
    if (error != null && stats == null) {
      return _Panel(
        theme: theme,
        child: Text(
          error!,
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    }
    if (stats == null) {
      return _Panel(
        theme: theme,
        child: Text('No stats available.', style: CalfTheme.muted(theme)),
      );
    }

    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.6,
      children: [
        _StatsChartCard(
          theme: theme,
          title: 'CPU usage: ${stats!.cpuPercent}',
          series: [
            _ChartSeries(
              label: 'CPU',
              color: theme.colorScheme.primary,
              values: history.cpu,
            ),
          ],
          formatY: (value) => '${value.toStringAsFixed(1)}%',
        ),
        _StatsChartCard(
          theme: theme,
          title: 'Memory usage: ${stats!.memUsage}',
          series: [
            _ChartSeries(
              label: 'Memory',
              color: theme.colorScheme.primary,
              values: history.memUsed,
            ),
          ],
          formatY: _formatBytes,
        ),
        _StatsChartCard(
          theme: theme,
          title: 'Disk read/write: ${stats!.blockIo}',
          series: [
            _ChartSeries(
              label: 'Data read',
              color: theme.colorScheme.primary,
              values: history.diskRead,
            ),
            _ChartSeries(
              label: 'Data write',
              color: const Color(0xFFF97316),
              values: history.diskWrite,
            ),
          ],
          formatY: _formatBytes,
        ),
        _StatsChartCard(
          theme: theme,
          title: 'Network I/O: ${stats!.netIo}',
          series: [
            _ChartSeries(
              label: 'Data received',
              color: theme.colorScheme.primary,
              values: history.netRx,
            ),
            _ChartSeries(
              label: 'Data sent',
              color: const Color(0xFFF97316),
              values: history.netTx,
            ),
          ],
          formatY: _formatBytes,
        ),
      ],
    );
  }
}

class _ChartSeries {
  /// Creates a [_ChartSeries] widget.
  const _ChartSeries({
    required this.label,
    required this.color,
    required this.values,
  });

  final String label;
  final Color color;
  final List<double> values;
}

class _StatsChartCard extends StatelessWidget {
  /// Creates a [_StatsChartCard] widget.
  const _StatsChartCard({
    required this.theme,
    required this.title,
    required this.series,
    required this.formatY,
  });

  final ThemeData theme;
  final String title;
  final List<_ChartSeries> series;
  final String Function(double value) formatY;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final maxValue = series
        .expand((item) => item.values)
        .fold<double>(0, (current, value) => value > current ? value : current);

    return _Panel(
      theme: theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: theme.textTheme.bodySmall!.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),

          /// Creates a [_StatsChartCard] widget.
          const SizedBox(height: 12),
          Expanded(
            child: LineChart(
              LineChartData(
                minY: 0,
                maxY: maxValue <= 0 ? 1 : maxValue * 1.2,
                clipData: const FlClipData.none(),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: theme.colorScheme.outlineVariant,
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      getTitlesWidget: (value, meta) => Text(
                        formatY(value),
                        style: CalfTheme.muted(theme).copyWith(fontSize: 10),
                      ),
                    ),
                  ),
                  bottomTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                lineTouchData: LineTouchData(
                  enabled: series.any((item) => item.values.isNotEmpty),
                  getTouchedSpotIndicator: (barData, spotIndexes) {
                    return [
                      for (final _ in spotIndexes)
                        TouchedSpotIndicatorData(
                          FlLine(
                            color: theme.colorScheme.outlineVariant,
                            strokeWidth: 1,
                          ),
                          FlDotData(
                            show: true,
                            getDotPainter: (spot, percent, bar, index) {
                              return FlDotCirclePainter(
                                radius: 4,
                                color: bar.color ?? theme.colorScheme.primary,
                                strokeWidth: 2,
                                strokeColor: theme.colorScheme.surface,
                              );
                            },
                          ),
                        ),
                    ];
                  },
                  touchTooltipData: LineTouchTooltipData(
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    maxContentWidth: 180,
                    tooltipRoundedRadius: 8,
                    tooltipMargin: 8,
                    tooltipPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    tooltipBorder: BorderSide(
                      color: theme.colorScheme.outlineVariant,
                    ),
                    getTooltipColor: (_) => theme.colorScheme.surface,
                    getTooltipItems: (spots) {
                      if (spots.isEmpty) {
                        return const [];
                      }

                      final labelStyle = theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                        height: 1.35,
                      );
                      final valueStyle = theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      );
                      final children = <TextSpan>[];
                      for (var i = 0; i < spots.length; i++) {
                        final spot = spots[i];
                        final seriesIndex = spot.barIndex.clamp(
                          0,
                          series.length - 1,
                        );
                        final item = series[seriesIndex];
                        children.add(
                          TextSpan(
                            text: item.label,
                            style: labelStyle.copyWith(color: item.color),
                          ),
                        );
                        children.add(
                          TextSpan(
                            text:
                                '  ${formatY(spot.y)}${i == spots.length - 1 ? '' : '\n'}',
                            style: valueStyle,
                          ),
                        );
                      }

                      return [
                        for (var i = 0; i < spots.length; i++)
                          i == 0
                              ? LineTooltipItem(
                                  '',
                                  valueStyle,
                                  textAlign: TextAlign.left,
                                  children: children,
                                )
                              : null,
                      ];
                    },
                  ),
                ),
                lineBarsData: [
                  for (final item in series)
                    LineChartBarData(
                      spots: [
                        for (var index = 0; index < item.values.length; index++)
                          FlSpot(index.toDouble(), item.values[index]),
                      ],
                      isCurved: false,
                      color: item.color,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                ],
              ),
            ),
          ),

          /// Creates a [_StatsChartCard] widget.
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            children: [
              for (final item in series)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 10, height: 10, color: item.color),

                    /// Creates a [_StatsChartCard] widget.
                    const SizedBox(width: 6),
                    Text(item.label, style: CalfTheme.muted(theme)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatsHistory {
  final cpu = <double>[];
  final memUsed = <double>[];
  final diskRead = <double>[];
  final diskWrite = <double>[];
  final netRx = <double>[];
  final netTx = <double>[];

  /// Replaces chart series from the server history window (and live snapshot).
  void replaceFrom(ContainerStats stats) {
    cpu.clear();
    memUsed.clear();
    diskRead.clear();
    diskWrite.clear();
    netRx.clear();
    netTx.clear();

    if (stats.samples.isNotEmpty) {
      for (final sample in stats.samples) {
        _appendSample(
          sample.cpuPercent,
          sample.memUsage,
          sample.blockIo,
          sample.netIo,
        );
      }
      return;
    }

    _appendSample(
      stats.cpuPercent,
      stats.memUsage,
      stats.blockIo,
      stats.netIo,
    );
  }

  /// Appends one parsed sample into the chart series buffers.
  void _appendSample(
    String cpuPercent,
    String memUsage,
    String blockIo,
    String netIo,
  ) {
    cpu.add(_parsePercent(cpuPercent));
    memUsed.add(_parsePair(memUsage).$1);
    final block = _parsePair(blockIo);
    diskRead.add(block.$1);
    diskWrite.add(block.$2);
    final net = _parsePair(netIo);
    netRx.add(net.$1);
    netTx.add(net.$2);
  }
}

/// Parse pair.
(double, double) _parsePair(String value) {
  final parts = value.split('/');
  if (parts.length != 2) {
    return (0, 0);
  }
  return (_parseDataSize(parts[0]), _parseDataSize(parts[1]));
}

/// Parses the input string into a typed value.
double _parsePercent(String value) {
  return double.tryParse(value.replaceAll('%', '').trim()) ?? 0;
}

/// Parses the input string into a typed value.
double _parseDataSize(String value) {
  final normalized = value.trim().toUpperCase();
  final match = RegExp(r'^([\d.]+)\s*([A-Z]+)?$').firstMatch(normalized);
  if (match == null) {
    return 0;
  }

  final amount = double.tryParse(match.group(1) ?? '') ?? 0;
  switch (match.group(2) ?? 'B') {
    case 'KB':
    case 'KIB':
      return amount * 1024;
    case 'MB':
    case 'MIB':
      return amount * 1024 * 1024;
    case 'GB':
    case 'GIB':
      return amount * 1024 * 1024 * 1024;
    case 'TB':
    case 'TIB':
      return amount * 1024 * 1024 * 1024 * 1024;
    default:
      return amount;
  }
}

/// Formats the value for display.
String _formatBytes(double value) {
  if (value >= 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }
  if (value >= 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
  if (value >= 1024) {
    return '${(value / 1024).toStringAsFixed(1)}KB';
  }
  return '${value.toStringAsFixed(0)}B';
}

/// Returns the themed background color for detail panels.
Color _panelBackgroundColor(ThemeData theme) {
  return Color.alphaBlend(
    theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
    theme.colorScheme.surface,
  );
}

const _lightTerminalTheme = TerminalTheme(
  cursor: Color(0xFF6B7280),
  selection: Color(0xFFB4D7FF),
  foreground: Color(0xFF1F2937),
  background: Color(0x00000000),
  black: Color(0xFF1F2937),
  red: Color(0xFFCD3131),
  green: Color(0xFF0D7D4D),
  yellow: Color(0xFFB58900),
  blue: Color(0xFF2472C8),
  magenta: Color(0xFFBC3FBC),
  cyan: Color(0xFF0E7490),
  white: Color(0xFFE5E7EB),
  brightBlack: Color(0xFF6B7280),
  brightRed: Color(0xFFE11D48),
  brightGreen: Color(0xFF059669),
  brightYellow: Color(0xFFD97706),
  brightBlue: Color(0xFF2563EB),
  brightMagenta: Color(0xFFC026D3),
  brightCyan: Color(0xFF0891B2),
  brightWhite: Color(0xFF111827),
  searchHitBackground: Color(0xFFFFF59D),
  searchHitBackgroundCurrent: Color(0xFFFFEB3B),
  searchHitForeground: Color(0xFF111827),
);

/// Builds a terminal color theme from the app theme.
TerminalTheme _terminalThemeFor(ThemeData theme) {
  final background = _panelBackgroundColor(theme);
  final foreground = theme.colorScheme.onSurface;
  final isLight = theme.brightness == Brightness.light;
  final base = isLight ? _lightTerminalTheme : TerminalThemes.defaultTheme;

  return TerminalTheme(
    cursor: theme.colorScheme.onSurface,
    selection: isLight
        ? theme.colorScheme.primary.withValues(alpha: 0.25)
        : theme.colorScheme.primary.withValues(alpha: 0.35),
    foreground: foreground,
    background: background,
    black: isLight ? base.black : foreground,
    red: base.red,
    green: base.green,
    yellow: base.yellow,
    blue: base.blue,
    magenta: base.magenta,
    cyan: base.cyan,
    white: isLight ? base.white : theme.colorScheme.onSurfaceVariant,
    brightBlack: isLight
        ? base.brightBlack
        : theme.colorScheme.onSurfaceVariant,
    brightRed: base.brightRed,
    brightGreen: base.brightGreen,
    brightYellow: base.brightYellow,
    brightBlue: base.brightBlue,
    brightMagenta: base.brightMagenta,
    brightCyan: base.brightCyan,
    brightWhite: foreground,
    searchHitBackground: base.searchHitBackground,
    searchHitBackgroundCurrent: base.searchHitBackgroundCurrent,
    searchHitForeground: base.searchHitForeground,
  );
}

/// Returns the status color for the given container.
Color _containerIconColor(ContainerItem container, ThemeData theme) {
  if (container.isRunning) {
    return CalfColors.success;
  }
  final state = container.state.toLowerCase();
  if (state == 'created' || state == 'restarting') {
    return CalfColors.warning;
  }
  if (container.status.toLowerCase().contains('restarting')) {
    return CalfColors.warning;
  }
  return theme.colorScheme.onSurfaceVariant;
}
