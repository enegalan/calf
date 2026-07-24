import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/widgets/build_row_icons.dart';
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

  /// Opens the Docker Hub page for a dependency image reference.
  Future<void> _openDependencyInDockerHub(String source) async {
    await openExternalUrl(dockerHubImageUrl(source));
  }

  /// Downloads a build result artifact as `sha256_<hash>.json`.
  Future<void> _downloadBuildResult(String digest) async {
    if (digest.isEmpty) {
      return;
    }

    final hash = digest.startsWith('sha256:') ? digest.substring(7) : digest;
    final suggestedName = 'sha256_$hash.json';
    final location = await getSaveLocation(suggestedName: suggestedName);
    if (location == null || !mounted) {
      return;
    }

    try {
      final bytes = await widget.apiClient.downloadBuildArtifact(
        widget.buildId,
        digest,
      );
      await File(location.path).writeAsBytes(bytes);
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } on FileSystemException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    }
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
                          width: 28,
                          height: 28,
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
          onOpenDependency: _openDependencyInDockerHub,
          onDownloadResult: _downloadBuildResult,
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
        final rawLog = _logs?.rawLog ?? detail.rawLog;
        final steps = _logs?.steps ?? detail.steps;
        return _LogsTab(
          theme: theme,
          detail: detail,
          rawLog: rawLog,
          steps: steps,
          loading: _logsLoading,
          error: _logsError,
          plainLogs: _plainLogs,
          expandedSteps: Set<int>.from(_expandedSteps),
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
          onExpandAll: () {
            setState(() {
              _expandedSteps
                ..clear()
                ..addAll([
                  for (var index = 0; index < steps.length; index++)
                    if (steps[index].log.isNotEmpty) index,
                ]);
            });
          },
          onCollapseAll: () => setState(() => _expandedSteps.clear()),
          onCopy: () => _copyText(rawLog),
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
    required this.onOpenDependency,
    required this.onDownloadResult,
  });

  final ThemeData theme;
  final BuildDetail detail;
  final String platformFilter;
  final ValueChanged<String> onPlatformChanged;
  final Future<void> Function(String value) onCopy;
  final Future<void> Function(String source) onOpenDependency;
  final Future<void> Function(String digest) onDownloadResult;

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
          startedAt: detail.createdAt,
          finishedAt: detail.finishedAt,
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
          leadingIcons: [
            for (final item in dependencies)
              buildDependencyIconKind(item.source),
          ],
          onCopy: onCopy,
          menuBuilder: (row) => const [
            PopupMenuItem(value: 'open', child: Text('Open in new window')),
          ],
          onMenuSelected: (action, row) async {
            if (action == 'open' && row.isNotEmpty) {
              await onOpenDependency(row[0]);
            }
          },
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
          leadingIcons: [
            for (final item in results) buildResultIconKind(item.name),
          ],
          onCopy: onCopy,
          menuBuilder: (row) => [
            PopupMenuItem(
              value: 'download',
              enabled: row.length > 2 && row[2].isNotEmpty,
              child: const Text('Download'),
            ),
          ],
          onMenuSelected: (action, row) async {
            if (action == 'download' && row.length > 2 && row[2].isNotEmpty) {
              await onDownloadResult(row[2]);
            }
          },
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
    required this.startedAt,
    required this.finishedAt,
  });

  final ThemeData theme;
  final BuildTiming timing;
  final int totalMs;
  final int cachedSteps;
  final int totalSteps;
  final String startedAt;
  final String finishedAt;

  /// Minimum width that fits all four timing charts in one row.
  static const double _wideBreakpoint = 720;

  static const Color _localTransfers = Color(0xFF166534);
  static const Color _imagePulls = Color(0xFF4ADE80);
  static const Color _executions = Color(0xFF3B82F6);
  static const Color _fileOperations = Color(0xFFEF4444);
  static const Color _resultExports = Color(0xFFA855F7);

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final idleColor = theme.colorScheme.onSurfaceVariant;
    final realTime = _timingSlices(timing, idleColor);
    final accumulatedTotal =
        timing.localTransfersMs +
        timing.imagePullsMs +
        timing.executionsMs +
        timing.fileOperationsMs +
        timing.resultExportsMs +
        timing.idleMs;
    final uncachedSteps = (totalSteps - cachedSteps).clamp(0, totalSteps);
    final cacheSlices = [
      _TimingSlice('Cached steps', cachedSteps.toDouble(), CalfColors.success),
      _TimingSlice('Non-cached steps', uncachedSteps.toDouble(), idleColor),
    ].where((slice) => slice.value > 0).toList();
    final idleMs = timing.idleMs.clamp(0, totalMs);
    final activeMs = (totalMs - idleMs).clamp(0, totalMs);
    final parallelSlices = [
      _TimingSlice(
        'Active',
        activeMs > 0 ? activeMs.toDouble() : 1,
        _executions,
      ),
      _TimingSlice('Idle', idleMs.toDouble(), idleColor),
    ].where((slice) => slice.value > 0).toList();
    final legendSlices = [
      const _TimingSlice('Local file transfers', 0, _localTransfers),
      const _TimingSlice('Image pulls', 0, _imagePulls),
      const _TimingSlice('Executions', 0, _executions),
      const _TimingSlice('File operations', 0, _fileOperations),
      const _TimingSlice('Result exports', 0, _resultExports),
      _TimingSlice('Idle', 0, idleColor),
    ];
    final charts = [
      _TimingChartCard(
        theme: theme,
        title: 'Real time',
        value: _formatDuration(totalMs),
        slices: realTime,
      ),
      _TimingChartCard(
        theme: theme,
        title: 'Accumulated time',
        value: _formatDuration(accumulatedTotal),
        slices: realTime,
      ),
      _TimingChartCard(
        theme: theme,
        title: 'Cache usage',
        value: '$cachedSteps/$totalSteps',
        slices: cacheSlices.isEmpty
            ? [_TimingSlice('None', 1, idleColor)]
            : cacheSlices,
      ),
      _TimingChartCard(
        theme: theme,
        title: 'Parallel execution',
        value: '',
        slices: parallelSlices,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _wideBreakpoint;
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final chart in charts) Expanded(child: chart),
                ],
              );
            }
            return Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: charts[0]),
                    Expanded(child: charts[1]),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: charts[2]),
                    Expanded(child: charts[3]),
                  ],
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        Center(
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 16,
            runSpacing: 8,
            children: [
              for (final slice in legendSlices)
                _ChartLegendSwatch(
                  theme: theme,
                  color: slice.color,
                  label: slice.label,
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _TimingSummary(
          theme: theme,
          startedAt: startedAt,
          finishedAt: finishedAt,
          totalMs: totalMs,
          cachedSteps: cachedSteps,
          uncachedSteps: uncachedSteps,
          totalSteps: totalSteps,
        ),
      ],
    );
  }

  /// Builds timing slices for the build-duration chart.
  List<_TimingSlice> _timingSlices(BuildTiming timing, Color idleColor) {
    return [
      _TimingSlice(
        'Local file transfers',
        timing.localTransfersMs.toDouble(),
        _localTransfers,
      ),
      _TimingSlice(
        'Image pulls',
        timing.imagePullsMs.toDouble(),
        _imagePulls,
      ),
      _TimingSlice(
        'Executions',
        timing.executionsMs.toDouble(),
        _executions,
      ),
      _TimingSlice(
        'File operations',
        timing.fileOperationsMs.toDouble(),
        _fileOperations,
      ),
      _TimingSlice(
        'Result exports',
        timing.resultExportsMs.toDouble(),
        _resultExports,
      ),
      _TimingSlice('Idle', timing.idleMs.toDouble(), idleColor),
    ].where((slice) => slice.value > 0).toList();
  }
}

/// Two-column build timing summary under the shared legend.
class _TimingSummary extends StatelessWidget {
  /// Creates a [_TimingSummary] widget.
  const _TimingSummary({
    required this.theme,
    required this.startedAt,
    required this.finishedAt,
    required this.totalMs,
    required this.cachedSteps,
    required this.uncachedSteps,
    required this.totalSteps,
  });

  final ThemeData theme;
  final String startedAt;
  final String finishedAt;
  final int totalMs;
  final int cachedSteps;
  final int uncachedSteps;
  final int totalSteps;

  /// Builds the summary columns.
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _summaryLine(
                label: 'Build start time',
                value: _formatBuildTimestamp(startedAt),
              ),
              const SizedBox(height: 6),
              _summaryLine(
                label: 'Build end time',
                value: _formatBuildTimestamp(finishedAt),
              ),
              const SizedBox(height: 6),
              _summaryLine(
                label: 'Total build time',
                value: _formatDuration(totalMs),
                emphasize: true,
              ),
            ],
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _summaryLine(label: 'Cached steps', value: '$cachedSteps'),
              const SizedBox(height: 6),
              _summaryLine(label: 'Non-cached steps', value: '$uncachedSteps'),
              const SizedBox(height: 6),
              _summaryLine(
                label: 'Total steps',
                value: '$totalSteps',
                emphasize: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Builds one label/value summary row.
  Widget _summaryLine({
    required String label,
    required String value,
    bool emphasize = false,
  }) {
    final style = emphasize
        ? theme.textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.w700)
        : CalfTheme.muted(theme);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '$label  ', style: CalfTheme.muted(theme)),
          TextSpan(text: value, style: style),
        ],
      ),
    );
  }
}

class _TimingSlice {
  /// Creates a [_TimingSlice] instance.
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
    required this.value,
    required this.slices,
  });

  final ThemeData theme;
  final String title;
  final String value;
  final List<_TimingSlice> slices;

  /// Creates the mutable state for [_TimingChartCard].
  @override
  State<_TimingChartCard> createState() => _TimingChartCardState();
}

class _TimingChartCardState extends State<_TimingChartCard> {
  int? _touchedIndex;

  static const double _chartSize = 220;

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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          SizedBox(
            height: 48,
            child: Column(
              children: [
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: CalfTheme.muted(widget.theme),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.value,
                  textAlign: TextAlign.center,
                  style: widget.theme.textTheme.titleMedium!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: _chartSize,
            height: _chartSize,
            child: total <= 0
                ? Center(
                    child: Text(
                      'No data',
                      style: CalfTheme.muted(widget.theme),
                    ),
                  )
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(
                        PieChartData(
                          sectionsSpace: 0,
                          centerSpaceRadius: 0,
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
                                radius: _touchedIndex == index ? 102 : 94,
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
                              horizontal: 8,
                              vertical: 6,
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
                                  textAlign: TextAlign.center,
                                  style: widget.theme.textTheme.bodySmall!
                                      .copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$touchedPercent%',
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
    this.leadingIcons,
    this.menuBuilder,
    this.onMenuSelected,
  });

  final ThemeData theme;
  final List<String> columns;
  final List<List<String>> rows;
  final Future<void> Function(String value) onCopy;
  final int? copyColumnIndex;
  final List<BuildRowIconKind>? leadingIcons;
  final List<PopupMenuEntry<String>> Function(List<String> row)? menuBuilder;
  final Future<void> Function(String action, List<String> row)? onMenuSelected;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Text('No data found', style: CalfTheme.muted(theme));
    }

    final showMenu = menuBuilder != null && onMenuSelected != null;
    final showIcons =
        leadingIcons != null && leadingIcons!.length == rows.length;

    return Column(
      children: [
        Row(
          children: [
            if (showIcons) const SizedBox(width: 34),
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
            SizedBox(width: showMenu ? 40 : 32),
          ],
        ),
        const SizedBox(height: 8),
        for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                if (showIcons) ...[
                  BuildRowIcon(kind: leadingIcons![rowIndex]),
                  const SizedBox(width: 12),
                ],
                for (var index = 0; index < columns.length; index++) ...[
                  Expanded(
                    child: Text(
                      rows[rowIndex].length > index
                          ? rows[rowIndex][index]
                          : '',
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                if (showMenu)
                  PopupMenuButton<String>(
                    tooltip: 'Actions',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(color: theme.colorScheme.outlineVariant),
                    ),
                    color: theme.colorScheme.surface,
                    surfaceTintColor: const Color(0x00000000),
                    icon: Icon(
                      LucideIcons.ellipsisVertical,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onSelected: (action) =>
                        onMenuSelected!(action, rows[rowIndex]),
                    itemBuilder: (context) => menuBuilder!(rows[rowIndex]),
                  )
                else if (rows[rowIndex].isNotEmpty)
                  Builder(
                    builder: (context) {
                      final row = rows[rowIndex];
                      final copyIndex = copyColumnIndex ?? row.length - 1;
                      if (copyIndex < 0 ||
                          copyIndex >= row.length ||
                          row[copyIndex].isEmpty) {
                        return const SizedBox(width: 32);
                      }

                      return CalfButton.ghost(
                        width: 28,
                        height: 28,
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
            Icon(LucideIcons.box, size: 16, color: theme.colorScheme.onSurface),

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
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.2,
              ),
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
    required this.onExpandAll,
    required this.onCollapseAll,
    required this.onCopy,
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
  final VoidCallback onExpandAll;
  final VoidCallback onCollapseAll;
  final VoidCallback onCopy;

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

    final expandableIndexes = [
      for (var index = 0; index < steps.length; index++)
        if (steps[index].log.isNotEmpty) index,
    ];
    final hasExpandableSteps = expandableIndexes.isNotEmpty;
    final showExpandControls = !plainLogs && hasExpandableSteps;
    final allExpanded =
        showExpandControls &&
        expandableIndexes.every(expandedSteps.contains);
    final anyExpanded =
        showExpandControls &&
        expandableIndexes.any(expandedSteps.contains);

    return Column(
      children: [
        _LogsToolbar(
          theme: theme,
          plainLogs: plainLogs,
          reserveExpandSlot: hasExpandableSteps,
          showExpandControls: showExpandControls,
          allExpanded: allExpanded,
          anyExpanded: anyExpanded,
          canCopy: rawLog.isNotEmpty,
          onTogglePlain: onTogglePlain,
          onExpandAll: onExpandAll,
          onCollapseAll: onCollapseAll,
          onCopy: onCopy,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: plainLogs
              ? _buildPlainLogs()
              : _StepLogsPanel(
                  theme: theme,
                  steps: steps,
                  totalMs: detail.durationMs,
                  expandedSteps: expandedSteps,
                  onToggleStep: onToggleStep,
                ),
        ),
      ],
    );
  }

  /// Builds the plain-text log viewer.
  Widget _buildPlainLogs() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.2,
        ),
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
    );
  }
}

/// Step list with a fixed timeline ruler driven by scroll position.
class _StepLogsPanel extends StatefulWidget {
  /// Creates a [_StepLogsPanel] widget.
  const _StepLogsPanel({
    required this.theme,
    required this.steps,
    required this.totalMs,
    required this.expandedSteps,
    required this.onToggleStep,
  });

  final ThemeData theme;
  final List<BuildStep> steps;
  final int totalMs;
  final Set<int> expandedSteps;
  final ValueChanged<int> onToggleStep;

  /// Creates the mutable state for [_StepLogsPanel].
  @override
  State<_StepLogsPanel> createState() => _StepLogsPanelState();
}

class _StepLogsPanelState extends State<_StepLogsPanel> {
  final ScrollController _scrollController = ScrollController();
  double _viewStart = 0;
  double _viewEnd = 1;

  /// Attaches the scroll listener and seeds the initial viewport range.
  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_syncViewport);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncViewport());
  }

  /// Recomputes the viewport range when expand/collapse changes content height.
  @override
  void didUpdateWidget(covariant _StepLogsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final expandedChanged =
        oldWidget.expandedSteps.length != widget.expandedSteps.length ||
        !oldWidget.expandedSteps.containsAll(widget.expandedSteps) ||
        !widget.expandedSteps.containsAll(oldWidget.expandedSteps);
    if (expandedChanged ||
        oldWidget.steps.length != widget.steps.length ||
        oldWidget.totalMs != widget.totalMs) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncViewport());
    }
  }

  /// Detaches the scroll listener and disposes the controller.
  @override
  void dispose() {
    _scrollController.removeListener(_syncViewport);
    _scrollController.dispose();
    super.dispose();
  }

  /// Maps the current scroll window onto the build timeline as 0–1 fractions.
  void _syncViewport() {
    if (!_scrollController.hasClients) {
      return;
    }

    final position = _scrollController.position;
    final content = position.maxScrollExtent + position.viewportDimension;
    if (content <= 0) {
      return;
    }

    final start = (position.pixels / content).clamp(0.0, 1.0);
    final end = ((position.pixels + position.viewportDimension) / content)
        .clamp(0.0, 1.0);
    if ((start - _viewStart).abs() < 0.0005 &&
        (end - _viewEnd).abs() < 0.0005) {
      return;
    }

    setState(() {
      _viewStart = start;
      _viewEnd = end;
    });
  }

  /// Builds the fixed ruler (when duration > 0) and the scrollable step list.
  @override
  Widget build(BuildContext context) {
    final totalMs = widget.totalMs;
    final showRuler = totalMs > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showRuler) ...[
          _BuildLogsRuler(
            theme: widget.theme,
            totalMs: totalMs,
            viewStart: _viewStart,
            viewEnd: _viewEnd,
          ),
          const SizedBox(height: 4),
        ],
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            itemCount: widget.steps.length,
            itemBuilder: (context, index) {
              final step = widget.steps[index];
              final expandable = step.log.isNotEmpty;
              final expanded = widget.expandedSteps.contains(index);
              final badge = step.index > 0
                  ? '${step.index}/${step.total}'
                  : 'internal';

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  children: [
                    HoverListRow(
                      theme: widget.theme,
                      onTap: expandable
                          ? () => widget.onToggleStep(index)
                          : null,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          if (expandable) ...[
                            Icon(
                              expanded
                                  ? LucideIcons.chevronUp
                                  : LucideIcons.chevronDown,
                              size: 16,
                              color: widget.theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                          ] else
                            const SizedBox(width: 22),
                          _StepBadge(theme: widget.theme, label: badge),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              step.name,
                              style: widget.theme.textTheme.titleMedium!
                                  .copyWith(fontFamily: 'Menlo'),
                            ),
                          ),
                          if (step.cached)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: widget.theme.colorScheme.primary
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                'CACHED',
                                style: widget.theme.textTheme.bodySmall!
                                    .copyWith(
                                  color: widget.theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          const SizedBox(width: 8),
                          Text(
                            _formatDuration(step.durationMs),
                            style: CalfTheme.muted(widget.theme),
                          ),
                        ],
                      ),
                    ),
                    if (expanded && expandable)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(left: 40, top: 4),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: widget.theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: SelectableText(
                          step.log,
                          style: widget.theme.textTheme.bodySmall!.copyWith(
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

/// Fixed build-duration ruler with a viewport marker tied to log scroll.
class _BuildLogsRuler extends StatelessWidget {
  /// Creates a [_BuildLogsRuler] widget.
  const _BuildLogsRuler({
    required this.theme,
    required this.totalMs,
    required this.viewStart,
    required this.viewEnd,
  });

  final ThemeData theme;
  final int totalMs;
  final double viewStart;
  final double viewEnd;

  static const double _height = 28;

  /// Builds the labeled tick strip and blue viewport marker.
  @override
  Widget build(BuildContext context) {
    final totalSeconds = totalMs / 1000.0;
    final interval = _rulerTickIntervalSeconds(totalSeconds);
    final tickColor = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.45);
    final labelStyle = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontSize: 11,
      height: 1,
    );

    return SizedBox(
      height: _height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          if (width <= 0 || totalSeconds <= 0) {
            return const SizedBox.shrink();
          }

          final markerLeft = (viewStart.clamp(0.0, 1.0) * width);
          final markerRight = (viewEnd.clamp(0.0, 1.0) * width);
          final markerWidth = (markerRight - markerLeft).clamp(4.0, width);

          final ticks = <Widget>[];
          for (var t = interval; t < totalSeconds - interval * 0.25; t += interval) {
            final x = (t / totalSeconds) * width;
            ticks.add(
              Positioned(
                left: x - 18,
                top: 0,
                width: 36,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatRulerTick(t, interval),
                      textAlign: TextAlign.center,
                      style: labelStyle,
                    ),
                    const SizedBox(height: 2),
                    Container(width: 1, height: 6, color: tickColor),
                  ],
                ),
              ),
            );
          }

          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 1,
                child: ColoredBox(color: tickColor),
              ),
              Positioned(
                left: markerLeft,
                bottom: 0,
                width: markerWidth,
                height: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              ...ticks,
            ],
          );
        },
      ),
    );
  }
}

/// Picks a readable tick spacing for [totalSeconds] on the build logs ruler.
double _rulerTickIntervalSeconds(double totalSeconds) {
  if (totalSeconds <= 1.5) {
    return 0.1;
  }
  if (totalSeconds <= 5) {
    return 0.5;
  }
  if (totalSeconds <= 15) {
    return 1;
  }
  if (totalSeconds <= 90) {
    return 6;
  }
  if (totalSeconds <= 180) {
    return 15;
  }
  if (totalSeconds <= 600) {
    return 30;
  }
  return 60;
}

/// Formats a ruler tick label for [seconds] given the chosen [interval].
String _formatRulerTick(double seconds, double interval) {
  if (interval < 1) {
    final rounded = (seconds * 10).round() / 10;
    if (rounded == rounded.roundToDouble()) {
      return '${rounded.toInt()}s';
    }
    return '${rounded.toStringAsFixed(1)}s';
  }

  return '${seconds.round()}s';
}

/// Icon toolbar for build log view mode, expand/collapse, and copy.
class _LogsToolbar extends StatelessWidget {
  /// Creates a [_LogsToolbar] widget.
  const _LogsToolbar({
    required this.theme,
    required this.plainLogs,
    required this.reserveExpandSlot,
    required this.showExpandControls,
    required this.allExpanded,
    required this.anyExpanded,
    required this.canCopy,
    required this.onTogglePlain,
    required this.onExpandAll,
    required this.onCollapseAll,
    required this.onCopy,
  });

  final ThemeData theme;
  final bool plainLogs;
  final bool reserveExpandSlot;
  final bool showExpandControls;
  final bool allExpanded;
  final bool anyExpanded;
  final bool canCopy;
  final ValueChanged<bool> onTogglePlain;
  final VoidCallback onExpandAll;
  final VoidCallback onCollapseAll;
  final VoidCallback onCopy;

  /// Height of view-mode and expand/collapse [CalfButtonGroup]s.
  static const double _groupSize = 36;

  /// Width of the expand/collapse [CalfButtonGroup] (2 segments + divider).
  static const double _expandGroupWidth = _groupSize + 12 + 1 + _groupSize + 12;

  /// Builds the right-aligned logs action strip.
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        CalfButtonGroup(
          size: _groupSize,
          actions: [
            CalfGroupAction(
              icon: LucideIcons.list,
              tooltip: 'List view',
              selected: !plainLogs,
              onPressed: () => onTogglePlain(false),
            ),
            CalfGroupAction(
              icon: LucideIcons.type,
              tooltip: 'Plain-text view',
              selected: plainLogs,
              onPressed: () => onTogglePlain(true),
            ),
          ],
        ),
        if (reserveExpandSlot) ...[
          const SizedBox(width: 8),
          SizedBox(
            width: _expandGroupWidth,
            height: _groupSize,
            child: showExpandControls
                ? CalfButtonGroup(
                    size: _groupSize,
                    actions: [
                      CalfGroupAction(
                        icon: LucideIcons.unfoldVertical,
                        tooltip: 'Expand all',
                        selected: false,
                        enabled: !allExpanded,
                        onPressed: onExpandAll,
                      ),
                      CalfGroupAction(
                        icon: LucideIcons.foldVertical,
                        tooltip: 'Collapse all',
                        selected: false,
                        enabled: anyExpanded,
                        onPressed: onCollapseAll,
                      ),
                    ],
                  )
                : null,
          ),
        ],
        const SizedBox(width: 8),
        Tooltip(
          message: 'Copy to clipboard',
          child: CalfButton.ghost(
            width: _groupSize,
            height: _groupSize,
            padding: EdgeInsets.zero,
            enabled: canCopy,
            onPressed: onCopy,
            child: Icon(
              LucideIcons.copy,
              size: 14,
              color: canCopy
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
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
          style: theme.textTheme.titleMedium!.copyWith(
            fontWeight: FontWeight.w600,
          ),
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
          style: theme.textTheme.titleMedium!.copyWith(
            fontWeight: FontWeight.w600,
          ),
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
                  Expanded(
                    child: Text(item.tag, style: theme.textTheme.titleMedium),
                  ),
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

/// Formats a build start/end timestamp as local `YYYY-MM-DD HH:MM:SS`.
String _formatBuildTimestamp(String raw) {
  if (raw.isEmpty) {
    return '—';
  }

  final parsed = _parseBuildTimestamp(raw);
  if (parsed == null) {
    return raw;
  }

  final local = parsed.toLocal();

  /// Pads a number to two digits for timestamp formatting.
  String two(int value) => value.toString().padLeft(2, '0');

  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// Parses an API build timestamp, truncating nanoseconds when needed.
DateTime? _parseBuildTimestamp(String raw) {
  try {
    return DateTime.parse(raw);
  } on FormatException {
    final truncated = raw.replaceFirstMapped(
      RegExp(r'\.(\d{6})\d+'),
      (match) => '.${match[1]}',
    );
    try {
      return DateTime.parse(truncated);
    } on FormatException {
      return null;
    }
  }
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
                    getDrawingHorizontalLine: (_) => FlLine(
                      color: theme.colorScheme.outlineVariant,
                      strokeWidth: 1,
                    ),
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
                              color: theme.colorScheme.outlineVariant
                                  .withValues(alpha: 0.55),
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
