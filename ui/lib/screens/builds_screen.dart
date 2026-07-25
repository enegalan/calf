import 'dart:async';

import 'package:flutter/material.dart';

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/screens/build_detail_screen.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/poll_interval_mixin.dart';
import 'package:ui/widgets/resource_list_scaffold.dart';
import 'package:ui/widgets/status_dot.dart';
import 'package:ui/theme/calf_theme.dart';

class BuildsScreen extends StatefulWidget {
  /// Creates a [BuildsScreen] widget.
  const BuildsScreen({
    super.key,
    required this.apiClient,
    this.initialBuildId,
    this.onInitialBuildConsumed,
  });

  final CalfClient apiClient;
  final String? initialBuildId;
  final VoidCallback? onInitialBuildConsumed;

  /// Creates the mutable state for [BuildsScreen].
  @override
  State<BuildsScreen> createState() => _BuildsScreenState();
}

class _BuildsScreenState extends State<BuildsScreen> with PollIntervalMixin {
  List<BuildItem> _builds = [];
  RuntimeStatus? _runtime;
  String? _error;
  bool _loading = true;
  bool _refreshInFlight = false;
  int _consecutiveSilentFailures = 0;
  String? _selectedBuildId;
  final _searchController = TextEditingController();
  String _searchQuery = '';

  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    _loadBuilds();
    startPollInterval(widget.apiClient, _loadBuilds);
    _searchController.addListener(() {
      setState(
        () => _searchQuery = _searchController.text.trim().toLowerCase(),
      );
    });
  }

  /// Re-arms the pending deep link when [initialBuildId] changes.
  @override
  void didUpdateWidget(covariant BuildsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialBuildId != oldWidget.initialBuildId &&
        widget.initialBuildId != null) {
      _openInitialBuildIfNeeded(_builds);
    }
  }

  /// Releases controllers, timers, and stream subscriptions.
  @override
  void dispose() {
    disposePollInterval();
    _searchController.dispose();
    super.dispose();
  }

  /// Fetches builds from the API, optionally skipping the loading indicator.
  Future<void> _loadBuilds({bool silent = false}) async {
    if (_refreshInFlight) {
      return;
    }

    _refreshInFlight = true;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final status = await widget.apiClient.fetchStatus();
      final builds = await widget.apiClient.fetchBuilds();
      if (!mounted) {
        return;
      }
      _consecutiveSilentFailures = 0;
      setState(() {
        _runtime = status.runtime;
        _builds = builds;
        _loading = false;
        _error = null;
      });
      _openInitialBuildIfNeeded(builds);
    } catch (error) {
      if (!mounted) {
        return;
      }
      if (!silent) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      } else {
        _consecutiveSilentFailures++;
        if (_consecutiveSilentFailures >= 3) {
          setState(() => _error = error.toString());
        }
      }
    } finally {
      _refreshInFlight = false;
    }
  }

  /// Navigates to or opens the selected build.
  void _openBuild(BuildItem build) {
    setState(() => _selectedBuildId = build.id);
  }

  /// Opens [initialBuildId] once builds are loaded, if provided.
  void _openInitialBuildIfNeeded(List<BuildItem> builds) {
    final id = widget.initialBuildId?.trim() ?? '';
    if (id.isEmpty) {
      return;
    }
    for (final build in builds) {
      if (build.id == id || build.id.startsWith(id)) {
        widget.onInitialBuildConsumed?.call();
        _openBuild(build);
        return;
      }
    }
  }

  /// Closes the current detail view and returns to the list.
  void _closeBuild() {
    setState(() => _selectedBuildId = null);
  }

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    if (_selectedBuildId != null) {
      return BuildDetailView(
        key: ValueKey(_selectedBuildId),
        buildId: _selectedBuildId!,
        apiClient: widget.apiClient,
        onBack: _closeBuild,
        onOpenBuild: (id) => setState(() => _selectedBuildId = id),
      );
    }

    final theme = Theme.of(context);
    final filtered = _searchQuery.isEmpty
        ? _builds
        : _builds
              .where(
                (b) =>
                    b.tag.toLowerCase().contains(_searchQuery) ||
                    b.id.toLowerCase().contains(_searchQuery) ||
                    b.status.toLowerCase().contains(_searchQuery),
              )
              .toList();
    final runtimeStopped = _runtime?.state == 'stopped';

    return ResourceListScaffold(
      title: 'Builds',
      searchController: _searchController,
      loading: _loading,
      error: _error,
      empty: filtered.isEmpty,
      emptyMessage: _searchQuery.isNotEmpty
          ? 'No builds match "$_searchQuery".'
          : runtimeStopped
          ? 'No builds yet. Runtime is stopped.'
          : 'No builds yet.',
      emptyAction: filtered.isEmpty && runtimeStopped && _searchQuery.isEmpty
          ? CalfButton(
              onPressed: _startEngine,
              child: const Text('Start engine'),
            )
          : null,
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final build = filtered[index];

        return HoverListRow(
          theme: theme,
          onTap: () => _openBuild(build),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              StatusDot(
                active: true,
                hollow: false,
                activeColor: _buildStatusColor(build.status, theme),
                tooltip: build.status,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(build.tag, style: theme.textTheme.titleMedium),
                    Text(
                      build.context.isNotEmpty
                          ? '${build.context} · ${build.status}'
                          : build.status,
                      style: CalfTheme.muted(theme),
                    ),
                    Text(
                      [
                        if (build.durationMs > 0)
                          _formatBuildDuration(build.durationMs),
                        build.createdAt,
                      ].where((item) => item.isNotEmpty).join(' · '),
                      style: CalfTheme.muted(theme),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Starts the container engine when the list is empty and runtime is stopped.
  Future<void> _startEngine() async {
    try {
      await widget.apiClient.startRuntime();
      if (!mounted) {
        return;
      }
      await _loadBuilds();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }
}

/// Returns the list-dot color for a build status.
Color _buildStatusColor(String status, ThemeData theme) {
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
String _formatBuildDuration(int durationMs) {
  if (durationMs <= 0) {
    return '';
  }

  final seconds = durationMs / 1000;
  if (seconds < 60) {
    return '${seconds.toStringAsFixed(1)}s';
  }

  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  return '${minutes}m ${remainder.toStringAsFixed(0)}s';
}
