import 'dart:async';

import 'package:flutter/material.dart' show
    PopupMenuItem,
    RelativeRect,
    RoundedRectangleBorder,
    Tooltip,
    showMenu;
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/screens/volume_detail_screen.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/hover_list_row.dart';

class ImagesScreen extends StatefulWidget {
  const ImagesScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

  @override
  State<ImagesScreen> createState() => _ImagesScreenState();
}

class _ImagesScreenState extends State<ImagesScreen> {
  List<ImageItem> _images = [];
  RuntimeStatus? _runtime;
  String? _error;
  bool _loading = true;
  Timer? _timer;
  int _pollIntervalMs = 3000;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  ImageItem? _selectedImage;
  List<ImageLayer>? _layers;
  bool _layersLoading = false;
  String? _layersError;

  @override
  void initState() {
    super.initState();
    _loadImages();
    _loadConfig();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final config = await widget.apiClient.fetchConfig();
      if (mounted) {
        _pollIntervalMs = config.pollIntervalMs;
        _timer = Timer.periodic(Duration(milliseconds: _pollIntervalMs), (_) => _loadImages(silent: true));
      }
    } catch (_) {
      if (mounted) {
        _timer = Timer.periodic(Duration(milliseconds: _pollIntervalMs), (_) => _loadImages(silent: true));
      }
    }
  }

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

  void _closeImage() {
    setState(() {
      _selectedImage = null;
      _layers = null;
      _layersError = null;
      _layersLoading = false;
    });
  }

  Future<void> _removeImage(ImageItem image) async {
    await widget.apiClient.removeImage(image.reference);
    if (_selectedImage?.id == image.id) {
      _closeImage();
    }
    await _loadImages();
  }

  Future<void> _runImage(ImageItem image) async {
    await widget.apiClient.runImage(image.reference);
    await _loadImages();
  }

  Future<void> _pullImage(ImageItem image) async {
    await widget.apiClient.pullImage(image.reference);
    await _loadImages();
    if (_selectedImage?.id == image.id) {
      await _openImage(image);
    }
  }

  Future<void> _pushImage(ImageItem image) async {
    await widget.apiClient.pushImage(image.reference);
  }

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
        : _images.where((img) =>
            img.repository.toLowerCase().contains(_searchQuery) ||
            img.tag.toLowerCase().contains(_searchQuery) ||
            img.id.toLowerCase().contains(_searchQuery)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Images', style: theme.textTheme.h3),
        const SizedBox(height: 16),
        ShadInput(
          controller: _searchController,
          placeholder: const Text('Search'),
        ),
        const SizedBox(height: 24),
        if (_loading)
          Text('Loading...', style: theme.textTheme.large)
        else if (_error != null)
          Text(_error!, style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive))
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
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

  @override
  State<_ImageDetailView> createState() => _ImageDetailViewState();
}

class _ImageDetailViewState extends State<_ImageDetailView> {
  final _menuButtonKey = GlobalKey();
  bool _busy = false;
  String? _actionMessage;
  String? _actionError;

  Future<void> _openActionsMenu() async {
    if (_busy) {
      return;
    }

    final buttonContext = _menuButtonKey.currentContext;
    if (buttonContext == null || !buttonContext.mounted) {
      return;
    }

    final box = buttonContext.findRenderObject()! as RenderBox;
    final overlayBox = Overlay.of(buttonContext).context.findRenderObject()! as RenderBox;
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

  Future<void> _runAction(Future<void> Function() action, String successMessage) async {
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
              child: Icon(LucideIcons.chevronLeft, size: 18, color: theme.colorScheme.foreground),
            ),
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
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(image.reference, style: theme.textTheme.h3, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 8),
                  Text(image.shortId, style: theme.textTheme.muted),
                  if (image.created.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text('CREATED', style: theme.textTheme.small.copyWith(color: theme.colorScheme.mutedForeground)),
                    Text(image.created, style: theme.textTheme.large),
                  ],
                  const SizedBox(height: 12),
                  Text('SIZE', style: theme.textTheme.small.copyWith(color: theme.colorScheme.mutedForeground)),
                  Text(image.size, style: theme.textTheme.large),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CalfButton(
                  enabled: !_busy,
                  onPressed: () => _runAction(widget.onRun, 'Container started'),
                  child: const Text('Run'),
                ),
                CalfButton.outline(
                  key: _menuButtonKey,
                  enabled: !_busy,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  onPressed: _openActionsMenu,
                  child: Icon(LucideIcons.chevronDown, size: 16, color: theme.colorScheme.foreground),
                ),
                const SizedBox(width: 8),
                CalfButton.destructive(
                  enabled: !_busy,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  onPressed: widget.onRemove,
                  child: Icon(LucideIcons.trash2, size: 16, color: theme.colorScheme.destructiveForeground),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: CustomScrollView(
            slivers: [
              if (_actionMessage != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_actionMessage!, style: theme.textTheme.small.copyWith(color: theme.colorScheme.primary)),
                  ),
                ),
              if (_actionError != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _actionError!,
                      style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Text('Layers (${layers?.length ?? 0})', style: theme.textTheme.large),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              _buildLayersSliver(theme, layers, layersLoading, layersError),
            ],
          ),
        ),
      ],
    );
  }

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
        child: Text(layersError, style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive)),
      );
    }

    if (layers == null || layers.isEmpty) {
      return SliverToBoxAdapter(
        child: Text('No layers found.', style: theme.textTheme.muted),
      );
    }

    return SliverList.separated(
      itemCount: layers.length,
      separatorBuilder: (_, __) => Container(
        height: 1,
        color: theme.colorScheme.border,
      ),
      itemBuilder: (context, index) {
        final layer = layers[index];

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
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

class VolumesScreen extends StatefulWidget {
  const VolumesScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

  @override
  State<VolumesScreen> createState() => _VolumesScreenState();
}

class _VolumesScreenState extends State<VolumesScreen> {
  List<VolumeItem> _volumes = [];
  RuntimeStatus? _runtime;
  String? _error;
  bool _loading = true;
  bool _refreshInFlight = false;
  final _nameController = TextEditingController();
  final _searchController = TextEditingController();
  String _searchQuery = '';
  String? _selectedVolume;

  @override
  void initState() {
    super.initState();
    _loadVolumes();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool _volumesChanged(List<VolumeItem> current, List<VolumeItem> next) {
    if (current.length != next.length) {
      return true;
    }

    for (var index = 0; index < current.length; index++) {
      final before = current[index];
      final after = next[index];
      if (before.name != after.name ||
          before.driver != after.driver ||
          before.inUse != after.inUse ||
          before.size != after.size ||
          before.created != after.created) {
        return true;
      }
    }

    return false;
  }

  List<VolumeItem> _sortedVolumes(List<VolumeItem> volumes) {
    return List<VolumeItem>.from(volumes)..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> _loadVolumes({bool silent = false}) async {
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
      final volumes = _sortedVolumes(await widget.apiClient.fetchVolumes());
      if (!mounted) {
        return;
      }

      if (!silent || _volumesChanged(_volumes, volumes) || _runtime?.state != status.runtime.state) {
        setState(() {
          _runtime = status.runtime;
          _volumes = volumes;
          _loading = false;
        });
      }
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

  Future<void> _createVolume() async {
    try {
      await widget.apiClient.createVolume(_nameController.text.trim());
      _nameController.clear();
      await _loadVolumes();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  void _openVolume(VolumeItem volume) {
    setState(() => _selectedVolume = volume.name);
  }

  void _closeVolume() {
    setState(() => _selectedVolume = null);
  }

  Future<void> _cloneVolume(VolumeItem volume) async {
    final nameController = TextEditingController(text: '${volume.name}-copy');
    final theme = ShadTheme.of(context);

    final confirmed = await showShadDialog<bool>(
      context: context,
      builder: (dialogContext) => ShadDialog(
        title: const Text('Clone volume'),
        description: Text('Create a copy of "${volume.name}".'),
        actions: [
          CalfButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          CalfButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clone'),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Volume name', style: theme.textTheme.small.copyWith(color: theme.colorScheme.mutedForeground)),
            const SizedBox(height: 8),
            ShadInput(
              controller: nameController,
              placeholder: const Text('Volume name'),
            ),
          ],
        ),
      ),
    );

    final destination = nameController.text.trim();
    nameController.dispose();

    if (confirmed != true || destination.isEmpty || !mounted) {
      return;
    }

    try {
      await widget.apiClient.cloneVolume(volume.name, destination);
      if (!mounted) {
        return;
      }
      await _loadVolumes();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedVolume != null) {
      return VolumeDetailView(
        volumeName: _selectedVolume!,
        apiClient: widget.apiClient,
        onBack: _closeVolume,
        onRemoved: _loadVolumes,
      );
    }

    final theme = ShadTheme.of(context);
    final filtered = _searchQuery.isEmpty
        ? _volumes
        : _volumes.where((v) =>
            v.name.toLowerCase().contains(_searchQuery) ||
            v.driver.toLowerCase().contains(_searchQuery)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Volumes', style: theme.textTheme.h3),
        const SizedBox(height: 16),
        ShadInput(
          controller: _searchController,
          placeholder: const Text('Search'),
        ),
        const SizedBox(height: 24),
        if (_loading)
          Text('Loading...', style: theme.textTheme.large)
        else if (_error != null)
          Text(_error!, style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive))
        else if (filtered.isEmpty)
          Text(
            _searchQuery.isNotEmpty
                ? 'No volumes match "$_searchQuery".'
                : _runtime?.state == 'stopped'
                    ? 'No volumes. Runtime is stopped.'
                    : 'No volumes.',
            style: theme.textTheme.muted,
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final volume = filtered[index];

                return HoverListRow(
                  theme: theme,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  onTap: () => _openVolume(volume),
                  child: Row(
                    children: [
                      _VolumeStatusDot(inUse: volume.inUse, theme: theme),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(volume.name, style: theme.textTheme.large),
                            if (volume.subtitle.isNotEmpty)
                              Text(volume.subtitle, style: theme.textTheme.muted),
                          ],
                        ),
                      ),
                      Tooltip(
                        message: 'Clone',
                        child: CalfButton.outline(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          onPressed: () => _cloneVolume(volume),
                          child: Icon(LucideIcons.copy, size: 16, color: theme.colorScheme.foreground),
                        ),
                      ),
                      const SizedBox(width: 8),
                      CalfButton.outline(
                        onPressed: () async {
                          await widget.apiClient.removeVolume(volume.name);
                          await _loadVolumes();
                        },
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

class _VolumeStatusDot extends StatelessWidget {
  const _VolumeStatusDot({
    required this.inUse,
    required this.theme,
  });

  final bool inUse;
  final ShadThemeData theme;

  static const _dotSize = 9.0;
  static const _borderWidth = 1.5;

  @override
  Widget build(BuildContext context) {
    if (inUse) {
      return Container(
        width: _dotSize,
        height: _dotSize,
        decoration: BoxDecoration(
          color: const Color(0xFF2DBE60),
          shape: BoxShape.circle,
          border: Border.all(color: theme.colorScheme.background, width: _borderWidth),
        ),
      );
    }

    return Container(
      width: _dotSize,
      height: _dotSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: theme.colorScheme.mutedForeground, width: _borderWidth),
      ),
    );
  }
}

class BuildsScreen extends StatefulWidget {
  const BuildsScreen({super.key, required this.apiClient});

  final CalfClient apiClient;

  @override
  State<BuildsScreen> createState() => _BuildsScreenState();
}

class _BuildsScreenState extends State<BuildsScreen> {
  List<BuildItem> _builds = [];
  RuntimeStatus? _runtime;
  String? _error;
  bool _loading = true;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _timer;
  int _pollIntervalMs = 3000;

  @override
  void initState() {
    super.initState();
    _loadBuilds();
    _loadConfig();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final config = await widget.apiClient.fetchConfig();
      if (mounted) {
        _pollIntervalMs = config.pollIntervalMs;
        _timer = Timer.periodic(Duration(milliseconds: _pollIntervalMs), (_) => _loadBuilds(silent: true));
      }
    } catch (_) {
      if (mounted) {
        _timer = Timer.periodic(Duration(milliseconds: _pollIntervalMs), (_) => _loadBuilds(silent: true));
      }
    }
  }

  Future<void> _loadBuilds({bool silent = false}) async {
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final filtered = _searchQuery.isEmpty
        ? _builds
        : _builds.where((b) =>
            b.tag.toLowerCase().contains(_searchQuery) ||
            b.id.toLowerCase().contains(_searchQuery) ||
            b.status.toLowerCase().contains(_searchQuery))
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Builds', style: theme.textTheme.h3),
        const SizedBox(height: 16),
        ShadInput(
          controller: _searchController,
          placeholder: const Text('Search'),
        ),
        const SizedBox(height: 24),
        if (_loading)
          Text('Loading...', style: theme.textTheme.large)
        else if (_error != null)
          Text(_error!, style: theme.textTheme.large.copyWith(color: theme.colorScheme.destructive))
        else if (filtered.isEmpty)
          Text(
            _searchQuery.isNotEmpty
                ? 'No builds match "$_searchQuery".'
                : _runtime?.state == 'stopped'
                    ? 'No builds yet.'
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(build.tag, style: theme.textTheme.large),
                      Text('${build.context} · ${build.status}', style: theme.textTheme.muted),
                      Text(build.createdAt, style: theme.textTheme.muted),
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
