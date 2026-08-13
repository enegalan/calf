import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/theme/calf_theme.dart';
import 'package:ui/widgets/build_row_icons.dart';

/// Kind of resource a global-search hit navigates to.
enum GlobalSearchKind { container, image, volume, network, build }

/// One selectable hit in the global search palette.
class GlobalSearchHit {
  /// Creates a [GlobalSearchHit] instance.
  const GlobalSearchHit({
    required this.kind,
    required this.id,
    required this.title,
    required this.subtitle,
  });

  final GlobalSearchKind kind;
  final String id;
  final String title;
  final String subtitle;
}

/// Opens the global resource search dialog and returns the selected hit, if any.
Future<GlobalSearchHit?> showGlobalSearchDialog(
  BuildContext context, {
  required CalfClient apiClient,
}) {
  return showDialog<GlobalSearchHit>(
    context: context,
    builder: (dialogContext) {
      return GlobalSearchDialog(apiClient: apiClient);
    },
  );
}

/// Command-palette dialog to find containers, images, volumes, networks, builds.
class GlobalSearchDialog extends StatefulWidget {
  /// Creates a [GlobalSearchDialog] instance.
  const GlobalSearchDialog({super.key, required this.apiClient});

  final CalfClient apiClient;

  @override
  State<GlobalSearchDialog> createState() => _GlobalSearchDialogState();
}

class _GlobalSearchDialogState extends State<GlobalSearchDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  final _selectedItemKey = GlobalKey();
  List<GlobalSearchHit> _all = [];
  List<GlobalSearchHit> _filtered = [];
  int _selectedIndex = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
    unawaited(_loadResources());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Loads all resource lists for local filtering.
  Future<void> _loadResources() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.apiClient.fetchContainers(),
        widget.apiClient.fetchImages(),
        widget.apiClient.fetchVolumes(),
        widget.apiClient.fetchNetworks(),
        widget.apiClient.fetchBuilds(),
      ]);
      if (!mounted) {
        return;
      }
      final containers = results[0] as List<ContainerItem>;
      final images = results[1] as List<ImageItem>;
      final volumes = results[2] as List<VolumeItem>;
      final networks = results[3] as List<NetworkItem>;
      final builds = results[4] as List<BuildItem>;

      final hits = <GlobalSearchHit>[
        for (final container in containers)
          GlobalSearchHit(
            kind: GlobalSearchKind.container,
            id: container.id,
            title: container.displayName.isNotEmpty
                ? container.displayName
                : container.name,
            subtitle: [
              if (container.composeProject.isNotEmpty) container.composeProject,
              container.image,
              container.status,
            ].where((part) => part.isNotEmpty).join(' · '),
          ),
        for (final image in images)
          GlobalSearchHit(
            kind: GlobalSearchKind.image,
            id: image.reference,
            title: image.reference,
            subtitle: image.id,
          ),
        for (final volume in volumes)
          GlobalSearchHit(
            kind: GlobalSearchKind.volume,
            id: volume.name,
            title: volume.name,
            subtitle: volume.driver,
          ),
        for (final network in networks)
          GlobalSearchHit(
            kind: GlobalSearchKind.network,
            id: network.name,
            title: network.name,
            subtitle: [
              network.driver,
              if (network.subnet.isNotEmpty) network.subnet,
            ].where((part) => part.isNotEmpty).join(' · '),
          ),
        for (final build in builds)
          GlobalSearchHit(
            kind: GlobalSearchKind.build,
            id: build.id,
            title: build.tag.isNotEmpty ? build.tag : build.id,
            subtitle: [
              build.status,
              build.id,
            ].where((part) => part.isNotEmpty).join(' · '),
          ),
      ];

      setState(() {
        _all = hits;
        _loading = false;
        _applyFilter(_controller.text);
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } on TimeoutException {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = 'Request timed out';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  /// Re-filters when the query text changes.
  void _onQueryChanged() {
    _applyFilter(_controller.text);
  }

  /// Filters [_all] by substring across title, subtitle, and id.
  void _applyFilter(String rawQuery) {
    final query = rawQuery.trim().toLowerCase();
    final filtered = query.isEmpty
        ? List<GlobalSearchHit>.from(_all)
        : _all.where((hit) {
            return hit.title.toLowerCase().contains(query) ||
                hit.subtitle.toLowerCase().contains(query) ||
                hit.id.toLowerCase().contains(query) ||
                _kindLabel(hit.kind).toLowerCase().contains(query);
          }).toList();
    setState(() {
      _filtered = filtered;
      _selectedIndex = filtered.isEmpty
          ? 0
          : _selectedIndex.clamp(0, filtered.length - 1);
    });
  }

  /// Confirms the currently highlighted hit.
  void _confirmSelection() {
    if (_filtered.isEmpty) {
      return;
    }
    final index = _selectedIndex.clamp(0, _filtered.length - 1);
    Navigator.of(context).pop(_filtered[index]);
  }

  /// Moves the highlight up or down within the filtered list.
  void _moveSelection(int delta) {
    if (_filtered.isEmpty) {
      return;
    }
    setState(() {
      _selectedIndex = (_selectedIndex + delta).clamp(0, _filtered.length - 1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureSelectedVisible();
    });
  }

  /// Scrolls the result list so the highlighted hit stays in view.
  void _ensureSelectedVisible() {
    final selectedContext = _selectedItemKey.currentContext;
    if (selectedContext == null) {
      return;
    }
    Scrollable.ensureVisible(
      selectedContext,
      alignment: 0.35,
      alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
    );
  }

  /// Builds the search palette dialog.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _moveSelection(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _moveSelection(-1),
        const SingleActivator(LogicalKeyboardKey.enter): _confirmSelection,
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: AlertDialog(
        shape: CalfTheme.dialogShape(theme.colorScheme),
        titlePadding: EdgeInsets.zero,
        contentPadding: EdgeInsets.zero,
        content: SizedBox(
          width: 520,
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  decoration: InputDecoration(
                    hintText: 'Search containers, images, volumes…',
                    prefixIcon: Icon(
                      LucideIcons.search,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _confirmSelection(),
                ),
              ),
              Divider(height: 1, color: theme.colorScheme.outlineVariant),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _error!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : _filtered.isEmpty
                    ? Center(
                        child: Text(
                          'No matches',
                          style: CalfTheme.muted(theme),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        itemCount: _filtered.length,
                        itemBuilder: (context, index) {
                          final hit = _filtered[index];
                          final selected = index == _selectedIndex;
                          return KeyedSubtree(
                            key: selected
                                ? _selectedItemKey
                                : ValueKey<String>('${hit.kind}-${hit.id}'),
                            child: InkWell(
                              onTap: () => Navigator.of(context).pop(hit),
                              onHover: (hovering) {
                                if (hovering) {
                                  setState(() => _selectedIndex = index);
                                }
                              },
                              child: ColoredBox(
                                color: selected
                                    ? theme.colorScheme.primary.withValues(
                                        alpha: 0.08,
                                      )
                                    : Colors.transparent,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      _kindIcon(theme, hit.kind),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              hit.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodyMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                            if (hit.subtitle.isNotEmpty)
                                              Text(
                                                '${_kindLabel(hit.kind)} · ${hit.subtitle}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: CalfTheme.muted(theme),
                                              )
                                            else
                                              Text(
                                                _kindLabel(hit.kind),
                                                style: CalfTheme.muted(theme),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Divider(height: 1, color: theme.colorScheme.outlineVariant),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  '↑↓ navigate · Enter open · Esc close',
                  style: CalfTheme.muted(theme).copyWith(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Returns a short label for [kind].
  String _kindLabel(GlobalSearchKind kind) {
    return switch (kind) {
      GlobalSearchKind.container => 'Container',
      GlobalSearchKind.image => 'Image',
      GlobalSearchKind.volume => 'Volume',
      GlobalSearchKind.network => 'Network',
      GlobalSearchKind.build => 'Build',
    };
  }

  /// Leading icon matching the sidebar for [kind].
  Widget _kindIcon(ThemeData theme, GlobalSearchKind kind) {
    final color = theme.colorScheme.onSurfaceVariant;
    return switch (kind) {
      GlobalSearchKind.container => Icon(
        LucideIcons.box,
        size: 16,
        color: color,
      ),
      GlobalSearchKind.image => SvgPicture.asset(
        buildPlaceholderIconAsset,
        width: 16,
        height: 16,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      ),
      GlobalSearchKind.volume => Icon(
        LucideIcons.hardDrive,
        size: 16,
        color: color,
      ),
      GlobalSearchKind.network => Icon(
        LucideIcons.network,
        size: 16,
        color: color,
      ),
      GlobalSearchKind.build => Icon(
        LucideIcons.wrench,
        size: 16,
        color: color,
      ),
    };
  }
}
