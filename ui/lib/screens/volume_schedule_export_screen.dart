import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/export_name_pattern.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/confirm_dialog.dart';
import 'package:ui/widgets/detail_breadcrumb.dart';
import 'package:ui/widgets/volume_export_form.dart';
import 'package:ui/theme/calf_theme.dart';

class VolumeScheduleExportView extends StatefulWidget {
  /// Creates a [VolumeScheduleExportView] widget.
  const VolumeScheduleExportView({
    super.key,
    required this.volumeName,
    required this.apiClient,
    required this.onBack,
    required this.onCompleted,
    this.existingSchedule,
  });

  final String volumeName;
  final CalfClient apiClient;
  final VoidCallback onBack;
  final VoidCallback onCompleted;
  final VolumeExportScheduleItem? existingSchedule;

  /// Returns the `isEditing` value.
  bool get isEditing => existingSchedule != null;

  /// Creates the mutable state for [VolumeScheduleExportView].
  @override
  State<VolumeScheduleExportView> createState() =>
      _VolumeScheduleExportViewState();
}

class _VolumeScheduleExportViewState extends State<VolumeScheduleExportView> {
  static const _weekdays = [
    (1, 'Mon'),
    (2, 'Tue'),
    (3, 'Wed'),
    (4, 'Thu'),
    (5, 'Fri'),
    (6, 'Sat'),
    (0, 'Sun'),
  ];

  VolumeQuickExportType _type = VolumeQuickExportType.localFile;
  final Map<int, List<TimeOfDay>> _dayTimes = {};
  final _fileNameController = TextEditingController();
  final _folderController = TextEditingController();
  final _imageRefController = TextEditingController();
  List<ImageItem> _images = [];
  bool _imagesLoading = false;
  String? _imagesError;
  bool _busy = false;
  String? _error;

  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    final schedule = widget.existingSchedule;
    if (schedule != null) {
      _type = volumeQuickExportTypeFromApi(schedule.type);
      _fileNameController.text = schedule.fileName.isNotEmpty
          ? schedule.fileName
          : defaultExportFileNamePattern();
      _folderController.text = schedule.folder;
      _imageRefController.text = schedule.imageRef;

      if (schedule.dayTimes.isNotEmpty) {
        for (final entry in schedule.dayTimes) {
          _dayTimes[entry.day] = entry.times.map(_parseExportTime).toList();
        }
      }
    } else {
      _fileNameController.text = defaultExportFileNamePattern();
    }
    _loadImages();
  }

  /// Releases controllers, timers, and stream subscriptions.
  @override
  void dispose() {
    _fileNameController.dispose();
    _folderController.dispose();
    _imageRefController.dispose();
    super.dispose();
  }

  /// Fetches Images from the API and updates state.
  Future<void> _loadImages() async {
    setState(() {
      _imagesLoading = true;
      _imagesError = null;
    });

    try {
      final images = await loadVolumeExportImages(widget.apiClient);
      if (!mounted) {
        return;
      }
      setState(() {
        _images = images;
        _imagesLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _imagesError = error.toString();
        _imagesLoading = false;
      });
    }
  }

  /// Whether or what value backs the `normalizedDayTimes` UI state.
  List<VolumeExportDayTimes> get _normalizedDayTimes {
    final days = _dayTimes.keys.toList()
      ..sort(VolumeExportScheduleItem.compareWeekdays);
    return [
      for (final day in days)
        if (_dayTimes[day]!.isNotEmpty)
          VolumeExportDayTimes(
            day: day,
            times: _dayTimes[day]!.map(_formatExportTime).toList(),
          ),
    ];
  }

  /// Whether or what value backs the `hasValidTimes` UI state.
  bool get _hasValidTimes =>
      _dayTimes.isNotEmpty &&
      _dayTimes.values.every((times) => times.isNotEmpty);

  /// Parses the input string into a typed value.
  TimeOfDay _parseExportTime(String value) {
    final parts = value.split(':');
    if (parts.length != 2) {
      return const TimeOfDay(hour: 3, minute: 0);
    }

    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null ||
        minute == null ||
        hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59) {
      return const TimeOfDay(hour: 3, minute: 0);
    }

    return TimeOfDay(hour: hour, minute: minute);
  }

  /// Formats the value for display.
  String _formatExportTime(TimeOfDay time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  /// Returns the short weekday label for [day].
  String _weekdayLabel(int day) {
    return _weekdays.firstWhere((entry) => entry.$1 == day).$2;
  }

  /// Whether or what value backs the `hasValidDestination` UI state.
  bool get _hasValidDestination {
    switch (_type) {
      case VolumeQuickExportType.localFile:
        return _fileNameController.text.trim().isNotEmpty &&
            _folderController.text.trim().isNotEmpty;
      case VolumeQuickExportType.localImage:
        return _imageRefController.text.trim().isNotEmpty;
      case VolumeQuickExportType.newImage:
      case VolumeQuickExportType.registry:
        return _imageRefController.text.trim().isNotEmpty;
    }
  }

  /// Whether or what value backs the `namePatternPreview` UI state.
  String get _namePatternPreview {
    final sampleTime = DateTime.now();
    switch (_type) {
      case VolumeQuickExportType.localFile:
        return expandExportFileNamePattern(
          _fileNameController.text,
          widget.volumeName,
          sampleTime,
        );
      case VolumeQuickExportType.newImage:
      case VolumeQuickExportType.registry:
        return expandExportImageRefPattern(
          _imageRefController.text,
          widget.volumeName,
          sampleTime,
        );
      case VolumeQuickExportType.localImage:
        return _imageRefController.text.trim();
    }
  }

  /// Inserts a pattern token at the current cursor position.
  void _insertPatternToken(TextEditingController controller, String token) {
    final text = controller.text;
    final selection = controller.selection;
    final start = selection.start >= 0 ? selection.start : text.length;
    final end = selection.end >= 0 ? selection.end : text.length;
    final updated = text.replaceRange(start, end, token);
    controller.text = updated;
    controller.selection = TextSelection.collapsed(
      offset: start + token.length,
    );
    setState(() {});
  }

  /// Whether or what value backs the `persistEnabled` UI state.
  bool get _persistEnabled => widget.existingSchedule?.enabled ?? true;

  /// Whether or what value backs the `canApply` UI state.
  bool get _canApply {
    if (_busy) {
      return false;
    }

    return _dayTimes.isNotEmpty && _hasValidTimes && _hasValidDestination;
  }

  /// Whether or what value backs the `cronSummary` UI state.
  String get _cronSummary {
    if (_dayTimes.isEmpty || !_hasValidTimes) {
      return '';
    }

    final days = _dayTimes.keys.toList()
      ..sort(VolumeExportScheduleItem.compareWeekdays);
    return days
        .map((day) {
          final times = _dayTimes[day]!.map(_formatExportTime).join(', ');
          return '${_weekdayLabel(day)} at $times';
        })
        .join('; ');
  }

  /// Toggles the corresponding UI state.
  void _toggleDay(int day) {
    setState(() {
      if (_dayTimes.containsKey(day)) {
        _dayTimes.remove(day);
        _rebuildTimeRowKeys(day);
      } else {
        _dayTimes[day] = [const TimeOfDay(hour: 3, minute: 0)];
      }
    });
  }

  /// Adds a new entry to the form state.
  void _addTime(int day) {
    setState(() {
      _dayTimes[day]!.add(const TimeOfDay(hour: 12, minute: 0));
    });
  }

  /// Removes the selected resource via the API.
  void _removeTime(int day, int index) {
    if (_dayTimes[day]!.length <= 1) {
      return;
    }

    setState(() {
      _commitPendingTimes();
      _dayTimes[day]!.removeAt(index);
      _rebuildTimeRowKeys(day);
    });
  }

  /// Updates the corresponding form field in state.
  void _updateExportTime(int day, int index, TimeOfDay time) {
    setState(() => _dayTimes[day]![index] = time);
  }

  /// Switches export type and clears the shared image reference field.
  void _setExportType(VolumeQuickExportType type) {
    if (_type == type) {
      return;
    }

    setState(() {
      _type = type;
      _imageRefController.clear();
    });
  }

  /// Opens a folder picker and stores the selected path.
  Future<void> _browseFolder() async {
    try {
      final location = await browseVolumeExportFolder();
      if (location == null || !mounted) {
        return;
      }

      setState(() {
        _folderController.text = location;
        _error = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = folderPickerErrorMessage(error));
    }
  }

  /// Builds the schedule payload fields for the API request.
  Map<String, dynamic> _scheduleFields() {
    final type = volumeQuickExportTypeToApi(_type);

    return {
      'type': type,
      'dayTimes': _committedDayTimes,
      'fileName': _fileNameController.text.trim(),
      'folder': _folderController.text.trim(),
      'imageRef': _imageRefController.text.trim(),
    };
  }

  /// Whether or what value backs the `committedDayTimes` UI state.
  List<VolumeExportDayTimes> get _committedDayTimes {
    _commitPendingTimes();
    return _normalizedDayTimes;
  }

  final Map<String, GlobalKey<_ExportTimeRowState>> _timeRowKeys = {};

  /// Returns or creates the state key for a time row editor.
  GlobalKey<_ExportTimeRowState> _timeRowKey(int day, int index) {
    final keyId = '$day-$index';
    return _timeRowKeys.putIfAbsent(keyId, GlobalKey<_ExportTimeRowState>.new);
  }

  /// Discards cached row keys for [day] after indices shift.
  void _rebuildTimeRowKeys(int day) {
    _timeRowKeys.removeWhere((key, _) => key.startsWith('$day-'));
  }

  /// Flushes pending editor values into committed state.
  void _commitPendingTimes() {
    for (final entry in _timeRowKeys.entries) {
      final state = entry.value.currentState;
      if (state == null) {
        continue;
      }

      final parts = entry.key.split('-');
      if (parts.length != 2) {
        continue;
      }

      final day = int.tryParse(parts[0]);
      final index = int.tryParse(parts[1]);
      if (day == null || index == null) {
        continue;
      }

      final times = _dayTimes[day];
      if (times == null || index < 0 || index >= times.length) {
        continue;
      }

      times[index] = state.currentTime;
    }
  }

  /// Validates and persists schedule changes via the API.
  Future<void> _applyChanges() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final fields = _scheduleFields();
      final dayTimes = fields['dayTimes'] as List<VolumeExportDayTimes>;
      if (dayTimes.isEmpty) {
        setState(() {
          _busy = false;
          _error = 'Select at least one day and export time.';
        });
        return;
      }

      if (widget.isEditing) {
        await widget.apiClient.updateVolumeExportSchedule(
          volumeName: widget.volumeName,
          scheduleId: widget.existingSchedule!.id,
          enabled: _persistEnabled,
          dayTimes: fields['dayTimes'] as List<VolumeExportDayTimes>,
          type: fields['type'] as String,
          fileName: fields['fileName'] as String,
          folder: fields['folder'] as String,
          imageRef: fields['imageRef'] as String,
        );
      } else {
        await widget.apiClient.createVolumeExportSchedule(
          name: widget.volumeName,
          enabled: true,
          type: fields['type'] as String,
          dayTimes: fields['dayTimes'] as List<VolumeExportDayTimes>,
          fileName: fields['fileName'] as String,
          folder: fields['folder'] as String,
          imageRef: fields['imageRef'] as String,
        );
      }

      if (!mounted) {
        return;
      }

      widget.onCompleted();
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

  /// Shows a confirmation dialog before performing the destructive action.
  Future<void> _confirmDelete() async {
    final schedule = widget.existingSchedule;
    if (schedule == null) {
      return;
    }

    final confirmed = await confirmDialog(
      context,
      title: 'Delete schedule',
      description:
          'Remove the scheduled export for "${widget.volumeName}"? This cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await widget.apiClient.deleteVolumeExportSchedule(
        widget.volumeName,
        schedule.id,
      );
      if (!mounted) {
        return;
      }
      widget.onCompleted();
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

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sortedDays = _dayTimes.keys.toList()
      ..sort(VolumeExportScheduleItem.compareWeekdays);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailBreadcrumb(
          segments: [
            'Volumes',
            widget.volumeName,
            widget.isEditing ? 'Edit schedule' : 'Schedule export',
          ],
          onBack: widget.onBack,
          onBackEnabled: !_busy,
        ),

        /// Creates a [_VolumeScheduleExportViewState] widget.
        const SizedBox(height: 16),
        Text(
          widget.isEditing ? 'Edit schedule' : 'Schedule export',
          style: theme.textTheme.headlineSmall,
        ),

        /// Creates a [_VolumeScheduleExportViewState] widget.
        const SizedBox(height: 8),
        Text(
          'Choose which days and times Calf should export this volume automatically.',
          style: CalfTheme.muted(theme),
        ),

        /// Creates a [_VolumeScheduleExportViewState] widget.
        const SizedBox(height: 20),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Days',
                        style: theme.textTheme.titleMedium!.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),

                      /// Creates a [_VolumeScheduleExportViewState] widget.
                      const SizedBox(height: 8),
                      Text(
                        'Select the days of the week when exports should run.',
                        style: CalfTheme.muted(theme),
                      ),

                      /// Creates a [_VolumeScheduleExportViewState] widget.
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final (day, label) in _weekdays)
                            _DayChip(
                              theme: theme,
                              label: label,
                              selected: _dayTimes.containsKey(day),
                              onTap: _busy ? null : () => _toggleDay(day),
                            ),
                        ],
                      ),
                      if (_dayTimes.isNotEmpty) ...[
                        /// Creates a [_VolumeScheduleExportViewState] widget.
                        const SizedBox(height: 20),
                        for (
                          var dayIndex = 0;
                          dayIndex < sortedDays.length;
                          dayIndex++
                        ) ...[
                          if (dayIndex > 0) const SizedBox(height: 12),
                          Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _weekdayLabel(sortedDays[dayIndex]),
                                        style: theme.textTheme.titleMedium!
                                            .copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ),
                                    CalfButton.outline(
                                      enabled: !_busy,
                                      onPressed: () =>
                                          _addTime(sortedDays[dayIndex]),
                                      child: const Text('Add time'),
                                    ),
                                  ],
                                ),

                                /// Creates a [_VolumeScheduleExportViewState] widget.
                                const SizedBox(height: 8),
                                Text(
                                  'Set one or more export times for ${_weekdayLabel(sortedDays[dayIndex])}.',
                                  style: CalfTheme.muted(theme),
                                ),

                                /// Creates a [_VolumeScheduleExportViewState] widget.
                                const SizedBox(height: 12),
                                for (
                                  var index = 0;
                                  index <
                                      _dayTimes[sortedDays[dayIndex]]!.length;
                                  index++
                                ) ...[
                                  _ExportTimeRow(
                                    key: _timeRowKey(
                                      sortedDays[dayIndex],
                                      index,
                                    ),
                                    theme: theme,
                                    time:
                                        _dayTimes[sortedDays[dayIndex]]![index],
                                    enabled: !_busy,
                                    canRemove:
                                        _dayTimes[sortedDays[dayIndex]]!
                                            .length >
                                        1,
                                    onTimeChanged: (time) => _updateExportTime(
                                      sortedDays[dayIndex],
                                      index,
                                      time,
                                    ),
                                    onRemove: () => _removeTime(
                                      sortedDays[dayIndex],
                                      index,
                                    ),
                                  ),
                                  if (index <
                                      _dayTimes[sortedDays[dayIndex]]!.length -
                                          1)
                                    /// Creates a [_VolumeScheduleExportViewState] widget.
                                    const SizedBox(height: 8),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ] else ...[
                        /// Creates a [_VolumeScheduleExportViewState] widget.
                        const SizedBox(height: 16),
                        Text(
                          'Select at least one day to configure export times.',
                          style: CalfTheme.muted(theme),
                        ),
                      ],
                      if (_cronSummary.isNotEmpty) ...[
                        /// Creates a [_VolumeScheduleExportViewState] widget.
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.08,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _cronSummary,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                /// Creates a [_VolumeScheduleExportViewState] widget.
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Location',
                        style: theme.textTheme.titleMedium!.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),

                      /// Creates a [_VolumeScheduleExportViewState] widget.
                      const SizedBox(height: 16),
                      VolumeExportOptionTile(
                        theme: theme,
                        title: 'Local file',
                        description:
                            'Create a compressed file (.tar.gz) in a selected directory.',
                        selected: _type == VolumeQuickExportType.localFile,
                        onSelect: _busy
                            ? null
                            : () => _setExportType(
                                VolumeQuickExportType.localFile,
                              ),
                        child: _type == VolumeQuickExportType.localFile
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  /// Creates a [_VolumeScheduleExportViewState] widget.
                                  const SizedBox(height: 12),
                                  _ExportNamePatternField(
                                    theme: theme,
                                    controller: _fileNameController,
                                    label: 'File name pattern',
                                    placeholder: defaultExportFileNamePattern(),
                                    helperText:
                                        'Use placeholders for unique names, or enter a fixed name if you want to overwrite the same file each run.',
                                    previewLabel: 'Example file name',
                                    preview: _namePatternPreview,
                                    onChanged: () => setState(() {}),
                                    onInsertToken: (token) =>
                                        _insertPatternToken(
                                          _fileNameController,
                                          token,
                                        ),
                                  ),

                                  /// Creates a [_VolumeScheduleExportViewState] widget.
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _folderController,
                                          decoration: const InputDecoration(
                                            hintText: 'Select folder',
                                          ),
                                          onChanged: (_) => setState(() {}),
                                        ),
                                      ),

                                      /// Creates a [_VolumeScheduleExportViewState] widget.
                                      const SizedBox(width: 8),
                                      CalfButton.outline(
                                        onPressed: _busy ? null : _browseFolder,
                                        child: const Text('Browse'),
                                      ),
                                    ],
                                  ),
                                ],
                              )
                            : null,
                      ),

                      /// Creates a [_VolumeScheduleExportViewState] widget.
                      const SizedBox(height: 16),
                      VolumeExportOptionTile(
                        theme: theme,
                        title: 'Local image',
                        description:
                            'Copy the volume content to an existing image.',
                        selected: _type == VolumeQuickExportType.localImage,
                        onSelect: _busy
                            ? null
                            : () => _setExportType(
                                VolumeQuickExportType.localImage,
                              ),
                        child: _type == VolumeQuickExportType.localImage
                            ? Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: VolumeExportImageRefField(
                                  theme: theme,
                                  controller: _imageRefController,
                                  images: _images,
                                  imagesLoading: _imagesLoading,
                                  imagesError: _imagesError,
                                  onChanged: () => setState(() {}),
                                ),
                              )
                            : null,
                      ),

                      /// Creates a [_VolumeScheduleExportViewState] widget.
                      const SizedBox(height: 16),
                      VolumeExportOptionTile(
                        theme: theme,
                        title: 'New image',
                        description:
                            'Create a new image and copy the volume contents into it.',
                        selected: _type == VolumeQuickExportType.newImage,
                        onSelect: _busy
                            ? null
                            : () => _setExportType(
                                VolumeQuickExportType.newImage,
                              ),
                        child: _type == VolumeQuickExportType.newImage
                            ? Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: _ExportNamePatternField(
                                  theme: theme,
                                  controller: _imageRefController,
                                  label: 'Image name pattern',
                                  placeholder: defaultExportImageRefPattern(),
                                  helperText:
                                      'Each run creates a new image. Use {timestamp} for unique tags, or a fixed name to overwrite.',
                                  previewLabel: 'Example image reference',
                                  preview: _namePatternPreview,
                                  onChanged: () => setState(() {}),
                                  onInsertToken: (token) => _insertPatternToken(
                                    _imageRefController,
                                    token,
                                  ),
                                ),
                              )
                            : null,
                      ),

                      /// Creates a [_VolumeScheduleExportViewState] widget.
                      const SizedBox(height: 16),
                      VolumeExportOptionTile(
                        theme: theme,
                        title: 'Registry',
                        description: 'Push the volume content to Docker Hub.',
                        selected: _type == VolumeQuickExportType.registry,
                        onSelect: _busy
                            ? null
                            : () => _setExportType(
                                VolumeQuickExportType.registry,
                              ),
                        child: _type == VolumeQuickExportType.registry
                            ? Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _DockerHubRegistryNotice(theme: theme),

                                    /// Creates a [_VolumeScheduleExportViewState] widget.
                                    const SizedBox(height: 12),
                                    TextField(
                                      controller: _imageRefController,
                                      decoration: const InputDecoration(
                                        hintText: '<user>/<repo-name>:<tag>',
                                      ),
                                      onChanged: (_) => setState(() {}),
                                    ),
                                  ],
                                ),
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          /// Creates a [_VolumeScheduleExportViewState] widget.
          const SizedBox(height: 12),
          Text(
            _error!,
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],

        /// Creates a [_VolumeScheduleExportViewState] widget.
        const SizedBox(height: 16),
        Row(
          children: [
            if (widget.isEditing)
              CalfButton.destructive(
                enabled: !_busy,
                onPressed: _confirmDelete,
                child: const Text('Delete schedule'),
              ),

            /// Creates a [_VolumeScheduleExportViewState] widget.
            const Spacer(),
            CalfButton.outline(
              enabled: !_busy,
              onPressed: widget.onBack,
              child: const Text('Cancel'),
            ),

            /// Creates a [_VolumeScheduleExportViewState] widget.
            const SizedBox(width: 8),
            CalfButton(
              enabled: _canApply,
              onPressed: _applyChanges,
              child: Text(
                _busy
                    ? 'Applying...'
                    : widget.isEditing
                    ? 'Apply changes'
                    : 'Create schedule',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ExportTimeRow extends StatefulWidget {
  /// Creates a [_ExportTimeRow] widget.
  const _ExportTimeRow({
    super.key,
    required this.theme,
    required this.time,
    required this.enabled,
    required this.canRemove,
    required this.onTimeChanged,
    required this.onRemove,
  });

  final ThemeData theme;
  final TimeOfDay time;
  final bool enabled;
  final bool canRemove;
  final ValueChanged<TimeOfDay> onTimeChanged;
  final VoidCallback onRemove;

  /// Creates the mutable state for [_ExportTimeRow].
  @override
  State<_ExportTimeRow> createState() => _ExportTimeRowState();
}

class _ExportTimeRowState extends State<_ExportTimeRow> {
  static final _hourOptions = List.generate(
    24,
    (hour) => hour.toString().padLeft(2, '0'),
  );
  static final _minuteOptions = List.generate(
    60,
    (minute) => minute.toString().padLeft(2, '0'),
  );

  late int _hour;
  late int _minute;

  /// Returns the `currentTime` value.
  TimeOfDay get currentTime => TimeOfDay(hour: _hour, minute: _minute);

  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    _hour = widget.time.hour;
    _minute = widget.time.minute;
  }

  /// Refreshes local state when the parent widget changes.
  @override
  void didUpdateWidget(covariant _ExportTimeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.time != widget.time) {
      _hour = widget.time.hour;
      _minute = widget.time.minute;
    }
  }

  /// Formats an hour as a two-digit string.
  static String _formatHour(int hour) => hour.toString().padLeft(2, '0');

  /// Formats a minute as a two-digit string.
  static String _formatMinute(int minute) => minute.toString().padLeft(2, '0');

  /// Updates the corresponding form field in state.
  void _updateHour(String? value) {
    if (value == null || !widget.enabled) {
      return;
    }

    setState(() => _hour = int.parse(value));
    widget.onTimeChanged(currentTime);
  }

  /// Updates the corresponding form field in state.
  void _updateMinute(String? value) {
    if (value == null || !widget.enabled) {
      return;
    }

    setState(() => _minute = int.parse(value));
    widget.onTimeChanged(currentTime);
  }

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: widget.theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: DropdownButton<String>(
              value: _formatHour(_hour),
              isExpanded: true,
              hint: const Text('HH'),
              items: _hourOptions
                  .map(
                    (value) => DropdownMenuItem<String>(
                      value: value,
                      child: Text(value),
                    ),
                  )
                  .toList(),
              onChanged: widget.enabled ? _updateHour : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              ':',
              style: widget.theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            width: 76,
            child: DropdownButton<String>(
              value: _formatMinute(_minute),
              isExpanded: true,
              hint: const Text('MM'),
              items: _minuteOptions
                  .map(
                    (value) => DropdownMenuItem<String>(
                      value: value,
                      child: Text(value),
                    ),
                  )
                  .toList(),
              onChanged: widget.enabled ? _updateMinute : null,
            ),
          ),
          if (widget.canRemove) ...[
            /// Creates a [_ExportTimeRowState] widget.
            const SizedBox(width: 8),
            CalfButton.ghost(
              enabled: widget.enabled,
              onPressed: widget.onRemove,
              child: Icon(
                LucideIcons.trash2,
                size: 16,
                color: widget.theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DockerHubRegistryNotice extends StatelessWidget {
  /// Creates a [_DockerHubRegistryNotice] widget.
  const _DockerHubRegistryNotice({required this.theme});

  final ThemeData theme;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.info, size: 16, color: theme.colorScheme.primary),

          /// Creates a [_DockerHubRegistryNotice] widget.
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'This might make any data in the volume publicly accessible on Docker Hub.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportNamePatternField extends StatelessWidget {
  /// Creates a [_ExportNamePatternField] widget.
  const _ExportNamePatternField({
    required this.theme,
    required this.controller,
    required this.label,
    required this.placeholder,
    required this.helperText,
    required this.previewLabel,
    required this.preview,
    required this.onChanged,
    required this.onInsertToken,
  });

  final ThemeData theme;
  final TextEditingController controller;
  final String label;
  final String placeholder;
  final String helperText;
  final String previewLabel;
  final String preview;
  final VoidCallback onChanged;
  final ValueChanged<String> onInsertToken;

  static const _tokens = ['{volume}', '{timestamp}', '{date}', '{time}'];

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final pattern = controller.text.trim();
    final isStaticName =
        pattern.isNotEmpty && !exportNamePatternHasUniqueToken(pattern);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall!.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),

        /// Creates a [_ExportNamePatternField] widget.
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          decoration: InputDecoration(hintText: placeholder),
          onChanged: (_) => onChanged(),
        ),

        /// Creates a [_ExportNamePatternField] widget.
        const SizedBox(height: 8),
        Text(helperText, style: CalfTheme.muted(theme)),

        /// Creates a [_ExportNamePatternField] widget.
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final token in _tokens)
              _PatternTokenChip(
                theme: theme,
                label: token,
                onTap: () => onInsertToken(token),
              ),
          ],
        ),
        if (pattern.isNotEmpty) ...[
          /// Creates a [_ExportNamePatternField] widget.
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  previewLabel,
                  style: theme.textTheme.bodySmall!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),

                /// Creates a [_ExportNamePatternField] widget.
                const SizedBox(height: 4),
                Text(preview, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
        if (isStaticName) ...[
          /// Creates a [_ExportNamePatternField] widget.
          const SizedBox(height: 8),
          Text(
            'Static name: each scheduled run will overwrite the previous export at this destination.',
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

class _PatternTokenChip extends StatefulWidget {
  /// Creates a [_PatternTokenChip] widget.
  const _PatternTokenChip({
    required this.theme,
    required this.label,
    required this.onTap,
  });

  final ThemeData theme;
  final String label;
  final VoidCallback onTap;

  /// Creates the mutable state for [_PatternTokenChip].
  @override
  State<_PatternTokenChip> createState() => _PatternTokenChipState();
}

class _PatternTokenChipState extends State<_PatternTokenChip> {
  bool _hovered = false;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final borderColor = _hovered
        ? widget.theme.colorScheme.primary
        : widget.theme.colorScheme.outlineVariant;
    final backgroundColor = _hovered
        ? widget.theme.colorScheme.primary.withValues(alpha: 0.12)
        : null;
    final textColor = _hovered
        ? widget.theme.colorScheme.primary
        : widget.theme.colorScheme.onSurface;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: backgroundColor,
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            widget.label,
            style: widget.theme.textTheme.bodySmall!.copyWith(color: textColor),
          ),
        ),
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  /// Creates a [_DayChip] widget.
  const _DayChip({
    required this.theme,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final ThemeData theme;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : null,
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: theme.textTheme.bodySmall!.copyWith(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
