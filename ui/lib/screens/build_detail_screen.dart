import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/calf_tab_bar.dart';
import 'package:ui/widgets/detail_breadcrumb.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/theme/calf_theme.dart';

enum _BuildDetailTab { info, source, logs, history }

class BuildDetailView extends StatefulWidget {
  /// Creates a [BuildDetailView] widget.
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

  /// Creates the mutable state for [BuildDetailView].
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

  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  /// Resets all cached state when navigating to a different build.
  @override
  void didUpdateWidget(covariant BuildDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.buildId != widget.buildId) {
      _resetState();
      _loadDetail();
    }
  }

  /// Clears tab-specific cached data for a fresh build load.
  void _resetState() {
    _tab = _BuildDetailTab.info;
    _detail = null;
    _source = null;
    _history = [];
    _detailLoading = true;
    _sourceLoading = false;
    _historyLoading = false;
    _detailError = null;
    _sourceError = null;
    _historyError = null;
    _logsLoading = false;
    _logsError = null;
    _logs = null;
    _platformFilter = '';
    _expandedSteps.clear();
    _plainLogs = false;
  }

  /// Fetches Detail from the API and updates state.
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

  /// Fetches Source from the API and updates state.
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

  /// Fetches build history for the current tag from the API.
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

  /// Fetches Logs from the API and updates state.
  Future<void> _loadLogs() async {
    final detail = _detail;
    if (detail != null &&
        (detail.rawLog.isNotEmpty || detail.steps.isNotEmpty)) {
      return;
    }
    if (_logsLoading) {
      return;
    }

    setState(() {
      _logs = null;
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

  /// Switches the active tab and loads tab-specific data.
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

  /// Copies [value] to the system clipboard.
  Future<void> _copyText(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
  }

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailBreadcrumb(
          segments: ['Builds', detail?.tag ?? widget.buildId],
          onBack: widget.onBack,
        ),

        /// Creates a [_BuildDetailViewState] widget.
        const SizedBox(height: 12),
        if (_detailLoading)
          Text('Loading...', style: CalfTheme.muted(theme))
        else if (_detailError != null)
          Text(
            _detailError!,
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.error,
            ),
          )
        else if (detail != null) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(detail.tag, style: theme.textTheme.headlineSmall),

                    /// Creates a [_BuildDetailViewState] widget.
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(detail.id, style: CalfTheme.muted(theme)),

                        /// Creates a [_BuildDetailViewState] widget.
                        const SizedBox(width: 8),
                        CalfButton.ghost(
                          padding: const EdgeInsets.all(4),
                          onPressed: () => _copyText(detail.id),
                          child: Icon(
                            LucideIcons.copy,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _SummaryColumn(
                theme: theme,
                label: 'Status',
                value: _statusLabel(detail.status),
                color: _statusColor(detail.status, theme),
              ),

              /// Creates a [_BuildDetailViewState] widget.
              const SizedBox(width: 24),
              _SummaryColumn(
                theme: theme,
                label: 'Duration',
                value: _formatDuration(detail.durationMs),
              ),

              /// Creates a [_BuildDetailViewState] widget.
              const SizedBox(width: 24),
              _SummaryColumn(
                theme: theme,
                label: 'Builder',
                value: detail.builder,
                link: true,
              ),
            ],
          ),

          /// Creates a [_BuildDetailViewState] widget.
          const SizedBox(height: 16),
          CalfTabBar(
            theme: theme,
            labels: const ['Info', 'Source', 'Logs', 'History'],
            selectedIndex: _tab.index,
            labelStyle: theme.textTheme.titleMedium,
            onSelected: (index) => _selectTab(_BuildDetailTab.values[index]),
          ),

          /// Creates a [_BuildDetailViewState] widget.
          const SizedBox(height: 16),
          Expanded(child: _buildTabContent(theme, detail)),
        ],
      ],
    );
  }

  /// Builds the widget for the currently selected tab.
  Widget _buildTabContent(ThemeData theme, BuildDetail detail) {
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
  /// Creates a [_SummaryColumn] widget.
  const _SummaryColumn({
    required this.theme,
    required this.label,
    required this.value,
    this.color,
    this.link = false,
  });

  final ThemeData theme;
  final String label;
  final String value;
  final Color? color;
  final bool link;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),

        /// Creates a [_SummaryColumn] widget.
        const SizedBox(height: 4),
        Text(
          value,
          style: theme.textTheme.titleMedium!.copyWith(
            color:
                color ??
                (link
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface),
          ),
        ),
      ],
    );
  }
}

class _InfoTab extends StatelessWidget {
  /// Creates a [_InfoTab] widget.
  const _InfoTab({
    required this.theme,
    required this.detail,
    required this.platformFilter,
    required this.onPlatformChanged,
    required this.onCopy,
  });

  final ThemeData theme;
  final BuildDetail detail;
  final String platformFilter;
  final ValueChanged<String> onPlatformChanged;
  final Future<void> Function(String value) onCopy;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final platforms = <String>{
      if (detail.platform.isNotEmpty) detail.platform,
      ...detail.dependencies
          .map((item) => item.platform)
          .where((item) => item.isNotEmpty),
      ...detail.results
          .map((item) => item.platform)
          .where((item) => item.isNotEmpty),
    }.toList()..sort();

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
        _InfoRow(
          theme: theme,
          label: 'Remote source location',
          value: detail.remoteSource,
          link: true,
        ),
        _InfoRow(theme: theme, label: 'Revision', value: detail.sourceRevision),
        _InfoRow(theme: theme, label: 'Dockerfile', value: detail.dockerfile),

        /// Creates a [_InfoTab] widget.
        const SizedBox(height: 24),
        _SectionHeader(theme: theme, title: 'Build timing'),

        /// Creates a [_InfoTab] widget.
        const SizedBox(height: 12),
        _TimingCharts(
          theme: theme,
          timing: detail.timing,
          totalMs: detail.durationMs,
          cachedSteps: detail.cachedSteps,
          totalSteps: detail.totalSteps,
        ),

        /// Creates a [_InfoTab] widget.
        const SizedBox(height: 24),
        _SectionHeader(theme: theme, title: 'Dependencies'),
        _DataTable(
          theme: theme,
          columns: const ['Source', 'Platform', 'Digest'],
          rows: dependencies
              .map((item) => [item.source, item.platform, item.digest])
              .toList(),
          onCopy: onCopy,
        ),

        /// Creates a [_InfoTab] widget.
        const SizedBox(height: 24),
        _SectionHeader(theme: theme, title: 'Build results'),
        _DataTable(
          theme: theme,
          columns: const ['Artifact', 'Platform', 'Digest', 'Size'],
          copyColumnIndex: 2,
          rows: results
              .map((item) => [item.name, item.platform, item.digest, item.size])
              .toList(),
          onCopy: onCopy,
        ),

        /// Creates a [_InfoTab] widget.
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
  /// Creates a [_PlatformFilter] widget.
  const _PlatformFilter({
    required this.theme,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final ThemeData theme;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Filter by platform', style: theme.textTheme.bodySmall),

        /// Creates a [_PlatformFilter] widget.
        const SizedBox(width: 8),
        CalfButton.outline(
          onPressed: () async {
            final renderBox = context.findRenderObject() as RenderBox?;
            if (renderBox == null) {
              return;
            }

            final offset = renderBox.localToGlobal(Offset.zero);
            final selected = await showMenu<String>(
              context: context,
              position: RelativeRect.fromLTRB(
                offset.dx,
                offset.dy + renderBox.size.height,
                offset.dx + renderBox.size.width,
                offset.dy + renderBox.size.height,
              ),
              items: options
                  .map(
                    (option) => PopupMenuItem<String>(
                      value: option,
                      child: Text(option),
                    ),
                  )
                  .toList(),
            );
            if (selected != null) {
              onChanged(selected);
            }
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(value, style: theme.textTheme.bodySmall),

              /// Creates a [_PlatformFilter] widget.
              const SizedBox(width: 4),
              Icon(
                LucideIcons.chevronDown,
                size: 14,
                color: theme.colorScheme.onSurface,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TimingCharts extends StatelessWidget {
  /// Creates a [_TimingCharts] widget.
  const _TimingCharts({
    required this.theme,
    required this.timing,
    required this.totalMs,
    required this.cachedSteps,
    required this.totalSteps,
  });

  final ThemeData theme;
  final BuildTiming timing;
  final int totalMs;
  final int cachedSteps;
  final int totalSteps;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final realTime = _timingSlices(timing);
    final accumulatedTotal =
        timing.localTransfersMs +
        timing.imagePullsMs +
        timing.executionsMs +
        timing.fileOperationsMs +
        timing.resultExportsMs +
        timing.idleMs;
    final accumulatedSlices = realTime;
    final uncachedSteps = (totalSteps - cachedSteps).clamp(0, totalSteps);
    final cacheSlices = [
      _TimingSlice('Cached steps', cachedSteps.toDouble(), CalfColors.success),
      _TimingSlice(
        'Other steps',
        uncachedSteps.toDouble(),
        theme.colorScheme.onSurfaceVariant,
      ),
    ];
    final idleMs = timing.idleMs.clamp(0, totalMs);
    final activeMs = (totalMs - idleMs).clamp(0, totalMs);

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
          title: 'Accumulated time (${_formatDuration(accumulatedTotal)})',
          slices: accumulatedSlices,
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
            _TimingSlice(
              'Active',
              activeMs > 0 ? activeMs.toDouble() : 1,

              /// Creates a [_TimingCharts] widget.
              const Color(0xFF3B82F6),
            ),
            _TimingSlice(
              'Idle',
              idleMs > 0 ? idleMs.toDouble() : 0,
              theme.colorScheme.onSurfaceVariant,
            ),
          ].where((slice) => slice.value > 0).toList(),
          formatValue: (value) => _formatDuration(value.toInt()),
        ),
      ],
    );
  }

  /// Builds timing slices for the build-duration chart.
  List<_TimingSlice> _timingSlices(BuildTiming timing) {
    return [
      _TimingSlice(
        'Local file transfers',
        timing.localTransfersMs.toDouble(),

        /// Creates a [_TimingCharts] widget.
        const Color(0xFF166534),
      ),
      _TimingSlice(
        'Image pulls',
        timing.imagePullsMs.toDouble(),

        /// Creates a [_TimingCharts] widget.
        const Color(0xFF4ADE80),
      ),
      _TimingSlice(
        'Executions',
        timing.executionsMs.toDouble(),

        /// Creates a [_TimingCharts] widget.
        const Color(0xFF3B82F6),
      ),
      _TimingSlice(
        'File operations',
        timing.fileOperationsMs.toDouble(),

        /// Creates a [_TimingCharts] widget.
        const Color(0xFFEF4444),
      ),
      _TimingSlice(
        'Result exports',
        timing.resultExportsMs.toDouble(),

        /// Creates a [_TimingCharts] widget.
        const Color(0xFFA855F7),
      ),
      _TimingSlice(
        'Idle',
        timing.idleMs.toDouble(),
        theme.colorScheme.onSurfaceVariant,
      ),
    ].where((slice) => slice.value > 0).toList();
  }
}

class _TimingSlice {
  /// Creates a [_TimingSlice] widget.
  const _TimingSlice(this.label, this.value, this.color);

  final String label;
  final double value;
  final Color color;
}

class _TimingChartCard extends StatefulWidget {
  /// Creates a [_TimingChartCard] widget.
  const _TimingChartCard({
    required this.theme,
    required this.title,
    required this.slices,
    required this.formatValue,
  });

  final ThemeData theme;
  final String title;
  final List<_TimingSlice> slices;
  final String Function(double value) formatValue;

  /// Creates the mutable state for [_TimingChartCard].
  @override
  State<_TimingChartCard> createState() => _TimingChartCardState();
}

class _TimingChartCardState extends State<_TimingChartCard> {
  int? _touchedIndex;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final total = widget.slices.fold<double>(
      0,
      (sum, slice) => sum + slice.value,
    );
    final touchedSlice =
        _touchedIndex != null &&
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
        border: Border.all(color: widget.theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: widget.theme.textTheme.bodySmall!.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),

          /// Creates a [_TimingChartCardState] widget.
          const SizedBox(height: 8),
          Expanded(
            child: total <= 0
                ? Center(
                    child: Text(
                      'No timing data',
                      style: CalfTheme.muted(widget.theme),
                    ),
                  )
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
                                _touchedIndex = response
                                    .touchedSection!
                                    .touchedSectionIndex;
                              });
                            },
                          ),
                          sections: [
                            for (
                              var index = 0;
                              index < widget.slices.length;
                              index++
                            )
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: widget.theme.colorScheme.surface,
                              border: Border.all(
                                color: widget.theme.colorScheme.outlineVariant,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: widget.theme.colorScheme.onSurface
                                      .withValues(alpha: 0.08),
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
                                  style: widget.theme.textTheme.bodySmall!.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),

                                /// Creates a [_TimingChartCardState] widget.
                                const SizedBox(height: 2),
                                Text(
                                  '${widget.formatValue(touchedSlice.value)} ($touchedPercent%)',
                                  style: CalfTheme.muted(widget.theme),
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
  /// Creates a [_SectionHeader] widget.
  const _SectionHeader({
    required this.theme,
    required this.title,
    this.trailing,
  });

  final ThemeData theme;
  final String title;
  final Widget? trailing;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleMedium!.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  /// Creates a [_InfoRow] widget.
  const _InfoRow({
    required this.theme,
    required this.label,
    required this.value,
    this.link = false,
  });

  final ThemeData theme;
  final String label;
  final String value;
  final bool link;

  /// Builds the widget tree for the current screen state.
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
          SizedBox(
            width: 180,
            child: Text(label, style: CalfTheme.muted(theme)),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.titleMedium!.copyWith(
                color: link ? theme.colorScheme.primary : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DataTable extends StatelessWidget {
  /// Creates a [_DataTable] widget.
  const _DataTable({
    required this.theme,
    required this.columns,
    required this.rows,
    required this.onCopy,
    this.copyColumnIndex,
  });

  final ThemeData theme;
  final List<String> columns;
  final List<List<String>> rows;
  final Future<void> Function(String value) onCopy;
  final int? copyColumnIndex;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Text('No data found', style: CalfTheme.muted(theme));
    }

    return Column(
      children: [
        Row(
          children: [
            for (final column in columns) ...[
              Expanded(
                child: Text(
                  column,
                  style: theme.textTheme.bodySmall!.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],

            /// Creates a [_DataTable] widget.
            const SizedBox(width: 32),
          ],
        ),

        /// Creates a [_DataTable] widget.
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
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                if (row.isNotEmpty) ...[
                  Builder(
                    builder: (context) {
                      final copyIndex = copyColumnIndex ?? row.length - 1;
                      if (copyIndex < 0 ||
                          copyIndex >= row.length ||
                          row[copyIndex].isEmpty) {
                        return const SizedBox.shrink();
                      }

                      return CalfButton.ghost(
                        padding: const EdgeInsets.all(4),
                        onPressed: () => onCopy(row[copyIndex]),
                        child: Icon(
                          LucideIcons.copy,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _SourceTab extends StatelessWidget {
  /// Creates a [_SourceTab] widget.
  const _SourceTab({
    required this.theme,
    required this.loading,
    required this.error,
    required this.source,
    required this.detail,
  });

  final ThemeData theme;
  final bool loading;
  final String? error;
  final BuildSource? source;
  final BuildDetail detail;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Text('Loading source...', style: CalfTheme.muted(theme));
    }
    if (error != null) {
      return Text(
        error!,
        style: theme.textTheme.bodySmall!.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }

    final content = source?.content ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              LucideIcons.box,
              size: 16,
              color: theme.colorScheme.onSurface,
            ),

            /// Creates a [_SourceTab] widget.
            const SizedBox(width: 8),
            Text(
              source?.filename ?? detail.dockerfile,
              style: theme.textTheme.titleMedium,
            ),

            /// Creates a [_SourceTab] widget.
            const SizedBox(width: 12),
            Text(_platformArch(detail.platform), style: CalfTheme.muted(theme)),
          ],
        ),

        /// Creates a [_SourceTab] widget.
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                content,
                style: theme.textTheme.bodySmall!.copyWith(
                  fontFamily: 'Menlo',
                  height: 1.5,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LogsTab extends StatelessWidget {
  /// Creates a [_LogsTab] widget.
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

  final ThemeData theme;
  final BuildDetail detail;
  final String rawLog;
  final List<BuildStep> steps;
  final bool loading;
  final String? error;
  final bool plainLogs;
  final Set<int> expandedSteps;
  final ValueChanged<bool> onTogglePlain;
  final ValueChanged<int> onToggleStep;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Center(
        child: Text('Loading logs...', style: CalfTheme.muted(theme)),
      );
    }
    if (error != null) {
      return Text(
        error!,
        style: theme.textTheme.bodySmall!.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    if (rawLog.isEmpty && steps.isEmpty) {
      return Center(
        child: Text(
          'No logs available for this build.',
          style: CalfTheme.muted(theme),
        ),
      );
    }

    if (plainLogs) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          CalfButton.ghost(
            onPressed: () => onTogglePlain(false),
            child: Text('Step view', style: theme.textTheme.bodySmall),
          ),

          /// Creates a [_LogsTab] widget.
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  rawLog,
                  style: theme.textTheme.bodySmall!.copyWith(
                    fontFamily: 'Menlo',
                    height: 1.4,
                  ),
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
              child: Text('Plain view', style: theme.textTheme.bodySmall),
            ),
          ],
        ),

        /// Creates a [_LogsTab] widget.
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: steps.length,
            itemBuilder: (context, index) {
              final step = steps[index];
              final expanded = expandedSteps.contains(index);
              final badge = step.index > 0
                  ? '${step.index}/${step.total}'
                  : 'internal';

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  children: [
                    HoverListRow(
                      theme: theme,
                      onTap: step.log.isEmpty
                          ? null
                          : () => onToggleStep(index),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          _StepBadge(theme: theme, label: badge),

                          /// Creates a [_LogsTab] widget.
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              step.name,
                              style: theme.textTheme.titleMedium!.copyWith(
                                fontFamily: 'Menlo',
                              ),
                            ),
                          ),
                          if (step.cached)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.15,
                                ),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                'CACHED',
                                style: theme.textTheme.bodySmall!.copyWith(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),

                          /// Creates a [_LogsTab] widget.
                          const SizedBox(width: 8),
                          Text(
                            _formatDuration(step.durationMs),
                            style: CalfTheme.muted(theme),
                          ),
                          SizedBox(
                            width: 120,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: FractionallySizedBox(
                                widthFactor: (step.durationMs / totalMs).clamp(
                                  0.05,
                                  1.0,
                                ),
                                child: Container(
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary.withValues(
                                      alpha: 0.5,
                                    ),
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
                          color: theme.colorScheme.surfaceContainerHighest.withValues(
                            alpha: 0.15,
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: SelectableText(
                          step.log,
                          style: theme.textTheme.bodySmall!.copyWith(
                            fontFamily: 'Menlo',
                          ),
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
  /// Creates a [_StepBadge] widget.
  const _StepBadge({required this.theme, required this.label});

  final ThemeData theme;
  final String label;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: theme.textTheme.bodySmall),
    );
  }
}

class _HistoryTab extends StatelessWidget {
  /// Creates a [_HistoryTab] widget.
  const _HistoryTab({
    required this.theme,
    required this.loading,
    required this.error,
    required this.history,
    required this.currentId,
    this.onOpenBuild,
  });

  final ThemeData theme;
  final bool loading;
  final String? error;
  final List<BuildItem> history;
  final String currentId;
  final ValueChanged<String>? onOpenBuild;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Text('Loading history...', style: CalfTheme.muted(theme));
    }
    if (error != null) {
      return Text(
        error!,
        style: theme.textTheme.bodySmall!.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }

    final items = history.take(30).toList().reversed.toList();

    return ListView(
      children: [
        Text(
          'Build history',
          style: theme.textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          'Each series is scaled to its own peak in this window.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 12),
        _BuildHistoryChart(theme: theme, items: items),

        /// Creates a [_HistoryTab] widget.
        const SizedBox(height: 24),
        Text(
          'Past builds',
          style: theme.textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w600),
        ),

        /// Creates a [_HistoryTab] widget.
        const SizedBox(height: 12),
        if (history.isEmpty)
          Text('No builds found for this image.', style: CalfTheme.muted(theme))
        else
          for (final item in history)
            HoverListRow(
              theme: theme,
              onTap: onOpenBuild == null || item.id == currentId
                  ? null
                  : () => onOpenBuild!(item.id),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(
                children: [
                  Expanded(child: Text(item.tag, style: theme.textTheme.titleMedium)),
                  Expanded(
                    child: Text(
                      item.id,
                      style: CalfTheme.muted(theme),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(item.builder, style: CalfTheme.muted(theme)),

                  /// Creates a [_HistoryTab] widget.
                  const SizedBox(width: 12),
                  Text(
                    _platformArch(item.platform),
                    style: CalfTheme.muted(theme),
                  ),

                  /// Creates a [_HistoryTab] widget.
                  const SizedBox(width: 12),
                  Text(
                    '${item.cachedSteps}/${item.totalSteps}',
                    style: CalfTheme.muted(theme),
                  ),

                  /// Creates a [_HistoryTab] widget.
                  const SizedBox(width: 12),
                  Text(
                    _formatDuration(item.durationMs),
                    style: CalfTheme.muted(theme),
                  ),

                  /// Creates a [_HistoryTab] widget.
                  const SizedBox(width: 12),
                  Text(item.createdAt, style: CalfTheme.muted(theme)),
                ],
              ),
            ),
      ],
    );
  }
}

/// Returns the display label or color for a status value.
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

/// Returns the display label or color for a status value.
Color _statusColor(String status, ThemeData theme) {
  switch (status) {
    case 'success':
      return CalfColors.success;
    case 'failed':
      return theme.colorScheme.error;
    case 'running':
      return theme.colorScheme.primary;
    default:
      return theme.colorScheme.onSurfaceVariant;
  }
}

/// Formats the value for display.
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

/// Extracts the architecture portion from a platform string.
String _platformArch(String platform) {
  final parts = platform.split('/');
  if (parts.length == 2) {
    return parts[1];
  }

  return platform;
}

/// Line chart of recent builds with an overlay tooltip above the widget tree.
class _BuildHistoryChart extends StatefulWidget {
  /// Creates a build-history line chart for [items].
  const _BuildHistoryChart({required this.theme, required this.items});

  final ThemeData theme;
  final List<BuildItem> items;

  /// Creates the mutable state for [_BuildHistoryChart].
  @override
  State<_BuildHistoryChart> createState() => _BuildHistoryChartState();
}

class _BuildHistoryChartState extends State<_BuildHistoryChart> {
  static const double _chartHeight = 220;
  static const double _tooltipWidth = 196;
  static const double _tooltipHeight = 108;
  static const double _tooltipGap = 12;

  final LayerLink _layerLink = LayerLink();
  final OverlayPortalController _tooltipPortal = OverlayPortalController();
  final GlobalKey _chartKey = GlobalKey();

  int? _touchedIndex;
  Offset _localTouch = Offset.zero;

  /// Clears the overlay tooltip when this chart leaves the tree.
  @override
  void dispose() {
    if (_tooltipPortal.isShowing) {
      _tooltipPortal.hide();
    }
    super.dispose();
  }

  /// Shows or updates the overlay tooltip for [index] at [localPosition].
  void _showTooltip(int index, Offset localPosition) {
    _touchedIndex = index;
    _localTouch = localPosition;
    if (!_tooltipPortal.isShowing) {
      _tooltipPortal.show();
    }
    setState(() {});
  }

  /// Hides the overlay tooltip.
  void _hideTooltip() {
    if (_touchedIndex == null && !_tooltipPortal.isShowing) {
      return;
    }
    _touchedIndex = null;
    if (_tooltipPortal.isShowing) {
      _tooltipPortal.hide();
    }
    setState(() {});
  }

  /// Places the tooltip near the touch point, flipping below when near the top.
  Offset _tooltipOffset(Size chartSize) {
    var dx = _localTouch.dx - _tooltipWidth / 2;
    var dy = _localTouch.dy - _tooltipHeight - _tooltipGap;
    if (dy < 8) {
      dy = _localTouch.dy + _tooltipGap;
    }
    final maxDx = (chartSize.width - _tooltipWidth).clamp(0.0, double.infinity);
    dx = dx.clamp(0.0, maxDx);
    return Offset(dx, dy);
  }

  /// Builds the chart, legend, and overlay tooltip portal.
  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final items = widget.items;

    if (items.isEmpty) {
      return SizedBox(
        height: _chartHeight,
        child: Center(
          child: Text('No builds to chart yet.', style: CalfTheme.muted(theme)),
        ),
      );
    }

    final durations = items.map((item) => item.durationMs.toDouble()).toList();
    final totalSteps = items.map((item) => item.totalSteps.toDouble()).toList();
    final cachedSteps = items
        .map((item) => item.cachedSteps.toDouble())
        .toList();
    final durationColor = theme.colorScheme.primary;
    final stepsColor = CalfColors.success;
    final cachedColor = theme.colorScheme.onSurfaceVariant;
    final touched =
        _touchedIndex != null &&
            _touchedIndex! >= 0 &&
            _touchedIndex! < items.length
        ? items[_touchedIndex!]
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OverlayPortal(
          controller: _tooltipPortal,
          overlayChildBuilder: (context) {
            if (touched == null) {
              return const SizedBox.shrink();
            }

            final box =
                _chartKey.currentContext?.findRenderObject() as RenderBox?;
            final chartSize = box?.size ?? const Size(300, _chartHeight);

            return UnconstrainedBox(
              child: CompositedTransformFollower(
                link: _layerLink,
                showWhenUnlinked: false,
                offset: _tooltipOffset(chartSize),
                child: IgnorePointer(
                  child: _BuildHistoryTooltip(
                    theme: theme,
                    item: touched,
                    durationColor: durationColor,
                    stepsColor: stepsColor,
                    cachedColor: cachedColor,
                    width: _tooltipWidth,
                  ),
                ),
              ),
            );
          },
          child: CompositedTransformTarget(
            link: _layerLink,
            child: SizedBox(
              key: _chartKey,
              height: _chartHeight,
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: items.length <= 1 ? 1 : (items.length - 1).toDouble(),
                  minY: 0,
                  maxY: 1.2,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    checkToShowHorizontalLine: (value) =>
                        value > 0.05 && value < 1.15,
                    getDrawingHorizontalLine: (_) =>
                        FlLine(color: theme.colorScheme.outlineVariant, strokeWidth: 1),
                  ),
                  titlesData: const FlTitlesData(show: false),
                  borderData: FlBorderData(show: false),
                  lineTouchData: LineTouchData(
                    enabled: true,
                    handleBuiltInTouches: true,
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (_) => const [],
                    ),
                    touchCallback: (event, response) {
                      final local = event.localPosition;
                      if (!event.isInterestedForInteractions ||
                          local == null ||
                          response?.lineBarSpots == null ||
                          response!.lineBarSpots!.isEmpty) {
                        _hideTooltip();
                        return;
                      }

                      final index = response.lineBarSpots!.first.x
                          .round()
                          .clamp(0, items.length - 1);
                      _showTooltip(index, local);
                    },
                    getTouchedSpotIndicator: (barData, spotIndexes) {
                      return [
                        for (final _ in spotIndexes)
                          TouchedSpotIndicatorData(
                            FlLine(
                              color: theme.colorScheme.outlineVariant.withValues(
                                alpha: 0.55,
                              ),
                              strokeWidth: 1,
                            ),
                            FlDotData(
                              show: true,
                              getDotPainter: (spot, percent, bar, index) {
                                return FlDotCirclePainter(
                                  radius: 4,
                                  color: bar.color ?? durationColor,
                                  strokeWidth: 2,
                                  strokeColor: theme.colorScheme.surface,
                                );
                              },
                            ),
                          ),
                      ];
                    },
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _normalizedHistorySpots(durations),
                      isCurved: items.length > 2,
                      color: durationColor,
                      barWidth: 2,
                      dotData: FlDotData(show: items.length <= 3),
                    ),
                    LineChartBarData(
                      spots: _normalizedHistorySpots(totalSteps),
                      isCurved: items.length > 2,
                      color: stepsColor,
                      barWidth: 2,
                      dotData: FlDotData(show: items.length <= 3),
                    ),
                    LineChartBarData(
                      spots: _normalizedHistorySpots(cachedSteps),
                      isCurved: items.length > 2,
                      color: cachedColor,
                      barWidth: 2,
                      dotData: FlDotData(show: items.length <= 3),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            _ChartLegendSwatch(
              theme: theme,
              color: durationColor,
              label: 'Duration',
            ),
            _ChartLegendSwatch(theme: theme, color: stepsColor, label: 'Steps'),
            _ChartLegendSwatch(
              theme: theme,
              color: cachedColor,
              label: 'Cached',
            ),
          ],
        ),
      ],
    );
  }
}

/// Floating overlay tooltip for one build-history point.
class _BuildHistoryTooltip extends StatelessWidget {
  /// Creates a styled tooltip card for [item].
  const _BuildHistoryTooltip({
    required this.theme,
    required this.item,
    required this.durationColor,
    required this.stepsColor,
    required this.cachedColor,
    required this.width,
  });

  final ThemeData theme;
  final BuildItem item;
  final Color durationColor;
  final Color stepsColor;
  final Color cachedColor;
  final double width;

  /// Builds the tooltip card.
  @override
  Widget build(BuildContext context) {
    final title = item.tag.isNotEmpty ? item.tag : item.id;
    final labelStyle = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w500,
      height: 1.3,
    );
    final valueStyle = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurface,
      fontWeight: FontWeight.w600,
      height: 1.3,
    );

    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: valueStyle.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          _tooltipRow(
            label: 'Duration',
            value: _formatDuration(item.durationMs),
            swatch: durationColor,
            labelStyle: labelStyle,
            valueStyle: valueStyle,
          ),
          const SizedBox(height: 4),
          _tooltipRow(
            label: 'Steps',
            value: '${item.totalSteps}',
            swatch: stepsColor,
            labelStyle: labelStyle,
            valueStyle: valueStyle,
          ),
          const SizedBox(height: 4),
          _tooltipRow(
            label: 'Cached',
            value: '${item.cachedSteps}',
            swatch: cachedColor,
            labelStyle: labelStyle,
            valueStyle: valueStyle,
          ),
        ],
      ),
    );
  }

  /// Builds one metric row with a color swatch.
  Widget _tooltipRow({
    required String label,
    required String value,
    required Color swatch,
    required TextStyle labelStyle,
    required TextStyle valueStyle,
  }) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: swatch,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: labelStyle)),
        Text(value, style: valueStyle),
      ],
    );
  }
}

/// Color key used under build and stats line charts.
class _ChartLegendSwatch extends StatelessWidget {
  /// Creates a small color square with [label].
  const _ChartLegendSwatch({
    required this.theme,
    required this.color,
    required this.label,
  });

  final ThemeData theme;
  final Color color;
  final String label;

  /// Builds the legend swatch row.
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: CalfTheme.muted(theme)),
      ],
    );
  }
}

/// Normalizes values for chart rendering.
List<FlSpot> _normalizedHistorySpots(List<double> values) {
  if (values.isEmpty) {
    return const [];
  }

  final peak = values.fold<double>(
    0,
    (current, value) => value > current ? value : current,
  );
  final normalized = values
      .map((value) => peak <= 0 ? 0.0 : value / peak)
      .toList(growable: false);

  return _historySpots(normalized);
}

/// Converts history values into chart data points.
List<FlSpot> _historySpots(List<double> values) {
  if (values.isEmpty) {
    return const [];
  }

  if (values.length == 1) {
    return [FlSpot(0, values[0]), FlSpot(1, values[0])];
  }

  return [
    for (var index = 0; index < values.length; index++)
      FlSpot(index.toDouble(), values[index]),
  ];
}
