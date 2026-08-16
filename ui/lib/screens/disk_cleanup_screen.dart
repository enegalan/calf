import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/utils/format.dart';
import 'package:ui/theme/calf_theme.dart';
import 'package:ui/widgets/build_row_icons.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/calf_snack_bar.dart';
import 'package:ui/widgets/confirm_dialog.dart';
import 'package:ui/widgets/detail_breadcrumb.dart';
import 'package:ui/widgets/error_text.dart';

/// Screen to preview and remove unused engine data (system prune).
class DiskCleanupScreen extends StatefulWidget {
  /// Creates a [DiskCleanupScreen] instance.
  const DiskCleanupScreen({
    super.key,
    required this.apiClient,
    required this.onClose,
  });

  final CalfClient apiClient;
  final VoidCallback onClose;

  @override
  State<DiskCleanupScreen> createState() => _DiskCleanupScreenState();
}

class _DiskCleanupScreenState extends State<DiskCleanupScreen> {
  PrunePreview? _preview;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  bool _runtimeStopped = false;
  bool _runtimeStarting = false;

  bool _containers = true;
  bool _images = true;
  bool _volumes = true;
  bool _networks = true;
  bool _buildCache = true;

  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreview());
  }

  /// Loads the prune preview, or marks the runtime as starting/stopped on 503.
  Future<void> _loadPreview() async {
    setState(() {
      _loading = true;
      _error = null;
      _runtimeStopped = false;
      _runtimeStarting = false;
    });
    try {
      final preview = await widget.apiClient.fetchPrunePreview();
      if (!mounted) {
        return;
      }
      setState(() {
        _preview = preview;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      var runtimeStopped = error.statusCode == 503;
      var runtimeStarting = false;
      if (runtimeStopped) {
        try {
          final status = await widget.apiClient.fetchStatus();
          if (!mounted) {
            return;
          }
          runtimeStarting = status.runtime.isStarting;
          runtimeStopped = status.runtime.isStopped;
        } on ApiException {
          runtimeStopped = true;
        } on TimeoutException {
          runtimeStopped = true;
        } on FormatException {
          runtimeStopped = true;
        }
      }
      setState(() {
        _loading = false;
        _runtimeStopped = runtimeStopped;
        _runtimeStarting = runtimeStarting;
        _error = error.message;
        _preview = null;
      });
    } on TimeoutException {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = 'Request timed out';
        _preview = null;
      });
    }
  }

  /// Starts the container engine then reloads the preview.
  Future<void> _startEngine() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.apiClient.startRuntime();
      if (!mounted) {
        return;
      }
      await _loadPreview();
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.message);
      showCalfSnackBar(context, error.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// Estimated reclaimable bytes for currently selected categories.
  int get _selectedBytes {
    final preview = _preview;
    if (preview == null) {
      return 0;
    }
    var total = 0;
    if (_containers) {
      total += preview.containers.reclaimableBytes;
    }
    if (_images) {
      total += preview.images.reclaimableBytes;
    }
    if (_volumes) {
      total += preview.volumes.reclaimableBytes;
    }
    if (_networks) {
      total += preview.networks.reclaimableBytes;
    }
    if (_buildCache) {
      total += preview.buildCache.reclaimableBytes;
    }
    return total;
  }

  /// Whether at least one category with items is selected.
  bool get _canPrune {
    final preview = _preview;
    if (preview == null || _busy) {
      return false;
    }
    return (_containers && preview.containers.items.isNotEmpty) ||
        (_images && preview.images.items.isNotEmpty) ||
        (_volumes && preview.volumes.items.isNotEmpty) ||
        (_networks && preview.networks.items.isNotEmpty) ||
        (_buildCache && preview.buildCache.items.isNotEmpty);
  }

  /// Confirms and runs prune for selected categories.
  Future<void> _runPrune() async {
    if (!_canPrune) {
      return;
    }
    final confirmed = await confirmDialog(
      context,
      title: 'Remove unused data',
      description:
          'Free about ${_formatSelectedBytes()} by removing the selected unused '
          'containers, images, volumes, networks, and build cache. '
          'This cannot be undone.',
      confirmLabel: 'Remove unused data',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }

    setState(() => _busy = true);
    try {
      final result = await widget.apiClient.prune(
        containers: _containers,
        images: _images,
        volumes: _volumes,
        networks: _networks,
        buildCache: _buildCache,
      );
      if (!mounted) {
        return;
      }
      showCalfSnackBar(
        context,
        result.reclaimedSize == '0 B'
            ? 'Unused data removed'
            : 'Reclaimed ${result.reclaimedSize}',
      );
      await _loadPreview();
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      showCalfSnackBar(context, error.message);
    } on TimeoutException {
      if (!mounted) {
        return;
      }
      showCalfSnackBar(context, 'Action timed out');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// Builds the clean unused data layout.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _preview;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailBreadcrumb(
          segments: const ['Troubleshoot', 'Clean unused data'],
          onBack: _busy ? null : widget.onClose,
          trailing: CalfButton.ghost(
            height: 32,
            onPressed: _busy || _loading
                ? null
                : () => unawaited(_loadPreview()),
            child: const Icon(LucideIcons.refreshCw, size: 16),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Remove unused containers, images, volumes, networks, and build cache '
          'without wiping the guest disk.',
          style: CalfTheme.muted(theme),
        ),
        const SizedBox(height: 16),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_runtimeStarting || _runtimeStopped)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _runtimeStarting || _busy
                        ? 'Engine is starting…'
                        : 'Runtime is stopped.',
                    style: CalfTheme.muted(theme),
                  ),
                  if (!_runtimeStarting) ...[
                    const SizedBox(height: 12),
                    CalfButton(
                      onPressed: _busy ? null : () => unawaited(_startEngine()),
                      child: const Text('Start engine'),
                    ),
                  ],
                ],
              ),
            ),
          )
        else if (_error != null)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ErrorText(error: _error!),
                  const SizedBox(height: 12),
                  CalfButton.outline(
                    onPressed: _busy ? null : () => unawaited(_loadPreview()),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          )
        else if (preview != null) ...[
          _selectedSpaceSummary(theme, preview),
          if (preview.diskUsage.rows.isNotEmpty) ...[
            const SizedBox(height: 8),
            _diskUsageTable(theme, preview.diskUsage),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              children: [
                _categorySection(
                  keyName: 'containers',
                  title: 'Stopped containers',
                  icon: LucideIcons.box,
                  category: preview.containers,
                  selected: _containers,
                  onChanged: (value) => setState(() => _containers = value),
                ),
                _categorySection(
                  keyName: 'images',
                  title: 'Unused images',
                  svgAsset: buildPlaceholderIconAsset,
                  category: preview.images,
                  selected: _images,
                  onChanged: (value) => setState(() => _images = value),
                ),
                _categorySection(
                  keyName: 'volumes',
                  title: 'Unused volumes',
                  icon: LucideIcons.hardDrive,
                  category: preview.volumes,
                  selected: _volumes,
                  onChanged: (value) => setState(() => _volumes = value),
                ),
                _categorySection(
                  keyName: 'networks',
                  title: 'Unused networks',
                  icon: LucideIcons.network,
                  category: preview.networks,
                  selected: _networks,
                  onChanged: (value) => setState(() => _networks = value),
                ),
                _categorySection(
                  keyName: 'build_cache',
                  title: 'Build cache',
                  icon: LucideIcons.wrench,
                  category: preview.buildCache,
                  selected: _buildCache,
                  onChanged: (value) => setState(() => _buildCache = value),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: CalfButton.destructive(
              onPressed: _canPrune ? () => unawaited(_runPrune()) : null,
              child: Text(_busy ? 'Removing…' : 'Remove unused data'),
            ),
          ),
        ],
      ],
    );
  }

  /// Compact system-df style Size / Reclaimable table for engine disk usage.
  Widget _diskUsageTable(ThemeData theme, SystemDiskUsage usage) {
    final headerStyle = CalfTheme.muted(
      theme,
    ).copyWith(fontWeight: FontWeight.w600, fontSize: 12);
    final cellStyle = theme.textTheme.bodySmall;

    Widget cell(String text, {int flex = 1, TextAlign align = TextAlign.left}) {
      return Expanded(
        flex: flex,
        child: Text(
          text,
          style: cellStyle,
          textAlign: align,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(flex: 2, child: Text('Type', style: headerStyle)),
            Expanded(
              child: Text(
                'Size',
                style: headerStyle,
                textAlign: TextAlign.right,
              ),
            ),
            Expanded(
              child: Text(
                'Reclaimable',
                style: headerStyle,
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final row in usage.rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                cell(row.type, flex: 2),
                cell(row.size, align: TextAlign.right),
                cell(row.reclaimable, align: TextAlign.right),
              ],
            ),
          ),
      ],
    );
  }

  /// Live summary of space that will be freed for the current checkbox selection.
  Widget _selectedSpaceSummary(ThemeData theme, PrunePreview preview) {
    final selectedLabel = formatFileSize(_selectedBytes);
    final hasSelection = _canPrune;
    final sizeLabel = hasSelection ? selectedLabel : '0 B';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            LucideIcons.hardDrive,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text('Space to free', style: CalfTheme.muted(theme)),
          const SizedBox(width: 8),
          AnimatedSwitcher(
            duration: CalfTheme.animationDuration,
            switchInCurve: CalfTheme.animationCurve,
            switchOutCurve: CalfTheme.animationCurve,
            child: Text(
              sizeLabel,
              key: ValueKey<String>(sizeLabel),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: hasSelection
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Spacer(),
          Text(
            'of ${preview.totalReclaimableSize}',
            style: CalfTheme.muted(theme),
          ),
        ],
      ),
    );
  }

  /// Formats selected reclaimable bytes for the current checkbox selection.
  String _formatSelectedBytes() => formatFileSize(_selectedBytes);

  /// Builds one selectable prune category with an expandable item list.
  Widget _categorySection({
    required String keyName,
    required String title,
    required PruneCategoryPreview category,
    required bool selected,
    required ValueChanged<bool> onChanged,
    IconData? icon,
    String? svgAsset,
  }) {
    final theme = Theme.of(context);
    final expanded = _expanded.contains(keyName);
    final count = category.items.length;
    final sizeLabel = category.reclaimableSize;
    final iconColor = theme.colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Checkbox(
              value: selected,
              onChanged: count == 0
                  ? null
                  : (value) => onChanged(value ?? false),
            ),
            Expanded(
              child: InkWell(
                onTap: count == 0
                    ? null
                    : () => setState(() {
                        if (expanded) {
                          _expanded.remove(keyName);
                        } else {
                          _expanded.add(keyName);
                        }
                      }),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      _categoryIcon(
                        icon: icon,
                        svgAsset: svgAsset,
                        color: iconColor,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(title, style: theme.textTheme.titleSmall),
                      ),
                      Text(
                        count == 0 ? 'None' : '$count · $sizeLabel',
                        style: CalfTheme.muted(theme),
                      ),
                      if (count > 0) ...[
                        const SizedBox(width: 8),
                        Icon(
                          expanded
                              ? LucideIcons.chevronUp
                              : LucideIcons.chevronDown,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        if (expanded && count > 0)
          Padding(
            padding: const EdgeInsets.only(left: 48, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in category.items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        _categoryIcon(
                          icon: icon,
                          svgAsset: svgAsset,
                          color: iconColor,
                          size: 14,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item.name,
                            style: theme.textTheme.bodyMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (item.size.isNotEmpty)
                          Text(item.size, style: CalfTheme.muted(theme)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        Divider(color: theme.colorScheme.outlineVariant),
      ],
    );
  }

  /// Leading icon for a prune category (Lucide or SVG, matching the sidebar).
  Widget _categoryIcon({
    IconData? icon,
    String? svgAsset,
    required Color color,
    required double size,
  }) {
    if (svgAsset != null) {
      return SvgPicture.asset(
        svgAsset,
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      );
    }
    return Icon(icon ?? LucideIcons.box, size: size, color: color);
  }
}
