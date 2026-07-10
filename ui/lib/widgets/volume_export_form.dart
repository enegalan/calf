import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';

enum VolumeQuickExportType { localFile, localImage, newImage, registry }

String volumeQuickExportTypeToApi(VolumeQuickExportType type) {
  return switch (type) {
    VolumeQuickExportType.localFile => 'local_file',
    VolumeQuickExportType.localImage => 'local_image',
    VolumeQuickExportType.newImage => 'new_image',
    VolumeQuickExportType.registry => 'registry',
  };
}

VolumeQuickExportType volumeQuickExportTypeFromApi(String value) {
  switch (value) {
    case 'local_image':
      return VolumeQuickExportType.localImage;
    case 'new_image':
      return VolumeQuickExportType.newImage;
    case 'registry':
      return VolumeQuickExportType.registry;
    default:
      return VolumeQuickExportType.localFile;
  }
}

Future<List<ImageItem>> loadVolumeExportImages(CalfClient apiClient) {
  return apiClient.fetchImages();
}

Future<String?> browseVolumeExportFolder() {
  return getDirectoryPath(confirmButtonText: 'Select');
}

String? folderPickerErrorMessage(Object error) {
  if (error is MissingPluginException) {
    return 'Folder picker unavailable. Restart the app and try again. '
        '(hot reload cannot load native plugins).';
  }

  return error.toString();
}

class VolumeExportOptionTile extends StatelessWidget {
  const VolumeExportOptionTile({
    super.key,
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
  final VoidCallback? onSelect;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.border,
        ),
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
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.mutedForeground,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.large.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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

class VolumeExportImageRefField extends StatelessWidget {
  const VolumeExportImageRefField({
    super.key,
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

    if (imagesError != null || images.isEmpty) {
      return ShadInput(
        controller: controller,
        placeholder: const Text('Image name'),
        onChanged: (_) => onChanged(),
      );
    }

    final references = images.map((image) => image.reference).toSet().toList()
      ..sort();
    final selected = references.contains(controller.text)
        ? controller.text
        : null;

    return ShadSelect<String>(
      placeholder: const Text('Image name'),
      initialValue: selected,
      options: references
          .map(
            (reference) => ShadOption(value: reference, child: Text(reference)),
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

class VolumeExportRegistryNotice extends StatelessWidget {
  const VolumeExportRegistryNotice({super.key, required this.theme});

  final ShadThemeData theme;

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
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'This might make any data in the volume publicly accessible on Docker Hub.',
              style: theme.textTheme.small,
            ),
          ),
        ],
      ),
    );
  }
}

class VolumeExportLocalImageWarning extends StatelessWidget {
  const VolumeExportLocalImageWarning({super.key, required this.theme});

  final ShadThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x33F59E0B),
        border: Border.all(color: const Color(0x66F59E0B)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            LucideIcons.triangleAlert,
            size: 16,
            color: const Color(0xFFF59E0B),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'This overwrites the existing image with the volume contents and deletes the previous image.',
              style: theme.textTheme.small,
            ),
          ),
        ],
      ),
    );
  }
}
