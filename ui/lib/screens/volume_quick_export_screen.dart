import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/widgets/calf_button.dart';

enum VolumeQuickExportType { localFile, localImage, newImage, registry }

class VolumeQuickExportView extends StatefulWidget {
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

  @override
  void initState() {
    super.initState();
    _fileNameController.text = '${widget.volumeName}.tar.gz';
    _loadImages();
  }

  @override
  void dispose() {
    _fileNameController.dispose();
    _folderController.dispose();
    _imageRefController.dispose();
    super.dispose();
  }

  Future<void> _loadImages() async {
    setState(() {
      _imagesLoading = true;
      _imagesError = null;
    });

    try {
      final images = await widget.apiClient.fetchImages();
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

  bool get _canSave {
    if (_busy) {
      return false;
    }

    switch (_type) {
      case VolumeQuickExportType.localFile:
        return _fileNameController.text.trim().isNotEmpty && _folderController.text.trim().isNotEmpty;
      case VolumeQuickExportType.localImage:
        return _imageRefController.text.trim().isNotEmpty;
      case VolumeQuickExportType.newImage:
      case VolumeQuickExportType.registry:
        return _imageRefController.text.trim().isNotEmpty;
    }
  }

  Future<void> _browseFolder() async {
    try {
      final location = await getDirectoryPath(confirmButtonText: 'Select');
      if (location == null || !mounted) {
        return;
      }

      setState(() {
        _folderController.text = location;
        _error = null;
      });
    } on MissingPluginException {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Folder picker unavailable. Restart the app and try again. '
            '(hot reload cannot load native plugins).';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final type = switch (_type) {
        VolumeQuickExportType.localFile => 'local_file',
        VolumeQuickExportType.localImage => 'local_image',
        VolumeQuickExportType.newImage => 'new_image',
        VolumeQuickExportType.registry => 'registry',
      };

      await widget.apiClient.createVolumeExport(
        name: widget.volumeName,
        type: type,
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

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

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
            Text('Volumes', style: theme.textTheme.muted),
            Text(' / ', style: theme.textTheme.muted),
            Text(widget.volumeName, style: theme.textTheme.muted),
            Text(' / ', style: theme.textTheme.muted),
            Text('Quick export', style: theme.textTheme.muted),
          ],
        ),
        const SizedBox(height: 16),
        Text('Quick export', style: theme.textTheme.h3),
        const SizedBox(height: 8),
        Text(
          'Quick export data backup to a specified location.',
          style: theme.textTheme.muted,
        ),
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
                  Text('Location', style: theme.textTheme.large.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 16),
                  _ExportOptionTile(
                    theme: theme,
                    title: 'Local file',
                    description:
                        'Create a compressed file (.tar.gz) in a selected directory with the content of this volume.',
                    selected: _type == VolumeQuickExportType.localFile,
                    onSelect: () => setState(() => _type = VolumeQuickExportType.localFile),
                    child: _type == VolumeQuickExportType.localFile
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 12),
                              ShadInput(
                                controller: _fileNameController,
                                placeholder: const Text('File name'),
                                onChanged: (_) => setState(() {}),
                              ),
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
                  const SizedBox(height: 16),
                  _ExportOptionTile(
                    theme: theme,
                    title: 'Local image',
                    description: 'Copy the volume content to an existing image in the /volume-data directory.',
                    selected: _type == VolumeQuickExportType.localImage,
                    onSelect: () => setState(() => _type = VolumeQuickExportType.localImage),
                    child: _type == VolumeQuickExportType.localImage
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0x33F59E0B),
                                  border: Border.all(color: const Color(0x66F59E0B)),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(LucideIcons.triangleAlert, size: 16, color: const Color(0xFFF59E0B)),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'This overwrites the existing image with the volume contents and deletes the previous image.',
                                        style: theme.textTheme.small,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              _ImageRefField(
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
                  const SizedBox(height: 16),
                  _ExportOptionTile(
                    theme: theme,
                    title: 'New image',
                    description: 'Create a new image and copy the volume contents into it.',
                    selected: _type == VolumeQuickExportType.newImage,
                    onSelect: () => setState(() => _type = VolumeQuickExportType.newImage),
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
                  const SizedBox(height: 16),
                  _ExportOptionTile(
                    theme: theme,
                    title: 'Registry',
                    description: 'Push the volume content to Docker Hub.',
                    selected: _type == VolumeQuickExportType.registry,
                    onSelect: () => setState(() => _type = VolumeQuickExportType.registry),
                    child: _type == VolumeQuickExportType.registry
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(LucideIcons.info, size: 16, color: theme.colorScheme.primary),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'This might make any data in the volume publicly accessible on Docker Hub.',
                                        style: theme.textTheme.small,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              ShadInput(
                                controller: _imageRefController,
                                placeholder: const Text('<user>/<repo-name>:<tag>'),
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
          const SizedBox(height: 12),
          Text(_error!, style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive)),
        ],
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            CalfButton.outline(
              enabled: !_busy,
              onPressed: widget.onBack,
              child: const Text('Cancel'),
            ),
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

class _ExportOptionTile extends StatelessWidget {
  const _ExportOptionTile({
    required this.theme,
    required this.title,
    required this.description,
    required this.selected,
    required this.onSelect,
    this.child,
  });

  final ShadThemeData theme;
  final String title;
  final String description;
  final bool selected;
  final VoidCallback onSelect;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: selected ? theme.colorScheme.primary : theme.colorScheme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: onSelect,
            behavior: HitTestBehavior.opaque,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected ? LucideIcons.circleDot : LucideIcons.circle,
                  size: 18,
                  color: selected ? theme.colorScheme.primary : theme.colorScheme.mutedForeground,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.large.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(description, style: theme.textTheme.muted),
                    ],
                  ),
                ),
              ],
            ),
          ),
          ?child,
        ],
      ),
    );
  }
}

class _ImageRefField extends StatelessWidget {
  const _ImageRefField({
    required this.theme,
    required this.controller,
    required this.images,
    required this.imagesLoading,
    required this.imagesError,
    required this.onChanged,
  });

  final ShadThemeData theme;
  final TextEditingController controller;
  final List<ImageItem> images;
  final bool imagesLoading;
  final String? imagesError;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    if (imagesLoading) {
      return Text('Loading images...', style: theme.textTheme.muted);
    }

    if (imagesError != null) {
      return ShadInput(
        controller: controller,
        placeholder: const Text('Image name'),
        onChanged: (_) => onChanged(),
      );
    }

    if (images.isEmpty) {
      return ShadInput(
        controller: controller,
        placeholder: const Text('Image name'),
        onChanged: (_) => onChanged(),
      );
    }

    final references = images.map((image) => image.reference).toSet().toList()..sort();
    final selected = references.contains(controller.text) ? controller.text : null;

    return ShadSelect<String>(
      placeholder: const Text('Image name'),
      initialValue: selected,
      options: references
          .map(
            (reference) => ShadOption(
              value: reference,
              child: Text(reference),
            ),
          )
          .toList(),
      selectedOptionBuilder: (context, value) => Text(value),
      onChanged: (value) {
        if (value == null) {
          return;
        }
        controller.text = value;
        onChanged();
      },
    );
  }
}
