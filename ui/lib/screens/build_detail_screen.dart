import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart' show BoxDecoration, BoxShadow, PopupMenuItem, RelativeRect, SelectableText, showMenu;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/hover_list_row.dart';

enum _BuildDetailTab { info, source, logs, history }

class BuildDetailView extends StatefulWidget {
  const BuildDetailView({
    super.key,
    required this.buildId,
    required this.apiClient,
    required this.onBack,
    this.onOpenBuild,
  });

  final String buildId;
  final CalfClient apiClient;
  final VoidCallback onBack;
  final ValueChanged<String>? onOpenBuild;

  @override
  State<BuildDetailView> createState() => _BuildDetailViewState();
}

class _BuildDetailViewState extends State<BuildDetailView> {
  _BuildDetailTab _tab = _BuildDetailTab.info;
  BuildDetail? _detail;
  BuildSource? _source;
  List<BuildItem> _history = [];
  bool _detailLoading = true;
  bool _sourceLoading = false;
  bool _historyLoading = false;
  String? _detailError;
  String? _sourceError;
  String? _historyError;
  bool _logsLoading = false;
  String? _logsError;
  BuildLogs? _logs;
  String _platformFilter = '';
  final Set<int> _expandedSteps = {};
  bool _plainLogs = false;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() {
      _detailLoading = true;
      _detailError = null;
    });

    try {
      final detail = await widget.apiClient.fetchBuildDetail(widget.buildId);
      if (!mounted) {
        return;
      }
      setState(() {
        _detail = detail;
        _detailLoading = false;
        if (_platformFilter.isEmpty && detail.platform.isNotEmpty) {
          _platformFilter = detail.platform;
        }
      });
      if (_tab == _BuildDetailTab.history) {
        await _loadHistory(tagOverride: detail.tag);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _detailError = error.toString();
        _detailLoading = false;
      });
    }
  }

  Future<void> _loadSource() async {
    setState(() {
      _sourceLoading = true;
      _sourceError = null;
    });

    try {
      final source = await widget.apiClient.fetchBuildSource(widget.buildId);
      if (!mounted) {
        return;
      }
      setState(() {
        _source = source;
        _sourceLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _sourceError = error.toString();
        _sourceLoading = false;
      });
    }
  }

  Future<void> _loadHistory({String? tagOverride}) async {
    final tag = tagOverride ?? _detail?.tag;
    if (tag == null || tag.isEmpty) {
      return;
    }

    setState(() {
      _historyLoading = true;
      _historyError = null;
    });

    try {
      final history = await widget.apiClient.fetchBuilds(tag: tag);
      if (!mounted) {
        return;
      }
      final detail = _detail;
      setState(() {
        _history = history.isNotEmpty
            ? history
            : detail != null
                ? [detail]
                : const [];
        _historyLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _historyError = error.toString();
        _historyLoading = false;
      });
    }
  }

  Future<void> _loadLogs() async {
    final detail = _detail;
    if (detail != null && (detail.rawLog.isNotEmpty || detail.steps.isNotEmpty)) {
      return;
    }
    if (_logs != null || _logsLoading) {
      return;
    }

    setState(() {
      _logsLoading = true;
      _logsError = null;
    });

    try {
      final logs = await widget.apiClient.fetchBuildLogs(widget.buildId);
      if (!mounted) {
        return;
      }
      setState(() {
        _logs = logs;
        _logsLoading = false;
        if (logs.steps.isEmpty && logs.rawLog.isNotEmpty) {
          _plainLogs = true;
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _logsError = error.toString();
        _logsLoading = false;
      });
    }
  }

  void _selectTab(_BuildDetailTab tab) {
    if (_tab == tab) {
      return;
    }

    setState(() => _tab = tab);
    if (tab == _BuildDetailTab.source && _source == null) {
      _loadSource();
    }
    if (tab == _BuildDetailTab.history) {
      _loadHistory();
    }
    if (tab == _BuildDetailTab.logs) {
      _loadLogs();
    }
  }

  Future<void> _copyText(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final detail = _detail;

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
            Text('Builds', style: theme.textTheme.muted),
            Text(' / ', style: theme.textTheme.muted),
            Expanded(
              child: Text(
                detail?.tag ?? widget.buildId,
                style: theme.textTheme.muted,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_detailLoading)
          Text('Loading...', style: theme.textTheme.muted)
        else if (_detailError != null)
          Text(_detailError!, style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive))
        else if (detail != null) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(detail.tag, style: theme.textTheme.h3),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(detail.id, style: theme.textTheme.muted),
                        const SizedBox(width: 8),
                        CalfButton.ghost(
                          padding: const EdgeInsets.all(4),
                          onPressed: () => _copyText(detail.id),
                          child: Icon(LucideIcons.copy, size: 14, color: theme.colorScheme.mutedForeground),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _SummaryColumn(theme: theme, label: 'Status', value: _statusLabel(detail.status), color: _statusColor(detail.status, theme)),
              const SizedBox(width: 24),
              _SummaryColumn(theme: theme, label: 'Duration', value: _formatDuration(detail.durationMs)),
              const SizedBox(width: 24),
              _SummaryColumn(theme: theme, label: 'Builder', value: detail.builder, link: true),
            ],
          ),
          const SizedBox(height: 16),
          _BuildTabBar(theme: theme, selected: _tab, onSelected: _selectTab),
          const SizedBox(height: 16),
          Expanded(child: _buildTabContent(theme, detail)),
        ],
      ],
    );
  }

  Widget _buildTabContent(ShadThemeData theme, BuildDetail detail) {
    switch (_tab) {
      case _BuildDetailTab.info:
        return _InfoTab(
          theme: theme,
          detail: detail,
          platformFilter: _platformFilter,
          onPlatformChanged: (value) => setState(() => _platformFilter = value),
          onCopy: _copyText,
        );
      case _BuildDetailTab.source:
        return _SourceTab(
          theme: theme,
          loading: _sourceLoading,
          error: _sourceError,
          source: _source,
          detail: detail,
        );
      case _BuildDetailTab.logs:
        return _LogsTab(
          theme: theme,
          detail: detail,
          rawLog: _logs?.rawLog ?? detail.rawLog,
          steps: _logs?.steps ?? detail.steps,
          loading: _logsLoading,
          error: _logsError,
          plainLogs: _plainLogs,
          expandedSteps: _expandedSteps,
          onTogglePlain: (value) => setState(() => _plainLogs = value),
          onToggleStep: (index) {
            setState(() {
              if (_expandedSteps.contains(index)) {
                _expandedSteps.remove(index);
              } else {
                _expandedSteps.add(index);
              }
            });
          },
        );
      case _BuildDetailTab.history:
        return _HistoryTab(
          theme: theme,
          loading: _historyLoading,
          error: _historyError,
          history: _history,
          currentId: detail.id,
          onOpenBuild: widget.onOpenBuild,
        );
    }
  }
}

class _SummaryColumn extends StatelessWidget {
  const _SummaryColumn({
    required this.theme,
    required this.label,
    required this.value,
    this.color,
    this.link = false,
  });

  final ShadThemeData theme;
  final String label;
  final String value;
  final Color? color;
  final bool link;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(label, style: theme.textTheme.small.copyWith(color: theme.colorScheme.mutedForeground)),
        const SizedBox(height: 4),
        Text(
          value,
          style: theme.textTheme.large.copyWith(
            color: color ?? (link ? theme.colorScheme.primary : theme.colorScheme.foreground),
          ),
        ),
      ],
    );
  }
}

class _BuildTabBar extends StatelessWidget {
  const _BuildTabBar({
    required this.theme,
    required this.selected,
    required this.onSelected,
  });

  final ShadThemeData theme;
  final _BuildDetailTab selected;
  final ValueChanged<_BuildDetailTab> onSelected;

  @override
  Widget build(BuildContext context) {
    const tabs = _BuildDetailTab.values;
    const labels = ['Info', 'Source', 'Logs', 'History'];

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colorScheme.border)),
      ),
      child: Row(
        children: [
          for (var index = 0; index < tabs.length; index++) ...[
            if (index > 0) const SizedBox(width: 20),
            _BuildTabButton(
              theme: theme,
              label: labels[index],
              selected: selected == tabs[index],
              onTap: () => onSelected(tabs[index]),
            ),
          ],
        ],
      ),
    );
  }
}

class _BuildTabButton extends StatelessWidget {
  const _BuildTabButton({
    required this.theme,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final ShadThemeData theme;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? theme.colorScheme.primary : const Color(0x00000000),
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.large.copyWith(
            color: selected ? theme.colorScheme.foreground : theme.colorScheme.mutedForeground,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _InfoTab extends StatelessWidget {
  const _InfoTab({
    required this.theme,
    required this.detail,
    required this.platformFilter,
    required this.onPlatformChanged,
    required this.onCopy,
  });

  final ShadThemeData theme;
  final BuildDetail detail;
  final String platformFilter;
  final ValueChanged<String> onPlatformChanged;
  final Future<void> Function(String value) onCopy;

  @override
  Widget build(BuildContext context) {
    final platforms = <String>{
      if (detail.platform.isNotEmpty) detail.platform,
      ...detail.dependencies.map((item) => item.platform).where((item) => item.isNotEmpty),
      ...detail.results.map((item) => item.platform).where((item) => item.isNotEmpty),
    }.toList()
      ..sort();

    final filterArch = _platformArch(platformFilter);
    final dependencies = detail.dependencies.where((item) {
      if (filterArch.isEmpty) {
        return true;
      }
      return item.platform.isEmpty || item.platform == filterArch;
    }).toList();
    final results = detail.results.where((item) {
      if (filterArch.isEmpty) {
        return true;
      }
      return item.platform.isEmpty || item.platform == filterArch;
    }).toList();

    return ListView(
      children: [
        _SectionHeader(
          theme: theme,
          title: 'Source details',
          trailing: platforms.isEmpty
              ? null
              : _PlatformFilter(
                  theme: theme,
                  value: platformFilter,
                  options: platforms,
                  onChanged: onPlatformChanged,
                ),
        ),
        _InfoRow(theme: theme, label: 'File name', value: detail.dockerfile),
        _InfoRow(theme: theme, label: 'Remote source location', value: detail.remoteSource, link: true),
        _InfoRow(theme: theme, label: 'Revision', value: detail.sourceRevision),
        _InfoRow(theme: theme, label: 'Dockerfile', value: detail.dockerfile),
        const SizedBox(height: 24),
        _SectionHeader(theme: theme, title: 'Build timing'),
        const SizedBox(height: 12),
        _TimingCharts(theme: theme, timing: detail.timing, totalMs: detail.durationMs, cachedSteps: detail.cachedSteps, totalSteps: detail.totalSteps),
        const SizedBox(height: 24),
        _SectionHeader(theme: theme, title: 'Dependencies'),
        _DataTable(
          theme: theme,
          columns: const ['Source', 'Platform', 'Digest'],
          rows: dependencies
              .map(
                (item) => [
                  item.source,
                  item.platform,
                  item.digest,
                ],
              )
              .toList(),
          onCopy: onCopy,
        ),
        const SizedBox(height: 24),
        _SectionHeader(theme: theme, title: 'Build results'),
        _DataTable(
          theme: theme,
          columns: const ['Artifact', 'Platform', 'Digest', 'Size'],
          rows: results
              .map(
                (item) => [
                  item.name,
                  item.platform,
                  item.digest,
                  item.size,
                ],
              )
              .toList(),
          onCopy: onCopy,
        ),
        const SizedBox(height: 24),
        _SectionHeader(theme: theme, title: 'Tags'),
        _DataTable(
          theme: theme,
          columns: const ['Tags', 'Digest'],
          rows: detail.tags.map((item) => [item.tag, item.digest]).toList(),
          onCopy: onCopy,
        ),
      ],
    );
  }
}

class _PlatformFilter extends StatelessWidget {
  const _PlatformFilter({
    required this.theme,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final ShadThemeData theme;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Filter by platform', style: theme.textTheme.small),
        const SizedBox(width: 8),
        CalfButton.outline(
          onPressed: () async {
            final selected = await showMenu<String>(
              context: context,
              position: const RelativeRect.fromLTRB(0, 0, 0, 0),
              items: options
                  .map((option) => PopupMenuItem<String>(value: option, child: Text(option)))
                  .toList(),
            );
            if (selected != null) {
              onChanged(selected);
            }
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(value, style: theme.textTheme.small),
              const SizedBox(width: 4),
              Icon(LucideIcons.chevronDown, size: 14, color: theme.colorScheme.foreground),
            ],
          ),
        ),
      ],
    );
  }
}

class _TimingCharts extends StatelessWidget {
  const _TimingCharts({
    required this.theme,
    required this.timing,
    required this.totalMs,
    required this.cachedSteps,
    required this.totalSteps,
  });

  final ShadThemeData theme;
  final BuildTiming timing;
  final int totalMs;
  final int cachedSteps;
  final int totalSteps;

  @override
  Widget build(BuildContext context) {
    final realTime = _timingSlices(timing);
    final cacheSlices = [
      _TimingSlice('Executions', totalSteps.toDouble(), const Color(0xFF3B82F6)),
      _TimingSlice('Cached steps', cachedSteps.toDouble(), const Color(0xFF22C55E)),
      _TimingSlice('Other steps', (totalSteps - cachedSteps).toDouble().clamp(0, double.infinity), theme.colorScheme.mutedForeground),
    ];

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.4,
      children: [
        _TimingChartCard(
          theme: theme,
          title: 'Real time (${_formatDuration(totalMs)})',
          slices: realTime,
          formatValue: (value) => _formatDuration(value.toInt()),
        ),
        _TimingChartCard(
          theme: theme,
          title: 'Accumulated time (${_formatDuration(totalMs)})',
          slices: realTime,
          formatValue: (value) => _formatDuration(value.toInt()),
        ),
        _TimingChartCard(
          theme: theme,
          title: 'Cache usage ($cachedSteps/$totalSteps)',
          slices: cacheSlices,
          formatValue: (value) => '${value.toInt()}',
        ),
        _TimingChartCard(
          theme: theme,
          title: 'Parallel execution',
          slices: [
            _TimingSlice('Active', totalMs > 0 ? totalMs.toDouble() : 1, const Color(0xFF3B82F6)),
            _TimingSlice('Idle', timing.idleMs.toDouble(), theme.colorScheme.mutedForeground),
          ],
          formatValue: (value) => _formatDuration(value.toInt()),
        ),
      ],
    );
  }

  List<_TimingSlice> _timingSlices(BuildTiming timing) {
    return [
      _TimingSlice('Local file transfers', timing.localTransfersMs.toDouble(), const Color(0xFF166534)),
      _TimingSlice('Image pulls', timing.imagePullsMs.toDouble(), const Color(0xFF4ADE80)),
      _TimingSlice('Executions', timing.executionsMs.toDouble(), const Color(0xFF3B82F6)),
      _TimingSlice('File operations', timing.fileOperationsMs.toDouble(), const Color(0xFFEF4444)),
      _TimingSlice('Result exports', timing.resultExportsMs.toDouble(), const Color(0xFFA855F7)),
      _TimingSlice('Idle', timing.idleMs.toDouble(), theme.colorScheme.mutedForeground),
    ].where((slice) => slice.value > 0).toList();
  }
}

class _TimingSlice {
  const _TimingSlice(this.label, this.value, this.color);

  final String label;
  final double value;
  final Color color;
}

class _TimingChartCard extends StatefulWidget {
  const _TimingChartCard({
    required this.theme,
    required this.title,
    required this.slices,
    required this.formatValue,
  });

  final ShadThemeData theme;
  final String title;
  final List<_TimingSlice> slices;
  final String Function(double value) formatValue;

  @override
  State<_TimingChartCard> createState() => _TimingChartCardState();
}

class _TimingChartCardState extends State<_TimingChartCard> {
  int? _touchedIndex;

  @override
  Widget build(BuildContext context) {
    final total = widget.slices.fold<double>(0, (sum, slice) => sum + slice.value);
    final touchedSlice = _touchedIndex != null &&
            _touchedIndex! >= 0 &&
            _touchedIndex! < widget.slices.length
        ? widget.slices[_touchedIndex!]
        : null;
    final touchedPercent = touchedSlice != null && total > 0
        ? (touchedSlice.value / total * 100).toStringAsFixed(1)
        : null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: widget.theme.colorScheme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: widget.theme.textTheme.small.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Expanded(
            child: total <= 0
                ? Center(child: Text('No timing data', style: widget.theme.textTheme.muted))
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(
                        PieChartData(
                          sectionsSpace: 1,
                          centerSpaceRadius: 28,
                          pieTouchData: PieTouchData(
                            enabled: true,
                            touchCallback: (event, response) {
                              setState(() {
                                if (!event.isInterestedForInteractions ||
                                    response == null ||
                                    response.touchedSection == null) {
                                  _touchedIndex = null;
                                  return;
                                }
                                _touchedIndex = response.touchedSection!.touchedSectionIndex;
                              });
                            },
                          ),
                          sections: [
                            for (var index = 0; index < widget.slices.length; index++)
                              PieChartSectionData(
                                value: widget.slices[index].value,
                                color: widget.slices[index].color,
                                radius: _touchedIndex == index ? 42 : 36,
                                title: '',
                              ),
                          ],
                        ),
                        duration: const Duration(milliseconds: 120),
                      ),
                      if (touchedSlice != null && touchedPercent != null)
                        IgnorePointer(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: widget.theme.colorScheme.background,
                              border: Border.all(color: widget.theme.colorScheme.border),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: widget.theme.colorScheme.foreground.withValues(alpha: 0.08),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  touchedSlice.label,
                                  style: widget.theme.textTheme.small.copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${widget.formatValue(touchedSlice.value)} ($touchedPercent%)',
                                  style: widget.theme.textTheme.muted,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.theme,
    required this.title,
    this.trailing,
  });

  final ShadThemeData theme;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(child: Text(title, style: theme.textTheme.large.copyWith(fontWeight: FontWeight.w600))),
          ?trailing,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.theme,
    required this.label,
    required this.value,
    this.link = false,
  });

  final ShadThemeData theme;
  final String label;
  final String value;
  final bool link;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 180, child: Text(label, style: theme.textTheme.muted)),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.large.copyWith(color: link ? theme.colorScheme.primary : null),
            ),
          ),
        ],
      ),
    );
  }
}

class _DataTable extends StatelessWidget {
  const _DataTable({
    required this.theme,
    required this.columns,
    required this.rows,
    required this.onCopy,
  });

  final ShadThemeData theme;
  final List<String> columns;
  final List<List<String>> rows;
  final Future<void> Function(String value) onCopy;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Text('No data found', style: theme.textTheme.muted);
    }

    return Column(
      children: [
        Row(
          children: [
            for (final column in columns) ...[
              Expanded(child: Text(column, style: theme.textTheme.small.copyWith(color: theme.colorScheme.mutedForeground))),
            ],
            const SizedBox(width: 32),
          ],
        ),
        const SizedBox(height: 8),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                for (var index = 0; index < columns.length; index++) ...[
                  Expanded(
                    child: Text(
                      row.length > index ? row[index] : '',
                      style: theme.textTheme.large,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                if (row.isNotEmpty && row.last.isNotEmpty)
                  CalfButton.ghost(
                    padding: const EdgeInsets.all(4),
                    onPressed: () => onCopy(row.last),
                    child: Icon(LucideIcons.copy, size: 14, color: theme.colorScheme.mutedForeground),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SourceTab extends StatelessWidget {
  const _SourceTab({
    required this.theme,
    required this.loading,
    required this.error,
    required this.source,
    required this.detail,
  });

  final ShadThemeData theme;
  final bool loading;
  final String? error;
  final BuildSource? source;
  final BuildDetail detail;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Text('Loading source...', style: theme.textTheme.muted);
    }
    if (error != null) {
      return Text(error!, style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive));
    }

    final content = source?.content ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(LucideIcons.box, size: 16, color: theme.colorScheme.foreground),
            const SizedBox(width: 8),
            Text(source?.filename ?? detail.dockerfile, style: theme.textTheme.large),
            const SizedBox(width: 12),
            Text(_platformArch(detail.platform), style: theme.textTheme.muted),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.muted.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.colorScheme.border),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                content,
                style: theme.textTheme.small.copyWith(fontFamily: 'Menlo', height: 1.5),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LogsTab extends StatelessWidget {
  const _LogsTab({
    required this.theme,
    required this.detail,
    required this.rawLog,
    required this.steps,
    required this.loading,
    required this.error,
    required this.plainLogs,
    required this.expandedSteps,
    required this.onTogglePlain,
    required this.onToggleStep,
  });

  final ShadThemeData theme;
  final BuildDetail detail;
  final String rawLog;
  final List<BuildStep> steps;
  final bool loading;
  final String? error;
  final bool plainLogs;
  final Set<int> expandedSteps;
  final ValueChanged<bool> onTogglePlain;
  final ValueChanged<int> onToggleStep;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Center(child: Text('Loading logs...', style: theme.textTheme.muted));
    }
    if (error != null) {
      return Text(error!, style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive));
    }
    if (rawLog.isEmpty && steps.isEmpty) {
      return Center(child: Text('No logs available for this build.', style: theme.textTheme.muted));
    }

    if (plainLogs) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          CalfButton.ghost(
            onPressed: () => onTogglePlain(false),
            child: Text('Step view', style: theme.textTheme.small),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.muted.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.border),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  rawLog,
                  style: theme.textTheme.small.copyWith(fontFamily: 'Menlo', height: 1.4),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final totalMs = detail.durationMs <= 0 ? 1 : detail.durationMs;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            CalfButton.ghost(
              onPressed: () => onTogglePlain(true),
              child: Text('Plain view', style: theme.textTheme.small),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: steps.length,
            itemBuilder: (context, index) {
              final step = steps[index];
              final expanded = expandedSteps.contains(index);
              final badge = step.index > 0 ? '${step.index}/${step.total}' : 'internal';

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  children: [
                    HoverListRow(
                      theme: theme,
                      onTap: step.log.isEmpty ? null : () => onToggleStep(index),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                      child: Row(
                        children: [
                          _StepBadge(theme: theme, label: badge),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(step.name, style: theme.textTheme.large.copyWith(fontFamily: 'Menlo')),
                          ),
                          if (step.cached)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text('CACHED', style: theme.textTheme.small.copyWith(color: theme.colorScheme.primary)),
                            ),
                          const SizedBox(width: 8),
                          Text(_formatDuration(step.durationMs), style: theme.textTheme.muted),
                          SizedBox(
                            width: 120,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: FractionallySizedBox(
                                widthFactor: (step.durationMs / totalMs).clamp(0.05, 1.0),
                                child: Container(
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary.withValues(alpha: 0.5),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (expanded && step.log.isNotEmpty)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(left: 40, top: 4),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.muted.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: SelectableText(
                          step.log,
                          style: theme.textTheme.small.copyWith(fontFamily: 'Menlo'),
                        ),
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

class _StepBadge extends StatelessWidget {
  const _StepBadge({required this.theme, required this.label});

  final ShadThemeData theme;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: theme.textTheme.small),
    );
  }
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab({
    required this.theme,
    required this.loading,
    required this.error,
    required this.history,
    required this.currentId,
    this.onOpenBuild,
  });

  final ShadThemeData theme;
  final bool loading;
  final String? error;
  final List<BuildItem> history;
  final String currentId;
  final ValueChanged<String>? onOpenBuild;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Text('Loading history...', style: theme.textTheme.muted);
    }
    if (error != null) {
      return Text(error!, style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive));
    }

    final items = history.take(30).toList().reversed.toList();
    final durations = items.map((item) => item.durationMs.toDouble()).toList();
    final totalSteps = items.map((item) => item.totalSteps.toDouble()).toList();
    final cachedSteps = items.map((item) => item.cachedSteps.toDouble()).toList();

    return ListView(
      children: [
        Text('Build history', style: theme.textTheme.large.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          'Each series is scaled to its own peak in this window.',
          style: theme.textTheme.muted,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 220,
          child: items.isEmpty
              ? Center(child: Text('No builds to chart yet.', style: theme.textTheme.muted))
              : LineChart(
                  LineChartData(
                    minX: 0,
                    maxX: items.length <= 1 ? 1 : (items.length - 1).toDouble(),
                    minY: 0,
                    maxY: 1.2,
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      getDrawingHorizontalLine: (_) => FlLine(color: theme.colorScheme.border, strokeWidth: 1),
                    ),
                    titlesData: const FlTitlesData(show: false),
                    borderData: FlBorderData(show: false),
                    lineTouchData: LineTouchData(
                      enabled: items.isNotEmpty,
                      touchTooltipData: LineTouchTooltipData(
                        getTooltipItems: (spots) {
                          return spots.map((spot) {
                            final index = spot.x.round().clamp(0, items.length - 1);
                            final item = items[index];
                            String label;
                            String value;
                            switch (spot.barIndex) {
                              case 1:
                                label = 'Steps';
                                value = '${item.totalSteps}';
                              case 2:
                                label = 'Cached';
                                value = '${item.cachedSteps}';
                              default:
                                label = 'Duration';
                                value = _formatDuration(item.durationMs);
                            }
                            return LineTooltipItem(
                              '$label\n$value',
                              theme.textTheme.small.copyWith(color: theme.colorScheme.foreground),
                            );
                          }).toList();
                        },
                      ),
                    ),
                    lineBarsData: [
                      LineChartBarData(
                        spots: _normalizedHistorySpots(durations),
                        isCurved: items.length > 2,
                        color: theme.colorScheme.primary,
                        barWidth: 2,
                        dotData: FlDotData(show: items.length <= 3),
                      ),
                      LineChartBarData(
                        spots: _normalizedHistorySpots(totalSteps),
                        isCurved: items.length > 2,
                        color: const Color(0xFF22C55E),
                        barWidth: 2,
                        dotData: FlDotData(show: items.length <= 3),
                      ),
                      LineChartBarData(
                        spots: _normalizedHistorySpots(cachedSteps),
                        isCurved: items.length > 2,
                        color: theme.colorScheme.mutedForeground,
                        barWidth: 2,
                        dotData: FlDotData(show: items.length <= 3),
                      ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 24),
        Text('Past builds', style: theme.textTheme.large.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (history.isEmpty)
          Text('No builds found for this image.', style: theme.textTheme.muted)
        else
          for (final item in history)
          HoverListRow(
            theme: theme,
            onTap: onOpenBuild == null || item.id == currentId ? null : () => onOpenBuild!(item.id),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              children: [
                Expanded(child: Text(item.tag, style: theme.textTheme.large)),
                Expanded(child: Text(item.id, style: theme.textTheme.muted, overflow: TextOverflow.ellipsis)),
                Text(item.builder, style: theme.textTheme.muted),
                const SizedBox(width: 12),
                Text(_platformArch(item.platform), style: theme.textTheme.muted),
                const SizedBox(width: 12),
                Text('${item.cachedSteps}/${item.totalSteps}', style: theme.textTheme.muted),
                const SizedBox(width: 12),
                Text(_formatDuration(item.durationMs), style: theme.textTheme.muted),
                const SizedBox(width: 12),
                Text(item.createdAt, style: theme.textTheme.muted),
              ],
            ),
          ),
      ],
    );
  }
}

String _statusLabel(String status) {
  switch (status) {
    case 'success':
      return 'Completed';
    case 'failed':
      return 'Failed';
    case 'running':
      return 'Running';
    default:
      return status;
  }
}

Color _statusColor(String status, ShadThemeData theme) {
  switch (status) {
    case 'success':
      return const Color(0xFF22C55E);
    case 'failed':
      return theme.colorScheme.destructive;
    case 'running':
      return theme.colorScheme.primary;
    default:
      return theme.colorScheme.mutedForeground;
  }
}

String _formatDuration(int durationMs) {
  if (durationMs <= 0) {
    return '0.0s';
  }

  final seconds = durationMs / 1000;
  if (seconds < 60) {
    return '${seconds.toStringAsFixed(1)}s';
  }

  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  return '${minutes}m ${remainder.toStringAsFixed(0)}s';
}

String _platformArch(String platform) {
  final parts = platform.split('/');
  if (parts.length == 2) {
    return parts[1];
  }

  return platform;
}

List<FlSpot> _normalizedHistorySpots(List<double> values) {
  if (values.isEmpty) {
    return const [];
  }

  final peak = values.fold<double>(0, (current, value) => value > current ? value : current);
  final normalized = values
      .map((value) => peak <= 0 ? 0.0 : value / peak)
      .toList(growable: false);

  return _historySpots(normalized);
}

List<FlSpot> _historySpots(List<double> values) {
  if (values.isEmpty) {
    return const [];
  }

  if (values.length == 1) {
    return [
      FlSpot(0, values[0]),
      FlSpot(1, values[0]),
    ];
  }

  return [
    for (var index = 0; index < values.length; index++)
      FlSpot(index.toDouble(), values[index]),
  ];
}
