import 'dart:async';
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart' show Divider, SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/calf_tab_bar.dart';
import 'package:ui/widgets/detail_breadcrumb.dart';
import 'package:ui/widgets/files_panel.dart';
import 'package:ui/widgets/logs_panel.dart';

enum _ContainerDetailTab { logs, inspect, mounts, exec, files, stats }

const _maxLogLines = 2000;

class ContainerDetailView extends StatefulWidget {
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

  @override
  void initState() {
    super.initState();
    _container = widget.container;
    _loadTabData();
  }

  @override
  void dispose() {
    _logsSubscription?.cancel();
    _logsScrollController.dispose();
    _statsTimer?.cancel();
    super.dispose();
  }

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

  void _selectTab(_ContainerDetailTab tab) {
    if (_tab == tab) {
      return;
    }
    setState(() => _tab = tab);
    _loadTabData();
  }

  void _stopTabBackgroundWork() {
    _logsSubscription?.cancel();
    _logsSubscription = null;
    _statsTimer?.cancel();
    _statsTimer = null;
  }

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

  void _startLogs() {
    setState(() {
      _logLines.clear();
      _logsError = null;
    });

    _logsSubscription = widget.apiClient.streamContainerLogs(_container.id).listen(
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
            _logsScrollController.jumpTo(_logsScrollController.position.maxScrollExtent);
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

  void _startStats() {
    _logsSubscription?.cancel();
    _statsTimer?.cancel();
    _refreshStats();
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) => _refreshStats());
  }

  Future<void> _refreshStats() async {
    if (!_container.isRunning) {
      if (!mounted) {
        return;
      }
      setState(() {
        _stats = null;
        _statsError = 'Stats are available only for running containers.';
        _statsLoading = false;
      });
      return;
    }

    setState(() {
      _statsLoading = _stats == null;
      _statsError = null;
    });

    try {
      final stats = await widget.apiClient.fetchContainerStats(_container.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _stats = stats;
        _statsHistory.add(stats);
        _statsLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statsError = error.toString();
        _statsLoading = false;
      });
    }
  }

  Map<String, dynamic>? _decodeInspectMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return null;
  }

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

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final port = _container.primaryHostPort;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailBreadcrumb(
          segments: ['Containers', _container.displayName],
          onBack: widget.onBack,
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(LucideIcons.box, size: 28, color: _containerIconColor(_container, theme)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_container.displayName, style: theme.textTheme.h3),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(_container.shortId, style: theme.textTheme.muted),
                      Text(_container.displayImage, style: theme.textTheme.muted),
                      if (port != null)
                        GestureDetector(
                          onTap: () => openPort(port),
                          child: Text(
                            '$port:$port',
                            style: theme.textTheme.small.copyWith(color: theme.colorScheme.primary),
                          ),
                        )
                      else
                        Text(_container.displayPorts, style: theme.textTheme.muted),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('STATUS', style: theme.textTheme.small.copyWith(color: theme.colorScheme.mutedForeground)),
                Text(_container.status, style: theme.textTheme.small),
                const SizedBox(height: 8),
                Row(
                  children: [
                    CalfButton.outline(
                      enabled: !_busy && _container.isRunning,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      onPressed: _container.isRunning ? () => _runAction(() => widget.apiClient.stopContainer(_container.id)) : null,
                      child: Icon(LucideIcons.square, size: 16, color: theme.colorScheme.foreground),
                    ),
                    const SizedBox(width: 8),
                    CalfButton(
                      enabled: !_busy && !_container.isRunning,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      onPressed: !_container.isRunning ? () => _runAction(() => widget.apiClient.startContainer(_container.id)) : null,
                      child: Icon(LucideIcons.play, size: 16, color: theme.colorScheme.primaryForeground),
                    ),
                    const SizedBox(width: 8),
                    CalfButton(
                      enabled: !_busy,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      onPressed: () => _runAction(() => widget.apiClient.restartContainer(_container.id)),
                      child: Icon(LucideIcons.rotateCw, size: 16, color: theme.colorScheme.primaryForeground),
                    ),
                    const SizedBox(width: 8),
                    CalfButton.destructive(
                      enabled: !_busy,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      onPressed: () async {
                        await _runAction(() => widget.apiClient.removeContainer(_container.id));
                        if (mounted) {
                          widget.onBack();
                        }
                      },
                      child: Icon(LucideIcons.trash2, size: 16, color: theme.colorScheme.destructiveForeground),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive)),
        ],
        const SizedBox(height: 16),
        CalfTabBar(
          theme: theme,
          labels: const ['Logs', 'Inspect', 'Bind mounts', 'Exec', 'Files', 'Stats'],
          selectedIndex: _tab.index,
          onSelected: (index) => _selectTab(_ContainerDetailTab.values[index]),
        ),
        const SizedBox(height: 12),
        Expanded(child: _buildTabContent(theme)),
      ],
    );
  }

  Widget _buildTabContent(ShadThemeData theme) {
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
        return _MountsTab(theme: theme, loading: _mountsLoading, error: _mountsError, mounts: _mounts);
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
          loadDirectory: (path) => widget.apiClient.fetchContainerFiles(_container.id, path: path),
        );
      case _ContainerDetailTab.stats:
        return _StatsTab(
          theme: theme,
          loading: _statsLoading,
          error: _statsError,
          stats: _stats,
          history: _statsHistory,
        );
    }
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.theme, required this.child});

  final ShadThemeData theme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.border),
        borderRadius: theme.radius,
        color: _panelBackgroundColor(theme),
      ),
      padding: const EdgeInsets.all(12),
      child: child,
    );
  }
}

class _InspectTab extends StatelessWidget {
  const _InspectTab({
    required this.theme,
    required this.loading,
    required this.error,
    required this.inspect,
    required this.text,
    required this.rawJson,
    required this.onToggleRaw,
  });

  final ShadThemeData theme;
  final bool loading;
  final String? error;
  final Map<String, dynamic>? inspect;
  final String text;
  final bool rawJson;
  final ValueChanged<bool> onToggleRaw;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Spacer(),
            Text('Raw JSON', style: theme.textTheme.small),
            const SizedBox(width: 8),
            ShadSwitch(value: rawJson, onChanged: onToggleRaw),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _Panel(
            theme: theme,
            child: loading
                ? Text('Loading inspect data...', style: theme.textTheme.muted)
                : error != null
                    ? Text(error!, style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive))
                    : rawJson
                        ? SingleChildScrollView(
                            child: SelectableText(
                              text,
                              style: theme.textTheme.small.copyWith(fontFamily: 'Menlo'),
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
  const _InspectFormattedView({
    required this.theme,
    required this.inspect,
  });

  final ShadThemeData theme;
  final Map<String, dynamic>? inspect;

  @override
  Widget build(BuildContext context) {
    if (inspect == null) {
      return Text('No inspect data available.', style: theme.textTheme.muted);
    }

    final sections = _buildInspectSections(inspect!);
    if (sections.isEmpty) {
      return Text('No inspect sections available.', style: theme.textTheme.muted);
    }

    return ListView.separated(
      itemCount: sections.length,
      separatorBuilder: (_, _) => const SizedBox(height: 20),
      itemBuilder: (context, index) {
        final section = sections[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(section.title, style: theme.textTheme.large.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            for (var rowIndex = 0; rowIndex < section.rows.length; rowIndex++) ...[
              if (rowIndex > 0) Divider(color: theme.colorScheme.border, height: 1),
              const SizedBox(height: 10),
              _InspectRow(theme: theme, label: section.rows[rowIndex].label, value: section.rows[rowIndex].value),
              const SizedBox(height: 10),
            ],
          ],
        );
      },
    );
  }

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
          rows.add(_InspectRowData(
            label: item.substring(0, separator),
            value: item.substring(separator + 1),
          ));
        }
        if (rows.isNotEmpty) {
          sections.add(_InspectSection(title: 'Environment', rows: rows));
        }
      }

      final labels = config['Labels'];
      if (labels is Map) {
        final rows = labels.entries
            .map((entry) => _InspectRowData(label: entry.key.toString(), value: entry.value.toString()))
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
          if (bindings is List && bindings.isNotEmpty && bindings.first is Map) {
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
  const _InspectSection({required this.title, required this.rows});

  final String title;
  final List<_InspectRowData> rows;
}

class _InspectRowData {
  const _InspectRowData({required this.label, required this.value});

  final String label;
  final String value;
}

class _InspectRow extends StatelessWidget {
  const _InspectRow({
    required this.theme,
    required this.label,
    required this.value,
  });

  final ShadThemeData theme;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(label, style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600)),
        ),
        Expanded(
          flex: 4,
          child: SelectableText(value, style: theme.textTheme.small),
        ),
        CalfButton.ghost(
          padding: const EdgeInsets.all(6),
          onPressed: () => Clipboard.setData(ClipboardData(text: value)),
          child: Icon(LucideIcons.copy, size: 16, color: theme.colorScheme.mutedForeground),
        ),
      ],
    );
  }
}

class _MountsTab extends StatelessWidget {
  const _MountsTab({
    required this.theme,
    required this.loading,
    required this.error,
    required this.mounts,
  });

  final ShadThemeData theme;
  final bool loading;
  final String? error;
  final List<ContainerMount> mounts;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return _Panel(theme: theme, child: Text('Loading bind mounts...', style: theme.textTheme.muted));
    }
    if (error != null) {
      return _Panel(theme: theme, child: Text(error!, style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive)));
    }
    if (mounts.isEmpty) {
      return _Panel(theme: theme, child: Text('No bind mounts.', style: theme.textTheme.muted));
    }

    return _Panel(
      theme: theme,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text('Source (Host)', style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600))),
              Expanded(child: Text('Destination (Container)', style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600))),
            ],
          ),
          const SizedBox(height: 8),
          Divider(color: theme.colorScheme.border, height: 1),
          for (final mount in mounts) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(mount.source, style: theme.textTheme.small.copyWith(color: theme.colorScheme.primary))),
                Expanded(child: Text(mount.destination, style: theme.textTheme.small)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ExecTab extends StatefulWidget {
  const _ExecTab({
    required this.theme,
    required this.containerId,
    required this.apiClient,
    required this.isRunning,
  });

  final ShadThemeData theme;
  final String containerId;
  final CalfClient apiClient;
  final bool isRunning;

  @override
  State<_ExecTab> createState() => _ExecTabState();
}

class _ExecTabState extends State<_ExecTab> {
  late final Terminal _terminal;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal();
    if (widget.isRunning) {
      _connect();
    }
  }

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

  void _connect() {
    _disconnect();
    final uri = widget.apiClient.containerExecWebSocketUri(widget.containerId);
    _channel = WebSocketChannel.connect(uri);
    _terminal.onOutput = (data) {
      _channel?.sink.add(utf8.encode(data));
    };
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      final payload = jsonEncode({'type': 'resize', 'rows': height, 'cols': width});
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

  void _disconnect() {
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
  }

  @override
  void dispose() {
    _disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isRunning) {
      return _Panel(
        theme: widget.theme,
        child: Text('Exec is available only for running containers.', style: widget.theme.textTheme.muted),
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
  const _StatsTab({
    required this.theme,
    required this.loading,
    required this.error,
    required this.stats,
    required this.history,
  });

  final ShadThemeData theme;
  final bool loading;
  final String? error;
  final ContainerStats? stats;
  final _StatsHistory history;

  @override
  Widget build(BuildContext context) {
    if (loading && stats == null) {
      return _Panel(theme: theme, child: Text('Loading stats...', style: theme.textTheme.muted));
    }
    if (error != null && stats == null) {
      return _Panel(theme: theme, child: Text(error!, style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive)));
    }
    if (stats == null) {
      return _Panel(theme: theme, child: Text('No stats available.', style: theme.textTheme.muted));
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
            _ChartSeries(label: 'CPU', color: theme.colorScheme.primary, values: history.cpu),
          ],
          formatY: (value) => '${value.toStringAsFixed(1)}%',
        ),
        _StatsChartCard(
          theme: theme,
          title: 'Memory usage: ${stats!.memUsage}',
          series: [
            _ChartSeries(label: 'Memory', color: theme.colorScheme.primary, values: history.memUsed),
          ],
          formatY: _formatBytes,
        ),
        _StatsChartCard(
          theme: theme,
          title: 'Disk read/write: ${stats!.blockIo}',
          series: [
            _ChartSeries(label: 'Data read', color: theme.colorScheme.primary, values: history.diskRead),
            _ChartSeries(label: 'Data write', color: const Color(0xFFF97316), values: history.diskWrite),
          ],
          formatY: _formatBytes,
        ),
        _StatsChartCard(
          theme: theme,
          title: 'Network I/O: ${stats!.netIo}',
          series: [
            _ChartSeries(label: 'Data received', color: theme.colorScheme.primary, values: history.netRx),
            _ChartSeries(label: 'Data sent', color: const Color(0xFFF97316), values: history.netTx),
          ],
          formatY: _formatBytes,
        ),
      ],
    );
  }
}

class _ChartSeries {
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
  const _StatsChartCard({
    required this.theme,
    required this.title,
    required this.series,
    required this.formatY,
  });

  final ShadThemeData theme;
  final String title;
  final List<_ChartSeries> series;
  final String Function(double value) formatY;

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
          Text(title, style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Expanded(
            child: LineChart(
              LineChartData(
                minY: 0,
                maxY: maxValue <= 0 ? 1 : maxValue * 1.2,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) => FlLine(color: theme.colorScheme.border, strokeWidth: 1),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      getTitlesWidget: (value, meta) => Text(
                        formatY(value),
                        style: theme.textTheme.muted.copyWith(fontSize: 10),
                      ),
                    ),
                  ),
                  bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
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
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            children: [
              for (final item in series)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 10, height: 10, color: item.color),
                    const SizedBox(width: 6),
                    Text(item.label, style: theme.textTheme.muted),
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
  static const _maxPoints = 60;

  final cpu = <double>[];
  final memUsed = <double>[];
  final diskRead = <double>[];
  final diskWrite = <double>[];
  final netRx = <double>[];
  final netTx = <double>[];

  void add(ContainerStats stats) {
    _append(cpu, _parsePercent(stats.cpuPercent));
    _append(memUsed, _parsePair(stats.memUsage).$1);
    final block = _parsePair(stats.blockIo);
    _append(diskRead, block.$1);
    _append(diskWrite, block.$2);
    final net = _parsePair(stats.netIo);
    _append(netRx, net.$1);
    _append(netTx, net.$2);
  }

  void _append(List<double> target, double value) {
    target.add(value);
    if (target.length > _maxPoints) {
      target.removeAt(0);
    }
  }
}

(double, double) _parsePair(String value) {
  final parts = value.split('/');
  if (parts.length != 2) {
    return (0, 0);
  }
  return (_parseDataSize(parts[0]), _parseDataSize(parts[1]));
}

double _parsePercent(String value) {
  return double.tryParse(value.replaceAll('%', '').trim()) ?? 0;
}

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

Color _panelBackgroundColor(ShadThemeData theme) {
  return Color.alphaBlend(
    theme.colorScheme.muted.withValues(alpha: 0.2),
    theme.colorScheme.background,
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

TerminalTheme _terminalThemeFor(ShadThemeData theme) {
  final background = _panelBackgroundColor(theme);
  final foreground = theme.colorScheme.foreground;
  final isLight = theme.brightness == Brightness.light;
  final base = isLight ? _lightTerminalTheme : TerminalThemes.defaultTheme;

  return TerminalTheme(
    cursor: theme.colorScheme.foreground,
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
    white: isLight ? base.white : theme.colorScheme.mutedForeground,
    brightBlack: isLight ? base.brightBlack : theme.colorScheme.mutedForeground,
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

Color _containerIconColor(ContainerItem container, ShadThemeData theme) {
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
  return theme.colorScheme.mutedForeground;
}
