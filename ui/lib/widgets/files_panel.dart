import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/calf_snack_bar.dart';
import 'package:ui/widgets/confirm_dialog.dart';
import 'package:ui/widgets/hover_list_row.dart';
import 'package:ui/theme/calf_theme.dart';
import 'package:ui/utils/format.dart';

/// Loads directory entries for a path in the container file browser.
typedef LoadDirectoryCallback =
    Future<List<ContainerFileEntry>> Function(String path);

/// Writes file contents at [path] in the container or volume.
typedef WriteFileCallback = Future<void> Function(String path, String content);

class FilesPanel extends StatefulWidget {
  /// Displays a lazy-loaded directory tree for container files.
  const FilesPanel({
    super.key,
    required this.theme,
    required this.loadDirectory,
    this.writeFile,
  });

  final ThemeData theme;
  final LoadDirectoryCallback loadDirectory;
  final WriteFileCallback? writeFile;

  /// Creates the mutable state for this files panel.
  @override
  State<FilesPanel> createState() => _FilesPanelState();
}

class _FilesPanelState extends State<FilesPanel> {
  final Map<String, List<ContainerFileEntry>> _cache = {};
  final Set<String> _expanded = {};
  final Set<String> _loading = {};
  bool _rootLoading = true;

  /// Loads the root directory when the panel is first shown.
  @override
  void initState() {
    super.initState();
    _loadDirectory('/');
  }

  /// Loads directory entries for [path] and updates cache or error state.
  Future<void> _loadDirectory(String path) async {
    final isRoot = path == '/';
    setState(() {
      if (isRoot) {
        _rootLoading = true;
      } else {
        _loading.add(path);
      }
    });

    try {
      final files = await widget.loadDirectory(path);
      if (!mounted) {
        return;
      }
      setState(() {
        _cache[path] = _sortedEntries(files);
        if (isRoot) {
          _rootLoading = false;
        } else {
          _loading.remove(path);
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        if (isRoot) {
          _rootLoading = false;
        } else {
          _loading.remove(path);
        }
      });
      showCalfErrorSnackBar(context, error);
    }
  }

  /// Expands or collapses a directory and loads its contents on first expand.
  void _toggleDirectory(String path) {
    setState(() {
      if (_expanded.contains(path)) {
        _expanded.remove(path);
        return;
      }
      _expanded.add(path);
    });

    if (!_cache.containsKey(path)) {
      _loadDirectory(path);
    }
  }

  /// Opens a dialog to overwrite [path] with new contents.
  Future<void> _editFile(String path) async {
    final writeFile = widget.writeFile;
    if (writeFile == null) {
      return;
    }
    final contentController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => CalfAlertDialog(
        title: const Text('Save file'),
        width: 480,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(path, style: CalfTheme.muted(Theme.of(dialogContext))),
            const SizedBox(height: 12),
            TextField(
              controller: contentController,
              maxLines: 12,
              decoration: const InputDecoration(
                labelText: 'Contents',
                hintText: 'Overwrites the file',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
        actions: [
          CalfButton.outline(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          CalfButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final content = contentController.text;
    contentController.dispose();
    if (confirmed != true || !mounted) {
      return;
    }
    final ok = await runCalfToastAction(
      pending: 'Saving $path...',
      done: 'Saved $path',
      action: () => writeFile(path, content),
    );
    if (ok && mounted) {
      final parent = path.contains('/')
          ? path.substring(0, path.lastIndexOf('/'))
          : '/';
      await _loadDirectory(parent.isEmpty ? '/' : parent);
    }
  }

  /// Sorts entries with directories first, then alphabetically by name.
  List<ContainerFileEntry> _sortedEntries(List<ContainerFileEntry> entries) {
    final sorted = List<ContainerFileEntry>.from(entries);
    sorted.sort((a, b) {
      if (a.isDir != b.isDir) {
        return a.isDir ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return sorted;
  }

  /// Builds the file tree or loading/error placeholder.
  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;

    return FilesPanelContainer(
      theme: theme,
      child: _rootLoading
          ? Text('Loading files...', style: CalfTheme.muted(theme))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilesPanelHeader(theme: theme),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(children: _buildDirectoryRows('/', 0)),
                ),
              ],
            ),
    );
  }

  /// Builds nested row widgets for [path] at the given tree [depth].
  List<Widget> _buildDirectoryRows(String path, int depth) {
    final entries = _cache[path] ?? [];
    final rows = <Widget>[];

    for (final entry in entries) {
      final expanded = entry.isDir && _expanded.contains(entry.path);
      rows.add(
        FilesPanelRow(
          theme: widget.theme,
          entry: entry,
          depth: depth,
          expanded: expanded,
          onToggle: entry.isDir ? () => _toggleDirectory(entry.path) : null,
          onEdit: !entry.isDir && widget.writeFile != null
              ? () => _editFile(entry.path)
              : null,
        ),
      );

      if (!entry.isDir || !expanded) {
        continue;
      }

      if (_loading.contains(entry.path)) {
        rows.add(
          FilesPanelStatusRow(
            theme: widget.theme,
            depth: depth + 1,
            message: 'Loading...',
          ),
        );
        continue;
      }

      rows.addAll(_buildDirectoryRows(entry.path, depth + 1));
    }

    return rows;
  }
}

class FilesPanelContainer extends StatelessWidget {
  /// Wraps files panel content in a bordered container.
  const FilesPanelContainer({
    super.key,
    required this.theme,
    required this.child,
  });

  final ThemeData theme;
  final Widget child;

  /// Builds the bordered panel container.
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: CalfTheme.radius,
        color: filesPanelBackgroundColor(theme),
      ),
      padding: const EdgeInsets.all(12),
      child: child,
    );
  }
}

class FilesPanelHeader extends StatelessWidget {
  /// Renders column headers for the files table.
  const FilesPanelHeader({super.key, required this.theme});

  final ThemeData theme;

  /// Builds the column header row.
  @override
  Widget build(BuildContext context) {
    final labelStyle = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          const SizedBox(width: 20),
          const SizedBox(width: 24),
          Expanded(flex: 3, child: Text('Name', style: labelStyle)),
          Expanded(flex: 2, child: Text('Note', style: labelStyle)),
          Expanded(child: Text('Size', style: labelStyle)),
          Expanded(child: Text('Last modified', style: labelStyle)),
          Expanded(child: Text('Mode', style: labelStyle)),
        ],
      ),
    );
  }
}

class FilesPanelRow extends StatelessWidget {
  /// Renders a single file or directory row in the tree.
  const FilesPanelRow({
    super.key,
    required this.theme,
    required this.entry,
    required this.depth,
    required this.expanded,
    required this.onToggle,
    this.onEdit,
  });

  final ThemeData theme;
  final ContainerFileEntry entry;
  final int depth;
  final bool expanded;
  final VoidCallback? onToggle;
  final VoidCallback? onEdit;

  /// Builds one file or directory table row.
  @override
  Widget build(BuildContext context) {
    return HoverListRow(
      theme: theme,
      padding: EdgeInsets.fromLTRB(8 + depth * 18.0, 8, 8, 8),
      onTap: onToggle ?? onEdit,
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: entry.isDir
                ? Icon(
                    expanded
                        ? LucideIcons.chevronDown
                        : LucideIcons.chevronRight,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  )
                : null,
          ),
          Icon(
            entry.isDir ? LucideIcons.folder : LucideIcons.file,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text(
              entry.name,
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              entry.note,
              style: CalfTheme.muted(theme),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Text(
              entry.isDir ? '' : formatFileSize(entry.size),
              style: CalfTheme.muted(theme),
            ),
          ),
          Expanded(
            child: Text(
              entry.modified,
              style: CalfTheme.muted(theme),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Text(
              entry.mode,
              style: CalfTheme.muted(theme),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onEdit != null)
            CalfButton.ghost(
              width: 28,
              height: 28,
              padding: EdgeInsets.zero,
              onPressed: onEdit,
              child: Icon(
                LucideIcons.pencil,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class FilesPanelStatusRow extends StatelessWidget {
  /// Renders a loading or error status line indented under a directory.
  const FilesPanelStatusRow({
    super.key,
    required this.theme,
    required this.depth,
    required this.message,
    this.isError = false,
  });

  final ThemeData theme;
  final int depth;
  final String message;
  final bool isError;

  /// Builds an indented status message row.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(8 + depth * 18.0 + 44, 4, 8, 4),
      child: Text(
        message,
        style: theme.textTheme.bodySmall!.copyWith(
          color: isError
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Returns the muted background color used by the files panel.
Color filesPanelBackgroundColor(ThemeData theme) {
  return Color.alphaBlend(
    theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
    theme.colorScheme.surface,
  );
}
