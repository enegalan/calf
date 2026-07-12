import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/detail_breadcrumb.dart';
import 'package:ui/widgets/volume_export_form.dart';

class VolumeQuickExportView extends StatefulWidget {
  /// Creates a [VolumeQuickExportView] widget.
  const VolumeQuickExportView({
    super.key,
    required this.volumeName,
    required this.apiClient,
    required this.onBack,
    required this.onCompleted,
  });

  final String volumeName;
  final CalfClient apiClient;
  final VoidCallback onBack;
  final VoidCallback onCompleted;

  /// Creates the mutable state for [VolumeQuickExportView].
  @override
  State<VolumeQuickExportView> createState() => _VolumeQuickExportViewState();
}

class _VolumeQuickExportViewState extends State<VolumeQuickExportView> {
  VolumeQuickExportType _type = VolumeQuickExportType.localFile;
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
    _fileNameController.text = '${widget.volumeName}.tar.gz';
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

  /// Whether or what value backs the `canSave` UI state.
  bool get _canSave {
    if (_busy) {
      return false;
    }

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

  /// Submits the form and triggers the export via the API.
  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await widget.apiClient.createVolumeExport(
        name: widget.volumeName,
        type: volumeQuickExportTypeToApi(_type),
        fileName: _fileNameController.text.trim(),
        folder: _folderController.text.trim(),
        imageRef: _imageRefController.text.trim(),
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
    final theme = ShadTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailBreadcrumb(
          segments: ['Volumes', widget.volumeName, 'Quick export'],
          onBack: widget.onBack,
        ),

        /// Creates a [_VolumeQuickExportViewState] widget.
        const SizedBox(height: 16),
        Text('Quick export', style: theme.textTheme.h3),

        /// Creates a [_VolumeQuickExportViewState] widget.
        const SizedBox(height: 8),
        Text(
          'Quick export data backup to a specified location.',
          style: theme.textTheme.muted,
        ),

        /// Creates a [_VolumeQuickExportViewState] widget.
        const SizedBox(height: 20),
        Expanded(
          child: SingleChildScrollView(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.border),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Location',
                    style: theme.textTheme.large.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),

                  /// Creates a [_VolumeQuickExportViewState] widget.
                  const SizedBox(height: 16),
                  VolumeExportOptionTile(
                    theme: theme,
                    title: 'Local file',
                    description:
                        'Create a compressed file (.tar.gz) in a selected directory with the content of this volume.',
                    selected: _type == VolumeQuickExportType.localFile,
                    onSelect: () =>
                        _setExportType(VolumeQuickExportType.localFile),
                    child: _type == VolumeQuickExportType.localFile
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              /// Creates a [_VolumeQuickExportViewState] widget.
                              const SizedBox(height: 12),
                              ShadInput(
                                controller: _fileNameController,
                                placeholder: const Text('File name'),
                                onChanged: (_) => setState(() {}),
                              ),

                              /// Creates a [_VolumeQuickExportViewState] widget.
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: ShadInput(
                                      controller: _folderController,
                                      placeholder: const Text('Select folder'),
                                      onChanged: (_) => setState(() {}),
                                    ),
                                  ),

                                  /// Creates a [_VolumeQuickExportViewState] widget.
                                  const SizedBox(width: 8),
                                  CalfButton.outline(
                                    onPressed: _browseFolder,
                                    child: const Text('Browse'),
                                  ),
                                ],
                              ),
                            ],
                          )
                        : null,
                  ),

                  /// Creates a [_VolumeQuickExportViewState] widget.
                  const SizedBox(height: 16),
                  VolumeExportOptionTile(
                    theme: theme,
                    title: 'Local image',
                    description:
                        'Copy the volume content to an existing image in the /volume-data directory.',
                    selected: _type == VolumeQuickExportType.localImage,
                    onSelect: () =>
                        _setExportType(VolumeQuickExportType.localImage),
                    child: _type == VolumeQuickExportType.localImage
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              /// Creates a [_VolumeQuickExportViewState] widget.
                              const SizedBox(height: 12),
                              VolumeExportLocalImageWarning(theme: theme),

                              /// Creates a [_VolumeQuickExportViewState] widget.
                              const SizedBox(height: 12),
                              VolumeExportImageRefField(
                                theme: theme,
                                controller: _imageRefController,
                                images: _images,
                                imagesLoading: _imagesLoading,
                                imagesError: _imagesError,
                                onChanged: () => setState(() {}),
                              ),
                            ],
                          )
                        : null,
                  ),

                  /// Creates a [_VolumeQuickExportViewState] widget.
                  const SizedBox(height: 16),
                  VolumeExportOptionTile(
                    theme: theme,
                    title: 'New image',
                    description:
                        'Create a new image and copy the volume contents into it.',
                    selected: _type == VolumeQuickExportType.newImage,
                    onSelect: () =>
                        _setExportType(VolumeQuickExportType.newImage),
                    child: _type == VolumeQuickExportType.newImage
                        ? Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: ShadInput(
                              controller: _imageRefController,
                              placeholder: const Text('Image name'),
                              onChanged: (_) => setState(() {}),
                            ),
                          )
                        : null,
                  ),

                  /// Creates a [_VolumeQuickExportViewState] widget.
                  const SizedBox(height: 16),
                  VolumeExportOptionTile(
                    theme: theme,
                    title: 'Registry',
                    description: 'Push the volume content to Docker Hub.',
                    selected: _type == VolumeQuickExportType.registry,
                    onSelect: () =>
                        _setExportType(VolumeQuickExportType.registry),
                    child: _type == VolumeQuickExportType.registry
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              /// Creates a [_VolumeQuickExportViewState] widget.
                              const SizedBox(height: 12),
                              VolumeExportRegistryNotice(theme: theme),

                              /// Creates a [_VolumeQuickExportViewState] widget.
                              const SizedBox(height: 12),
                              ShadInput(
                                controller: _imageRefController,
                                placeholder: const Text(
                                  '<user>/<repo-name>:<tag>',
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ],
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_error != null) ...[
          /// Creates a [_VolumeQuickExportViewState] widget.
          const SizedBox(height: 12),
          Text(
            _error!,
            style: theme.textTheme.small.copyWith(
              color: theme.colorScheme.destructive,
            ),
          ),
        ],

        /// Creates a [_VolumeQuickExportViewState] widget.
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            CalfButton.outline(
              onPressed: widget.onBack,
              child: const Text('Cancel'),
            ),

            /// Creates a [_VolumeQuickExportViewState] widget.
            const SizedBox(width: 8),
            CalfButton(
              enabled: _canSave,
              onPressed: _save,
              child: Text(_busy ? 'Exporting...' : 'Save'),
            ),
          ],
        ),
      ],
    );
  }
}
