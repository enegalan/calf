import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/confirm_dialog.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/poll_interval_mixin.dart';
import 'package:ui/widgets/resource_list_scaffold.dart';
import 'package:ui/theme/calf_theme.dart';

class ImagesScreen extends StatefulWidget {
  /// Creates a [ImagesScreen] widget.
  const ImagesScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

  /// Creates the mutable state for [ImagesScreen].
  @override
  State<ImagesScreen> createState() => _ImagesScreenState();
}

class _ImagesScreenState extends State<ImagesScreen> with PollIntervalMixin {
  List<ImageItem> _images = [];
  RuntimeStatus? _runtime;
  String? _error;
  bool _loading = true;
  bool _refreshInFlight = false;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  ImageItem? _selectedImage;
  List<ImageLayer>? _layers;
  bool _layersLoading = false;
  String? _layersError;

  /// Initializes state and starts loading or subscriptions.
  @override
  void initState() {
    super.initState();
    _loadImages();
    startPollInterval(widget.apiClient, _loadImages);
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

  /// Fetches images from the API, optionally skipping the loading indicator.
  Future<void> _loadImages({bool silent = false}) async {
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
      final images = await widget.apiClient.fetchImages();
      if (!mounted) {
        return;
      }
      setState(() {
        _runtime = status.runtime;
        _images = images;
        _loading = false;
        _syncSelectedImage(images);
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

  /// Updates [_selectedImage] from a fresh poll when detail view is open.
  void _syncSelectedImage(List<ImageItem> images) {
    final selected = _selectedImage;
    if (selected == null) {
      return;
    }

    for (final image in images) {
      if (image.id == selected.id) {
        _selectedImage = image;
        return;
      }
    }

    _selectedImage = null;
    _layers = null;
    _layersError = null;
    _layersLoading = false;
  }

  /// Navigates to or opens the selected image.
  Future<void> _openImage(ImageItem image) async {
    setState(() {
      _selectedImage = image;
      _layers = null;
      _layersLoading = true;
      _layersError = null;
    });

    try {
      final layers = await widget.apiClient.fetchImageLayers(image.reference);
      if (!mounted || _selectedImage?.id != image.id) {
        return;
      }
      setState(() {
        _layers = layers;
        _layersLoading = false;
      });
    } catch (error) {
      if (!mounted || _selectedImage?.id != image.id) {
        return;
      }
      setState(() {
        _layersError = error.toString();
        _layersLoading = false;
      });
    }
  }

  /// Closes the current detail view and returns to the list.
  void _closeImage() {
    setState(() {
      _selectedImage = null;
      _layers = null;
      _layersError = null;
      _layersLoading = false;
    });
  }

  /// Removes the selected resource via the API after confirmation.
  Future<void> _removeImage(ImageItem image) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Remove image',
      description:
          'Remove "${image.reference}"? This cannot be undone.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    await widget.apiClient.removeImage(image.reference);
    if (_selectedImage?.id == image.id) {
      _closeImage();
    }
    await _loadImages();
  }

  /// Runs the given async action and refreshes the list on success.
  Future<void> _runImage(ImageItem image) async {
    await widget.apiClient.runImage(image.reference);
    await _loadImages();
  }

  /// Pulls the image from its registry via the API.
  Future<void> _pullImage(ImageItem image) async {
    await widget.apiClient.pullImage(image.reference);
    await _loadImages();
    if (_selectedImage?.id == image.id) {
      await _openImage(image);
    }
  }

  /// Pushes the image to Docker Hub via the API.
  Future<void> _pushImage(ImageItem image) async {
    await widget.apiClient.pushImage(image.reference);
  }

  /// Starts the container engine when the list is empty and runtime is stopped.
  Future<void> _startEngine() async {
    try {
      await widget.apiClient.startRuntime();
      if (!mounted) {
        return;
      }
      await _loadImages();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    if (_selectedImage != null) {
      return _ImageDetailView(
        image: _selectedImage!,
        layers: _layers,
        layersLoading: _layersLoading,
        layersError: _layersError,
        onBack: _closeImage,
        onRun: () => _runImage(_selectedImage!),
        onPull: () => _pullImage(_selectedImage!),
        onPush: () => _pushImage(_selectedImage!),
        onRemove: () => _removeImage(_selectedImage!),
      );
    }

    final theme = Theme.of(context);
    final filtered = _searchQuery.isEmpty
        ? _images
        : _images
              .where(
                (img) =>
                    img.repository.toLowerCase().contains(_searchQuery) ||
                    img.tag.toLowerCase().contains(_searchQuery) ||
                    img.id.toLowerCase().contains(_searchQuery),
              )
              .toList();
    final runtimeStopped = _runtime?.state == 'stopped';

    return ResourceListScaffold(
      title: 'Images',
      searchController: _searchController,
      loading: _loading,
      error: _error,
      empty: filtered.isEmpty,
      emptyMessage: _searchQuery.isNotEmpty
          ? 'No images match "$_searchQuery".'
          : runtimeStopped
          ? 'No images. Runtime is stopped.'
          : 'No local images.',
      emptyAction: filtered.isEmpty && runtimeStopped && _searchQuery.isEmpty
          ? CalfButton(
              onPressed: _startEngine,
              child: const Text('Start engine'),
            )
          : null,
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final image = filtered[index];

        return HoverListRow(
          theme: theme,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          onTap: () => _openImage(image),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(image.reference, style: theme.textTheme.titleMedium),
                    Text(image.size, style: CalfTheme.muted(theme)),
                  ],
                ),
              ),
              CalfButton.outline(
                onPressed: () => _removeImage(image),
                child: const Text('Remove'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ImageDetailView extends StatefulWidget {
  /// Creates a [_ImageDetailView] widget.
  const _ImageDetailView({
    required this.image,
    required this.layers,
    required this.layersLoading,
    required this.layersError,
    required this.onBack,
    required this.onRun,
    required this.onPull,
    required this.onPush,
    required this.onRemove,
  });

  final ImageItem image;
  final List<ImageLayer>? layers;
  final bool layersLoading;
  final String? layersError;
  final VoidCallback onBack;
  final Future<void> Function() onRun;
  final Future<void> Function() onPull;
  final Future<void> Function() onPush;
  final VoidCallback onRemove;

  /// Creates the mutable state for [_ImageDetailView].
  @override
  State<_ImageDetailView> createState() => _ImageDetailViewState();
}

class _ImageDetailViewState extends State<_ImageDetailView> {
  final _menuButtonKey = GlobalKey();
  bool _busy = false;
  String? _actionMessage;
  String? _actionError;

  /// Navigates to or opens the selected actionsmenu.
  Future<void> _openActionsMenu() async {
    if (_busy) {
      return;
    }

    final buttonContext = _menuButtonKey.currentContext;
    if (buttonContext == null || !buttonContext.mounted) {
      return;
    }

    final box = buttonContext.findRenderObject()! as RenderBox;
    final overlayBox =
        Overlay.of(buttonContext).context.findRenderObject()! as RenderBox;
    final offset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final theme = Theme.of(buttonContext);
    const menuWidth = 220.0;

    final selected = await showMenu<String>(
      context: buttonContext,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(offset.dx, offset.dy + box.size.height + 4, menuWidth, 0),
        Offset.zero & overlayBox.size,
      ),
      color: theme.colorScheme.surface,
      surfaceTintColor: const Color(0x00000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      constraints: const BoxConstraints(minWidth: menuWidth),
      items: const [
        PopupMenuItem(value: 'pull', child: Text('Pull')),
        PopupMenuItem(value: 'push', child: Text('Push to Docker Hub')),
      ],
    );

    if (!mounted || selected == null) {
      return;
    }

    switch (selected) {
      case 'pull':
        await _runAction(widget.onPull, 'Image pulled');
      case 'push':
        await _runAction(widget.onPush, 'Image pushed');
    }
  }

  /// Runs an image action and shows a success or error message.
  Future<void> _runAction(
    Future<void> Function() action,
    String successMessage,
  ) async {
    setState(() {
      _busy = true;
      _actionError = null;
      _actionMessage = null;
    });

    try {
      await action();
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _actionMessage = successMessage;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _actionError = error.toString();
      });
    }
  }

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final image = widget.image;
    final layers = widget.layers;
    final layersLoading = widget.layersLoading;
    final layersError = widget.layersError;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CalfButton.ghost(
              width: 36,
              height: 36,
              onPressed: widget.onBack,
              child: Icon(
                LucideIcons.chevronLeft,
                size: 18,
                color: theme.colorScheme.onSurface,
              ),
            ),

            /// Creates a [_ImageDetailViewState] widget.
            const SizedBox(width: 4),
            Text('Images', style: CalfTheme.muted(theme)),
            Text(' / ', style: CalfTheme.muted(theme)),
            Expanded(
              child: Text(
                image.reference,
                style: CalfTheme.muted(theme),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),

        /// Creates a [_ImageDetailViewState] widget.
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    image.reference,
                    style: theme.textTheme.headlineSmall,
                    overflow: TextOverflow.ellipsis,
                  ),

                  /// Creates a [_ImageDetailViewState] widget.
                  const SizedBox(height: 8),
                  Text(image.shortId, style: CalfTheme.muted(theme)),
                  if (image.created.isNotEmpty) ...[
                    /// Creates a [_ImageDetailViewState] widget.
                    const SizedBox(height: 12),
                    Text(
                      'CREATED',
                      style: theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(image.created, style: theme.textTheme.titleMedium),
                  ],

                  /// Creates a [_ImageDetailViewState] widget.
                  const SizedBox(height: 12),
                  Text(
                    'SIZE',
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(image.size, style: theme.textTheme.titleMedium),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CalfButton(
                  enabled: !_busy,
                  onPressed: () =>
                      _runAction(widget.onRun, 'Container started'),
                  child: const Text('Run'),
                ),
                CalfButton.outline(
                  key: _menuButtonKey,
                  enabled: !_busy,
                  width: 36,
                  height: 36,
                  onPressed: _openActionsMenu,
                  child: Icon(
                    LucideIcons.chevronDown,
                    size: 16,
                    color: theme.colorScheme.onSurface,
                  ),
                ),

                /// Creates a [_ImageDetailViewState] widget.
                const SizedBox(width: 8),
                CalfButton.destructive(
                  enabled: !_busy,
                  width: 36,
                  height: 36,
                  onPressed: widget.onRemove,
                  child: Icon(
                    LucideIcons.trash2,
                    size: 16,
                    color: theme.colorScheme.onError,
                  ),
                ),
              ],
            ),
          ],
        ),

        /// Creates a [_ImageDetailViewState] widget.
        const SizedBox(height: 16),
        Expanded(
          child: CustomScrollView(
            slivers: [
              if (_actionMessage != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _actionMessage!,
                      style: theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              if (_actionError != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _actionError!,
                      style: theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Text(
                  'Layers (${layers?.length ?? 0})',
                  style: theme.textTheme.titleMedium,
                ),
              ),

              /// Creates a [_ImageDetailViewState] widget.
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              _buildLayersSliver(theme, layers, layersLoading, layersError),
            ],
          ),
        ),
      ],
    );
  }

  /// Builds the sliver that lists image layers or loading/error states.
  Widget _buildLayersSliver(
    ThemeData theme,
    List<ImageLayer>? layers,
    bool layersLoading,
    String? layersError,
  ) {
    if (layersLoading) {
      return SliverToBoxAdapter(
        child: Text('Loading layers...', style: CalfTheme.muted(theme)),
      );
    }

    if (layersError != null) {
      return SliverToBoxAdapter(
        child: Text(
          layersError,
          style: theme.textTheme.titleMedium!.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    }

    if (layers == null || layers.isEmpty) {
      return SliverToBoxAdapter(
        child: Text('No layers found.', style: CalfTheme.muted(theme)),
      );
    }

    return SliverList.separated(
      itemCount: layers.length,
      separatorBuilder: (_, _) =>
          Container(height: 1, color: theme.colorScheme.outlineVariant),
      itemBuilder: (context, index) {
        final layer = layers[index];

        return HoverListRow(
          theme: theme,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 28,
                child: Text('${layer.index}', style: CalfTheme.muted(theme)),
              ),
              Expanded(
                child: Text(
                  layer.createdBy,
                  style: theme.textTheme.titleMedium,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),

              /// Creates a [_ImageDetailViewState] widget.
              const SizedBox(width: 16),
              SizedBox(
                width: 88,
                child: Text(
                  layer.size,
                  style: CalfTheme.muted(theme),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
