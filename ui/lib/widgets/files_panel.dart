import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/widgets/hover_list_row.dart';

typedef LoadDirectoryCallback = Future<List<ContainerFileEntry>> Function(String path);

class FilesPanel extends StatefulWidget {
  const FilesPanel({
    super.key,
    required this.theme,
    required this.loadDirectory,
  });

  final ShadThemeData theme;
  final LoadDirectoryCallback loadDirectory;

  @override
  State<FilesPanel> createState() => _FilesPanelState();
}

class _FilesPanelState extends State<FilesPanel> {
  final Map<String, List<ContainerFileEntry>> _cache = {};
  final Set<String> _expanded = {};
  final Set<String> _loading = {};
  final Map<String, String> _errors = {};
  bool _rootLoading = true;
  String? _rootError;

  @override
  void initState() {
    super.initState();
    _loadDirectory('/');
  }

  Future<void> _loadDirectory(String path) async {
    final isRoot = path == '/';
    setState(() {
      if (isRoot) {
        _rootLoading = true;
        _rootError = null;
      } else {
        _loading.add(path);
        _errors.remove(path);
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
          _rootError = error.toString();
          _rootLoading = false;
        } else {
          _loading.remove(path);
          _errors[path] = error.toString();
        }
      });
    }
  }

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

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;

    return FilesPanelContainer(
      theme: theme,
      child: _rootLoading
          ? Text('Loading files...', style: theme.textTheme.muted)
          : _rootError != null
              ? Text(_rootError!, style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilesPanelHeader(theme: theme),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView(
                        children: _buildDirectoryRows('/', 0),
                      ),
                    ),
                  ],
                ),
    );
  }

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
        ),
      );

      if (!entry.isDir || !expanded) {
        continue;
      }

      if (_loading.contains(entry.path)) {
        rows.add(FilesPanelStatusRow(theme: widget.theme, depth: depth + 1, message: 'Loading...'));
        continue;
      }

      if (_errors.containsKey(entry.path)) {
        rows.add(
          FilesPanelStatusRow(
            theme: widget.theme,
            depth: depth + 1,
            message: _errors[entry.path]!,
            isError: true,
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
  const FilesPanelContainer({
    super.key,
    required this.theme,
    required this.child,
  });

  final ShadThemeData theme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.border),
        borderRadius: theme.radius,
        color: filesPanelBackgroundColor(theme),
      ),
      padding: const EdgeInsets.all(12),
      child: child,
    );
  }
}

class FilesPanelHeader extends StatelessWidget {
  const FilesPanelHeader({super.key, required this.theme});

  final ShadThemeData theme;

  @override
  Widget build(BuildContext context) {
    final labelStyle = theme.textTheme.small.copyWith(
      color: theme.colorScheme.mutedForeground,
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
  const FilesPanelRow({
    super.key,
    required this.theme,
    required this.entry,
    required this.depth,
    required this.expanded,
    required this.onToggle,
  });

  final ShadThemeData theme;
  final ContainerFileEntry entry;
  final int depth;
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    return HoverListRow(
      theme: theme,
      padding: EdgeInsets.fromLTRB(8 + depth * 18.0, 8, 8, 8),
      onTap: onToggle,
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: entry.isDir
                ? Icon(
                    expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                    size: 16,
                    color: theme.colorScheme.mutedForeground,
                  )
                : null,
          ),
          Icon(
            entry.isDir ? LucideIcons.folder : LucideIcons.file,
            size: 16,
            color: theme.colorScheme.mutedForeground,
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text(entry.name, style: theme.textTheme.small, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            flex: 2,
            child: Text(entry.note, style: theme.textTheme.muted, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: Text(
              entry.isDir ? '' : formatFileSize(entry.size),
              style: theme.textTheme.muted,
            ),
          ),
          Expanded(
            child: Text(entry.modified, style: theme.textTheme.muted, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: Text(entry.mode, style: theme.textTheme.muted, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class FilesPanelStatusRow extends StatelessWidget {
  const FilesPanelStatusRow({
    super.key,
    required this.theme,
    required this.depth,
    required this.message,
    this.isError = false,
  });

  final ShadThemeData theme;
  final int depth;
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(8 + depth * 18.0 + 44, 4, 8, 4),
      child: Text(
        message,
        style: theme.textTheme.small.copyWith(
          color: isError ? theme.colorScheme.destructive : theme.colorScheme.mutedForeground,
        ),
      ),
    );
  }
}

Color filesPanelBackgroundColor(ShadThemeData theme) {
  return Color.alphaBlend(
    theme.colorScheme.muted.withValues(alpha: 0.2),
    theme.colorScheme.background,
  );
}

String formatFileSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} kB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
