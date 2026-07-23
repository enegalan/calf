import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/theme/calf_theme.dart';

enum VolumeQuickExportType { localFile, localImage, newImage, registry }

/// Maps a [VolumeQuickExportType] to its API string value.
String volumeQuickExportTypeToApi(VolumeQuickExportType type) {
  return switch (type) {
    VolumeQuickExportType.localFile => 'local_file',
    VolumeQuickExportType.localImage => 'local_image',
    VolumeQuickExportType.newImage => 'new_image',
    VolumeQuickExportType.registry => 'registry',
  };
}

/// Parses an API export type string into a [VolumeQuickExportType].
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

/// Fetches the image list used by volume export destination pickers.
Future<List<ImageItem>> loadVolumeExportImages(CalfClient apiClient) {
  return apiClient.fetchImages();
}

/// Opens a native folder picker for choosing a volume export destination.
Future<String?> browseVolumeExportFolder() {
  return getDirectoryPath(confirmButtonText: 'Select');
}

/// Returns a user-friendly message when the folder picker fails.
String? folderPickerErrorMessage(Object error) {
  if (error is MissingPluginException) {
    return 'Folder picker unavailable. Restart the app and try again. '
        '(hot reload cannot load native plugins).';
  }

  return error.toString();
}

class VolumeExportOptionTile extends StatelessWidget {
  /// Renders a selectable radio-style tile for a volume export option.
  const VolumeExportOptionTile({
    super.key,
    required this.theme,
    required this.title,
    required this.description,
    required this.selected,
    required this.onSelect,
    this.child,
  });

  final ThemeData theme;
  final String title;
  final String description;
  final bool selected;
  final VoidCallback? onSelect;
  final Widget? child;

  /// Builds the selectable export option tile.
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
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
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium!.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(description, style: CalfTheme.muted(theme)),
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
  /// Renders an image reference field with dropdown or free-text fallback.
  const VolumeExportImageRefField({
    super.key,
    required this.theme,
    required this.controller,
    required this.images,
    required this.imagesLoading,
    required this.imagesError,
    required this.onChanged,
  });

  final ThemeData theme;
  final TextEditingController controller;
  final List<ImageItem> images;
  final bool imagesLoading;
  final String? imagesError;
  final VoidCallback onChanged;

  /// Builds the image reference input or dropdown.
  @override
  Widget build(BuildContext context) {
    if (imagesLoading) {
      return Text('Loading images...', style: CalfTheme.muted(theme));
    }

    if (imagesError != null || images.isEmpty) {
      return TextField(
        controller: controller,
        decoration: const InputDecoration(hintText: 'Image name'),
        onChanged: (_) => onChanged(),
      );
    }

    final references = images.map((image) => image.reference).toSet().toList()
      ..sort();
    final selected = references.contains(controller.text)
        ? controller.text
        : null;

    return DropdownButton<String>(
      value: selected,
      isExpanded: true,
      hint: const Text('Image name'),
      items: references
          .map(
            (reference) => DropdownMenuItem<String>(
              value: reference,
              child: Text(reference),
            ),
          )
          .toList(),
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
  /// Shows a notice that registry export may expose volume data publicly.
  const VolumeExportRegistryNotice({super.key, required this.theme});

  final ThemeData theme;

  /// Builds the registry export privacy notice.
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
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class VolumeExportLocalImageWarning extends StatelessWidget {
  /// Warns that exporting to a local image overwrites the existing image.
  const VolumeExportLocalImageWarning({super.key, required this.theme});

  final ThemeData theme;

  /// Builds the local image overwrite warning banner.
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
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
