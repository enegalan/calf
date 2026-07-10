import 'dart:async';

import 'package:flutter/material.dart'
    show PopupMenuItem, RelativeRect, RoundedRectangleBorder, showMenu;
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/widgets/poll_interval_mixin.dart';

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
    }
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

  /// Removes the selected resource via the API.
  Future<void> _removeImage(ImageItem image) async {
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

    final theme = ShadTheme.of(context);
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Images', style: theme.textTheme.h3),
        /// Creates a [_ImagesScreenState] widget.
        const SizedBox(height: 16),
        ShadInput(
          controller: _searchController,
          placeholder: const Text('Search'),
        ),
        /// Creates a [_ImagesScreenState] widget.
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
                ? 'No images match "$_searchQuery".'
                : _runtime?.state == 'stopped'
                ? 'No images. Runtime is stopped.'
                : 'No local images.',
            style: theme.textTheme.muted,
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final image = filtered[index];

                return HoverListRow(
                  theme: theme,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 10,
                  ),
                  onTap: () => _openImage(image),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(image.reference, style: theme.textTheme.large),
                            Text(image.size, style: theme.textTheme.muted),
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
            ),
          ),
      ],
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
    final theme = ShadTheme.of(buttonContext);
    const menuWidth = 220.0;

    final selected = await showMenu<String>(
      context: buttonContext,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(offset.dx, offset.dy + box.size.height + 4, menuWidth, 0),
        Offset.zero & overlayBox.size,
      ),
      color: theme.colorScheme.popover,
      surfaceTintColor: const Color(0x00000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.border),
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
    final theme = ShadTheme.of(context);
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
              onPressed: widget.onBack,
              child: Icon(
                LucideIcons.chevronLeft,
                size: 18,
                color: theme.colorScheme.foreground,
              ),
            ),
            /// Creates a [_ImageDetailViewState] widget.
            const SizedBox(width: 4),
            Text('Images', style: theme.textTheme.muted),
            Text(' / ', style: theme.textTheme.muted),
            Expanded(
              child: Text(
                image.reference,
                style: theme.textTheme.muted,
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
                    style: theme.textTheme.h3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  /// Creates a [_ImageDetailViewState] widget.
                  const SizedBox(height: 8),
                  Text(image.shortId, style: theme.textTheme.muted),
                  if (image.created.isNotEmpty) ...[
                    /// Creates a [_ImageDetailViewState] widget.
                    const SizedBox(height: 12),
                    Text(
                      'CREATED',
                      style: theme.textTheme.small.copyWith(
                        color: theme.colorScheme.mutedForeground,
                      ),
                    ),
                    Text(image.created, style: theme.textTheme.large),
                  ],
                  /// Creates a [_ImageDetailViewState] widget.
                  const SizedBox(height: 12),
                  Text(
                    'SIZE',
                    style: theme.textTheme.small.copyWith(
                      color: theme.colorScheme.mutedForeground,
                    ),
                  ),
                  Text(image.size, style: theme.textTheme.large),
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
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  onPressed: _openActionsMenu,
                  child: Icon(
                    LucideIcons.chevronDown,
                    size: 16,
                    color: theme.colorScheme.foreground,
                  ),
                ),
                /// Creates a [_ImageDetailViewState] widget.
                const SizedBox(width: 8),
                CalfButton.destructive(
                  enabled: !_busy,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  onPressed: widget.onRemove,
                  child: Icon(
                    LucideIcons.trash2,
                    size: 16,
                    color: theme.colorScheme.destructiveForeground,
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
                      style: theme.textTheme.small.copyWith(
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
                      style: theme.textTheme.small.copyWith(
                        color: theme.colorScheme.destructive,
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Text(
                  'Layers (${layers?.length ?? 0})',
                  style: theme.textTheme.large,
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
    ShadThemeData theme,
    List<ImageLayer>? layers,
    bool layersLoading,
    String? layersError,
  ) {
    if (layersLoading) {
      return SliverToBoxAdapter(
        child: Text('Loading layers...', style: theme.textTheme.muted),
      );
    }

    if (layersError != null) {
      return SliverToBoxAdapter(
        child: Text(
          layersError,
          style: theme.textTheme.large.copyWith(
            color: theme.colorScheme.destructive,
          ),
        ),
      );
    }

    if (layers == null || layers.isEmpty) {
      return SliverToBoxAdapter(
        child: Text('No layers found.', style: theme.textTheme.muted),
      );
    }

    return SliverList.separated(
      itemCount: layers.length,
      separatorBuilder: (_, _) =>
          Container(height: 1, color: theme.colorScheme.border),
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
                child: Text('${layer.index}', style: theme.textTheme.muted),
              ),
              Expanded(
                child: Text(
                  layer.createdBy,
                  style: theme.textTheme.large,
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
                  style: theme.textTheme.muted,
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
