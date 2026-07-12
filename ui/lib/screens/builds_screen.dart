import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/screens/build_detail_screen.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/poll_interval_mixin.dart';

class BuildsScreen extends StatefulWidget {
  /// Creates a [BuildsScreen] widget.
  const BuildsScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

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
      setState(() {
        _runtime = status.runtime;
        _builds = builds;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      if (!silent) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    } finally {
      _refreshInFlight = false;
    }
  }

  /// Navigates to or opens the selected build.
  void _openBuild(BuildItem build) {
    setState(() => _selectedBuildId = build.id);
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

    final theme = ShadTheme.of(context);
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Builds', style: theme.textTheme.h3),

        /// Creates a [_BuildsScreenState] widget.
        const SizedBox(height: 16),
        ShadInput(
          controller: _searchController,
          placeholder: const Text('Search'),
        ),

        /// Creates a [_BuildsScreenState] widget.
        const SizedBox(height: 24),
        if (_loading)
          Text('Loading...', style: theme.textTheme.large)
        else if (_error != null)
          Text(
            _error!,
            style: theme.textTheme.large.copyWith(
              color: theme.colorScheme.destructive,
            ),
          )
        else if (filtered.isEmpty)
          Text(
            _searchQuery.isNotEmpty
                ? 'No builds match "$_searchQuery".'
                : _runtime?.state == 'stopped'
                ? 'No builds yet. Runtime is stopped.'
                : 'No builds yet.',
            style: theme.textTheme.muted,
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final build = filtered[index];

                return HoverListRow(
                  theme: theme,
                  onTap: () => _openBuild(build),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _buildStatusColor(build.status, theme),
                          shape: BoxShape.circle,
                        ),
                      ),

                      /// Creates a [_BuildsScreenState] widget.
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(build.tag, style: theme.textTheme.large),
                            Text(
                              build.context.isNotEmpty
                                  ? '${build.context} · ${build.status}'
                                  : build.status,
                              style: theme.textTheme.muted,
                            ),
                            Text(
                              [
                                if (build.durationMs > 0)
                                  _formatBuildDuration(build.durationMs),
                                build.createdAt,
                              ].where((item) => item.isNotEmpty).join(' · '),
                              style: theme.textTheme.muted,
                            ),
                          ],
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

/// Returns the list-dot color for a build status.
Color _buildStatusColor(String status, ShadThemeData theme) {
  switch (status) {
    case 'success':
      return CalfColors.success;
    case 'failed':
      return theme.colorScheme.destructive;
    case 'running':
      return theme.colorScheme.primary;
    default:
      return theme.colorScheme.mutedForeground;
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
