import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/screens/volume_quick_export_screen.dart';
import 'package:ui/screens/volume_schedule_export_screen.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/calf_tab_bar.dart';
import 'package:ui/widgets/detail_breadcrumb.dart';
import 'package:ui/widgets/files_panel.dart';

enum _VolumeDetailTab { storedData, containersInUse, exports }

enum _VolumeDetailView { detail, quickExport, scheduleExport }

class VolumeDetailView extends StatefulWidget {
  /// Creates a [VolumeDetailView] widget.
  const VolumeDetailView({
    super.key,
    required this.volumeName,
    required this.apiClient,
    required this.onBack,
    required this.onRemoved,
  });

  final String volumeName;
  final CalfClient apiClient;
  final VoidCallback onBack;
  final Future<void> Function() onRemoved;

  /// Creates the mutable state for [VolumeDetailView].
  @override
  State<VolumeDetailView> createState() => _VolumeDetailViewState();
}

class _VolumeDetailViewState extends State<VolumeDetailView> {
  _VolumeDetailTab _tab = _VolumeDetailTab.storedData;
  _VolumeDetailView _view = _VolumeDetailView.detail;
  VolumeExportScheduleItem? _editingSchedule;
  VolumeDetail? _detail;
  List<VolumeContainerUsage> _containers = [];
  List<VolumeExportItem> _exports = [];
  List<VolumeExportScheduleItem> _schedules = [];
  bool _detailLoading = true;
  bool _containersLoading = false;
  bool _exportsLoading = false;
  bool _schedulesLoading = false;
  String? _detailError;
  String? _containersError;
  String? _exportsError;
  String? _schedulesError;
  String? _downloadError;
  bool _busy = false;
  String? _downloadingExportId;
  String? _togglingScheduleId;

  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    _loadDetail();
    _loadContainers();
  }

  /// Fetches Detail from the API and updates state.
  Future<void> _loadDetail() async {
    setState(() {
      _detailLoading = true;
      _detailError = null;
    });

    try {
      final detail = await widget.apiClient.fetchVolumeDetail(
        widget.volumeName,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _detail = detail;
        _detailLoading = false;
      });
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

  /// Switches the active tab and loads tab-specific data.
  void _selectTab(_VolumeDetailTab tab) {
    if (_tab == tab) {
      return;
    }

    setState(() => _tab = tab);
    if (tab == _VolumeDetailTab.containersInUse) {
      _loadContainers();
    } else if (tab == _VolumeDetailTab.exports) {
      _loadExportsTab();
    }
  }

  /// Fetches ExportsTab from the API and updates state.
  Future<void> _loadExportsTab() async {
    await Future.wait([_loadExports(), _loadSchedules()]);
  }

  /// Fetches Containers from the API and updates state.
  Future<void> _loadContainers() async {
    setState(() {
      _containersLoading = true;
      _containersError = null;
    });

    try {
      final containers = await widget.apiClient.fetchVolumeContainers(
        widget.volumeName,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _containers = containers;
        _containersLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _containersError = error.toString();
        _containersLoading = false;
      });
    }
  }

  /// Fetches Exports from the API and updates state.
  Future<void> _loadExports() async {
    setState(() {
      _exportsLoading = true;
      _exportsError = null;
    });

    try {
      final exports = await widget.apiClient.fetchVolumeExports(
        widget.volumeName,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _exports = exports;
        _exportsLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _exportsError = error.toString();
        _exportsLoading = false;
      });
    }
  }

  /// Fetches Schedules from the API and updates state.
  Future<void> _loadSchedules() async {
    setState(() {
      _schedulesLoading = true;
      _schedulesError = null;
    });

    try {
      final schedules = await widget.apiClient.fetchVolumeExportSchedules(
        widget.volumeName,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _schedules = schedules;
        _schedulesLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _schedulesError = error.toString();
        _schedulesLoading = false;
      });
    }
  }

  /// Removes the selected resource via the API.
  Future<void> _removeVolume() async {
    setState(() {
      _busy = true;
    });

    try {
      await widget.apiClient.removeVolume(widget.volumeName);
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      await widget.onRemoved();
      widget.onBack();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _detailError = error.toString();
      });
    }
  }

  /// Navigates to or opens the selected quickexport.
  void _openQuickExport() {
    setState(() => _view = _VolumeDetailView.quickExport);
  }

  /// Closes the current detail view and returns to the list.
  void _closeQuickExport() {
    setState(() => _view = _VolumeDetailView.detail);
  }

  /// Navigates to or opens the selected scheduleexport.
  void _openScheduleExport() {
    setState(() {
      _editingSchedule = null;
      _view = _VolumeDetailView.scheduleExport;
    });
  }

  /// Navigates to or opens the selected scheduleedit.
  void _openScheduleEdit(VolumeExportScheduleItem schedule) {
    setState(() {
      _editingSchedule = schedule;
      _view = _VolumeDetailView.scheduleExport;
    });
  }

  /// Closes the current detail view and returns to the list.
  void _closeScheduleExport() {
    setState(() {
      _editingSchedule = null;
      _view = _VolumeDetailView.detail;
    });
  }

  /// Handles completion of the parent flow and refreshes exports.
  void _onScheduleCompleted() {
    setState(() {
      _editingSchedule = null;
      _view = _VolumeDetailView.detail;
      _tab = _VolumeDetailTab.exports;
    });
    _loadExportsTab();
  }

  /// Enables or disables an export schedule via the API.
  Future<void> _setScheduleEnabled(
    VolumeExportScheduleItem schedule,
    bool enabled,
  ) async {
    setState(() {
      _togglingScheduleId = schedule.id;
      _schedulesError = null;
    });

    try {
      await widget.apiClient.updateVolumeExportSchedule(
        volumeName: widget.volumeName,
        scheduleId: schedule.id,
        enabled: enabled,
      );
      if (!mounted) {
        return;
      }
      await _loadSchedules();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _schedulesError = error.toString());
    } finally {
      if (mounted) {
        setState(() => _togglingScheduleId = null);
      }
    }
  }

  /// Handles completion of the parent flow and refreshes exports.
  void _onExportCompleted() {
    setState(() {
      _view = _VolumeDetailView.detail;
      _tab = _VolumeDetailTab.exports;
    });
    _loadExportsTab();
  }

  /// Downloads the export file and saves it to a user-chosen location.
  Future<void> _downloadExport(VolumeExportItem export) async {
    setState(() {
      _downloadingExportId = export.id;
      _downloadError = null;
    });

    try {
      final suggestedName = export.fileName.isNotEmpty
          ? export.fileName
          : '${widget.volumeName}.tar.gz';
      final location = await getSaveLocation(suggestedName: suggestedName);
      if (location == null) {
        if (mounted) {
          setState(() => _downloadingExportId = null);
        }
        return;
      }

      final bytes = await widget.apiClient.downloadVolumeExport(
        widget.volumeName,
        export.id,
      );
      await File(location.path).writeAsBytes(bytes);
      if (!mounted) {
        return;
      }
      setState(() => _downloadingExportId = null);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _downloadingExportId = null;
        _downloadError = error.toString();
      });
    }
  }

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    if (_view == _VolumeDetailView.quickExport) {
      return VolumeQuickExportView(
        volumeName: widget.volumeName,
        apiClient: widget.apiClient,
        onBack: _closeQuickExport,
        onCompleted: _onExportCompleted,
      );
    }

    if (_view == _VolumeDetailView.scheduleExport) {
      return VolumeScheduleExportView(
        key: ValueKey(_editingSchedule?.id ?? 'new-schedule'),
        volumeName: widget.volumeName,
        apiClient: widget.apiClient,
        existingSchedule: _editingSchedule,
        onBack: _closeScheduleExport,
        onCompleted: _onScheduleCompleted,
      );
    }

    final theme = ShadTheme.of(context);
    final detail = _detail;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailBreadcrumb(
          segments: ['Volumes', widget.volumeName],
          onBack: widget.onBack,
        ),
        /// Creates a [_VolumeDetailViewState] widget.
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        LucideIcons.hardDrive,
                        size: 20,
                        color: theme.colorScheme.foreground,
                      ),
                      /// Creates a [_VolumeDetailViewState] widget.
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.volumeName,
                          style: theme.textTheme.h3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  /// Creates a [_VolumeDetailViewState] widget.
                  const SizedBox(height: 8),
                  if (_detailLoading)
                    Text('Loading...', style: theme.textTheme.muted)
                  else if (_detailError != null)
                    Text(
                      _detailError!,
                      style: theme.textTheme.small.copyWith(
                        color: theme.colorScheme.destructive,
                      ),
                    )
                  else if (detail != null) ...[
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: detail.inUse
                                ? CalfColors.success
                                : theme.colorScheme.mutedForeground,
                            shape: BoxShape.circle,
                          ),
                        ),
                        /// Creates a [_VolumeDetailViewState] widget.
                        const SizedBox(width: 8),
                        Text(
                          detail.inUse ? 'In use' : 'Not in use',
                          style: theme.textTheme.large,
                        ),
                      ],
                    ),
                    if (detail.created.isNotEmpty) ...[
                      /// Creates a [_VolumeDetailViewState] widget.
                      const SizedBox(height: 12),
                      Text(
                        'Created ${detail.created}',
                        style: theme.textTheme.muted,
                      ),
                    ],
                  ],
                ],
              ),
            ),
            CalfButton.destructive(
              enabled: !_busy,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: _removeVolume,
              child: Icon(
                LucideIcons.trash2,
                size: 16,
                color: theme.colorScheme.destructiveForeground,
              ),
            ),
          ],
        ),
        /// Creates a [_VolumeDetailViewState] widget.
        const SizedBox(height: 16),
        CalfTabBar(
          theme: theme,
          labels: const ['Stored data', 'Container in-use', 'Exports'],
          selectedIndex: _tab.index,
          onSelected: (index) => _selectTab(_VolumeDetailTab.values[index]),
        ),
        /// Creates a [_VolumeDetailViewState] widget.
        const SizedBox(height: 16),
        Expanded(
          child: switch (_tab) {
            _VolumeDetailTab.storedData => FilesPanel(
              theme: theme,
              loadDirectory: (path) => widget.apiClient.fetchVolumeFiles(
                widget.volumeName,
                path: path,
              ),
            ),
            _VolumeDetailTab.containersInUse => _ContainersInUseTab(
              theme: theme,
              loading: _containersLoading,
              error: _containersError,
              containers: _containers,
            ),
            _VolumeDetailTab.exports => _ExportsTab(
              theme: theme,
              loading: _exportsLoading,
              schedulesLoading: _schedulesLoading,
              error: _exportsError,
              schedulesError: _schedulesError,
              downloadError: _downloadError,
              exports: _exports,
              schedules: _schedules,
              downloadingExportId: _downloadingExportId,
              onQuickExport: _openQuickExport,
              onScheduleExport: _openScheduleExport,
              onEditSchedule: _openScheduleEdit,
              onScheduleEnabledChanged: _setScheduleEnabled,
              togglingScheduleId: _togglingScheduleId,
              onDownload: _downloadExport,
            ),
          },
        ),
      ],
    );
  }
}

class _ExportsTab extends StatelessWidget {
  /// Creates a [_ExportsTab] widget.
  const _ExportsTab({
    required this.theme,
    required this.loading,
    required this.schedulesLoading,
    required this.error,
    required this.schedulesError,
    required this.downloadError,
    required this.exports,
    required this.schedules,
    required this.downloadingExportId,
    required this.onQuickExport,
    required this.onScheduleExport,
    required this.onEditSchedule,
    required this.onScheduleEnabledChanged,
    required this.togglingScheduleId,
    required this.onDownload,
  });

  final ShadThemeData theme;
  final bool loading;
  final bool schedulesLoading;
  final String? error;
  final String? schedulesError;
  final String? downloadError;
  final List<VolumeExportItem> exports;
  final List<VolumeExportScheduleItem> schedules;
  final String? downloadingExportId;
  final VoidCallback onQuickExport;
  final VoidCallback onScheduleExport;
  final ValueChanged<VolumeExportScheduleItem> onEditSchedule;
  final void Function(VolumeExportScheduleItem schedule, bool enabled)
  onScheduleEnabledChanged;
  final String? togglingScheduleId;
  final ValueChanged<VolumeExportItem> onDownload;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        _ExportSectionCard(
          theme: theme,
          title: 'Schedule export',
          subtitle:
              'Set schedules effortlessly and eliminate manual tasks, ensuring reliable and efficient data management.',
          action: CalfButton(
            onPressed: onScheduleExport,
            child: const Text('Add schedule'),
          ),
          child: schedulesLoading
              ? Text('Loading schedules...', style: theme.textTheme.muted)
              : schedulesError != null
              ? Text(
                  schedulesError!,
                  style: theme.textTheme.small.copyWith(
                    color: theme.colorScheme.destructive,
                  ),
                )
              : schedules.isEmpty
              ? Column(
                  children: [
                    Icon(
                      LucideIcons.calendarClock,
                      size: 28,
                      color: theme.colorScheme.mutedForeground,
                    ),
                    /// Creates a [_ExportsTab] widget.
                    const SizedBox(height: 12),
                    Text(
                      'Schedule exports',
                      style: theme.textTheme.large.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    /// Creates a [_ExportsTab] widget.
                    const SizedBox(height: 8),
                    Text(
                      'Use Add schedule to create recurring backups for this volume.',
                      style: theme.textTheme.muted,
                      textAlign: TextAlign.center,
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final schedule in schedules) ...[
                      _ScheduleHistoryRow(
                        theme: theme,
                        schedule: schedule,
                        toggling: togglingScheduleId == schedule.id,
                        onEdit: () => onEditSchedule(schedule),
                        onEnabledChanged: (enabled) =>
                            onScheduleEnabledChanged(schedule, enabled),
                      ),
                      if (schedule != schedules.last)
                        /// Creates a [_ExportsTab] widget.
                        const SizedBox(height: 12),
                    ],
                  ],
                ),
        ),
        /// Creates a [_ExportsTab] widget.
        const SizedBox(height: 16),
        _ExportSectionCard(
          theme: theme,
          title: 'Export logs',
          subtitle: 'View logs and monitor your export activities.',
          action: CalfButton(
            onPressed: onQuickExport,
            child: const Text('Quick export'),
          ),
          child: loading
              ? Text('Loading exports...', style: theme.textTheme.muted)
              : error != null
              ? Text(
                  error!,
                  style: theme.textTheme.small.copyWith(
                    color: theme.colorScheme.destructive,
                  ),
                )
              : exports.isEmpty
              ? Column(
                  children: [
                    Icon(
                      LucideIcons.fileText,
                      size: 28,
                      color: theme.colorScheme.mutedForeground,
                    ),
                    /// Creates a [_ExportsTab] widget.
                    const SizedBox(height: 12),
                    Text(
                      'No data',
                      style: theme.textTheme.large.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    /// Creates a [_ExportsTab] widget.
                    const SizedBox(height: 8),
                    Text(
                      'Use the Quick export button to create export history.',
                      style: theme.textTheme.muted,
                      textAlign: TextAlign.center,
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (downloadError != null) ...[
                      Text(
                        downloadError!,
                        style: theme.textTheme.small.copyWith(
                          color: theme.colorScheme.destructive,
                        ),
                      ),
                      /// Creates a [_ExportsTab] widget.
                      const SizedBox(height: 12),
                    ],
                    for (final export in exports) ...[
                      _ExportHistoryRow(
                        theme: theme,
                        export: export,
                        downloading: downloadingExportId == export.id,
                        onDownload:
                            export.downloadable && export.status == 'completed'
                            ? () => onDownload(export)
                            : null,
                      ),
                      if (export != exports.last)
                        Container(height: 1, color: theme.colorScheme.border),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _ExportSectionCard extends StatelessWidget {
  /// Creates a [_ExportSectionCard] widget.
  const _ExportSectionCard({
    required this.theme,
    required this.title,
    required this.subtitle,
    required this.child,
    this.action,
  });

  final ShadThemeData theme;
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? action;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.large.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    /// Creates a [_ExportSectionCard] widget.
                    const SizedBox(height: 4),
                    Text(subtitle, style: theme.textTheme.muted),
                  ],
                ),
              ),
              ?action,
            ],
          ),
          /// Creates a [_ExportSectionCard] widget.
          const SizedBox(height: 20),
          child,
        ],
      ),
    );
  }
}

class _ScheduleHistoryRow extends StatelessWidget {
  /// Creates a [_ScheduleHistoryRow] widget.
  const _ScheduleHistoryRow({
    required this.theme,
    required this.schedule,
    required this.toggling,
    required this.onEdit,
    required this.onEnabledChanged,
  });

  final ShadThemeData theme;
  final VolumeExportScheduleItem schedule;
  final bool toggling;
  final VoidCallback onEdit;
  final ValueChanged<bool> onEnabledChanged;

  /// Whether or what value backs the `typeIcon` UI state.
  IconData get _typeIcon {
    switch (schedule.type) {
      case 'local_image':
      case 'new_image':
        return LucideIcons.box;
      case 'registry':
        return LucideIcons.cloudUpload;
      default:
        return LucideIcons.fileArchive;
    }
  }

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final enabled = schedule.enabled;
    final enabledColor = enabled
        ? CalfColors.success
        : theme.colorScheme.mutedForeground;
    final lastStatusColor = schedule.lastStatus == 'completed'
        ? CalfColors.success
        : schedule.lastStatus == 'failed'
        ? theme.colorScheme.destructive
        : theme.colorScheme.mutedForeground;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.border),
        borderRadius: BorderRadius.circular(8),
        color: enabled ? null : theme.colorScheme.muted.withValues(alpha: 0.25),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_typeIcon, size: 18, color: theme.colorScheme.primary),
          ),
          /// Creates a [_ScheduleHistoryRow] widget.
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  schedule.typeLabel,
                  style: theme.textTheme.small.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                /// Creates a [_ScheduleHistoryRow] widget.
                const SizedBox(height: 10),
                if (schedule.dayTimes.isNotEmpty) ...[
                  for (final entry in schedule.dayTimes) ...[
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _ScheduleMiniChip(
                          theme: theme,
                          label: VolumeExportScheduleItem.weekdayShort(
                            entry.day,
                          ),
                          emphasized: enabled,
                        ),
                        for (final time in entry.times)
                          _ScheduleMiniChip(
                            theme: theme,
                            label: time,
                            icon: LucideIcons.clock,
                            emphasized: enabled,
                          ),
                      ],
                    ),
                    /// Creates a [_ScheduleHistoryRow] widget.
                    const SizedBox(height: 8),
                  ],
                ],
                if (schedule.destinationSummary.isNotEmpty) ...[
                  /// Creates a [_ScheduleHistoryRow] widget.
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        schedule.type == 'local_file'
                            ? LucideIcons.folder
                            : LucideIcons.tag,
                        size: 14,
                        color: theme.colorScheme.mutedForeground,
                      ),
                      /// Creates a [_ScheduleHistoryRow] widget.
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          schedule.destinationSummary,
                          style: theme.textTheme.muted,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
                if (enabled && schedule.formattedNextRun.isNotEmpty) ...[
                  /// Creates a [_ScheduleHistoryRow] widget.
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        LucideIcons.calendarClock,
                        size: 14,
                        color: theme.colorScheme.mutedForeground,
                      ),
                      /// Creates a [_ScheduleHistoryRow] widget.
                      const SizedBox(width: 6),
                      Text(
                        'Next run ${schedule.formattedNextRun}',
                        style: theme.textTheme.muted,
                      ),
                    ],
                  ),
                ],
                if (schedule.lastStatus.isNotEmpty) ...[
                  /// Creates a [_ScheduleHistoryRow] widget.
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text('Last run', style: theme.textTheme.small),
                      /// Creates a [_ScheduleHistoryRow] widget.
                      const SizedBox(width: 8),
                      _ScheduleBadge(
                        theme: theme,
                        label: schedule.lastStatus,
                        color: lastStatusColor,
                      ),
                    ],
                  ),
                ],
                if (schedule.lastError.isNotEmpty) ...[
                  /// Creates a [_ScheduleHistoryRow] widget.
                  const SizedBox(height: 8),
                  Text(
                    schedule.lastError,
                    style: theme.textTheme.small.copyWith(
                      color: theme.colorScheme.destructive,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          /// Creates a [_ScheduleHistoryRow] widget.
          const SizedBox(width: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                enabled ? 'Enabled' : 'Paused',
                style: theme.textTheme.small.copyWith(color: enabledColor),
              ),
              /// Creates a [_ScheduleHistoryRow] widget.
              const SizedBox(width: 8),
              ShadSwitch(
                value: enabled,
                onChanged: toggling ? null : onEnabledChanged,
              ),
              /// Creates a [_ScheduleHistoryRow] widget.
              const SizedBox(width: 12),
              CalfButton.outline(onPressed: onEdit, child: const Text('Edit')),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScheduleBadge extends StatelessWidget {
  /// Creates a [_ScheduleBadge] widget.
  const _ScheduleBadge({
    required this.theme,
    required this.label,
    required this.color,
  });

  final ShadThemeData theme;
  final String label;
  final Color color;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.small.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ScheduleMiniChip extends StatelessWidget {
  /// Creates a [_ScheduleMiniChip] widget.
  const _ScheduleMiniChip({
    required this.theme,
    required this.label,
    this.icon,
    this.emphasized = false,
  });

  final ShadThemeData theme;
  final String label;
  final IconData? icon;
  final bool emphasized;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final background = emphasized
        ? theme.colorScheme.primary.withValues(alpha: 0.12)
        : theme.colorScheme.muted.withValues(alpha: 0.45);
    final foreground = emphasized
        ? theme.colorScheme.primary
        : theme.colorScheme.foreground;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: emphasized
            ? Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.25),
              )
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: foreground),
            /// Creates a [_ScheduleMiniChip] widget.
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: theme.textTheme.small.copyWith(
              color: foreground,
              fontWeight: emphasized ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportHistoryRow extends StatelessWidget {
  /// Creates a [_ExportHistoryRow] widget.
  const _ExportHistoryRow({
    required this.theme,
    required this.export,
    required this.downloading,
    this.onDownload,
  });

  final ShadThemeData theme;
  final VolumeExportItem export;
  final bool downloading;
  final VoidCallback? onDownload;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final statusColor = switch (export.status) {
      'completed' => CalfColors.success,
      'failed' => theme.colorScheme.destructive,
      /// .
      _ => theme.colorScheme.mutedForeground,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  export.typeLabel,
                  style: theme.textTheme.small.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                /// Creates a [_ExportHistoryRow] widget.
                const SizedBox(height: 4),
                Text(
                  export.summary,
                  style: theme.textTheme.muted,
                  overflow: TextOverflow.ellipsis,
                ),
                if (export.error.isNotEmpty) ...[
                  /// Creates a [_ExportHistoryRow] widget.
                  const SizedBox(height: 4),
                  Text(
                    export.error,
                    style: theme.textTheme.small.copyWith(
                      color: theme.colorScheme.destructive,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (export.size.isNotEmpty) ...[
            Text(export.size, style: theme.textTheme.muted),
            /// Creates a [_ExportHistoryRow] widget.
            const SizedBox(width: 16),
          ],
          Text(export.createdAt, style: theme.textTheme.muted),
          /// Creates a [_ExportHistoryRow] widget.
          const SizedBox(width: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              export.status,
              style: theme.textTheme.small.copyWith(color: statusColor),
            ),
          ),
          if (onDownload != null) ...[
            /// Creates a [_ExportHistoryRow] widget.
            const SizedBox(width: 12),
            CalfButton.outline(
              enabled: !downloading,
              onPressed: onDownload,
              child: Text(downloading ? 'Downloading...' : 'Download'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ContainersInUseTab extends StatelessWidget {
  /// Creates a [_ContainersInUseTab] widget.
  const _ContainersInUseTab({
    required this.theme,
    required this.loading,
    required this.error,
    required this.containers,
  });

  final ShadThemeData theme;
  final bool loading;
  final String? error;
  final List<VolumeContainerUsage> containers;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Text('Loading containers...', style: theme.textTheme.muted);
    }

    if (error != null) {
      return Text(
        error!,
        style: theme.textTheme.large.copyWith(
          color: theme.colorScheme.destructive,
        ),
      );
    }

    if (containers.isEmpty) {
      return Text(
        'No containers are using this volume.',
        style: theme.textTheme.muted,
      );
    }

    final labelStyle = theme.textTheme.small.copyWith(
      color: theme.colorScheme.mutedForeground,
      fontWeight: FontWeight.w600,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Text('Container name', style: labelStyle),
              ),
              Expanded(flex: 3, child: Text('Image', style: labelStyle)),
              Expanded(child: Text('Port', style: labelStyle)),
              Expanded(flex: 2, child: Text('Target', style: labelStyle)),
            ],
          ),
        ),
        /// Creates a [_ContainersInUseTab] widget.
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            itemCount: containers.length,
            separatorBuilder: (_, _) =>
                Container(height: 1, color: theme.colorScheme.border),
            itemBuilder: (context, index) {
              final container = containers[index];

              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      LucideIcons.box,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    /// Creates a [_ContainersInUseTab] widget.
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 3,
                      child: Text(
                        container.name,
                        style: theme.textTheme.small.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(
                        container.image,
                        style: theme.textTheme.muted,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        container.port,
                        style: theme.textTheme.small.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        container.target,
                        style: theme.textTheme.muted,
                        overflow: TextOverflow.ellipsis,
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
