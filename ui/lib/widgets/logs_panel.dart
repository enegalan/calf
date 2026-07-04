import 'package:flutter/material.dart' show SelectableText, SelectionArea, Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:xterm/xterm.dart';

import 'package:ui/storage/logs_viewer_preferences.dart';
import 'package:ui/widgets/calf_button.dart';

class LogLine {
  const LogLine({
    required this.text,
    required this.receivedAt,
  });

  final String text;
  final DateTime receivedAt;
}

class MixedLogBlock {
  const MixedLogBlock({
    required this.containerId,
    required this.containerName,
    required this.color,
    required this.lines,
  });

  final String containerId;
  final String containerName;
  final Color color;
  final List<LogLine> lines;

  MixedLogBlock copyWith({List<LogLine>? lines}) {
    return MixedLogBlock(
      containerId: containerId,
      containerName: containerName,
      color: color,
      lines: lines ?? this.lines,
    );
  }
}

Color logsPanelBackground(ShadThemeData theme) {
  return Color.alphaBlend(
    theme.colorScheme.muted.withValues(alpha: 0.2),
    theme.colorScheme.background,
  );
}

const double _logTimestampColumnWidth = 184;

String formatLogTimestamp(DateTime receivedAt) {
  final local = receivedAt.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');

  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String formatLogPlainLine(LogLine line, {required bool showTimestamp}) {
  if (!showTimestamp) {
    return line.text;
  }

  return '${formatLogTimestamp(line.receivedAt)} ${line.text}';
}

class LogsPanel extends StatefulWidget {
  const LogsPanel({
    super.key,
    required this.lines,
    required this.scrollController,
    required this.onClear,
    this.error,
  });

  final List<LogLine> lines;
  final String? error;
  final ScrollController scrollController;
  final VoidCallback onClear;

  @override
  State<LogsPanel> createState() => _LogsPanelState();
}

class _LogsPanelState extends State<LogsPanel> {
  final _searchController = TextEditingController();
  bool _searchOpen = false;
  bool _regexEnabled = false;
  bool _showTimestamp = LogViewerPreferences.defaults.showTimestamp;
  bool _wrapLines = LogViewerPreferences.defaults.wrapLines;
  bool _settingsOpen = false;
  int _currentMatchIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final preferences = await LogViewerPreferences.load();
    if (!mounted) {
      return;
    }

    setState(() {
      _showTimestamp = preferences.showTimestamp;
      _wrapLines = preferences.wrapLines;
    });
  }

  void _setShowTimestamp(bool value) {
    setState(() => _showTimestamp = value);
    LogViewerPreferences.save(showTimestamp: value, wrapLines: _wrapLines);
  }

  void _setWrapLines(bool value) {
    setState(() => _wrapLines = value);
    LogViewerPreferences.save(showTimestamp: _showTimestamp, wrapLines: value);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchController.clear();
        _currentMatchIndex = 0;
      }
    });
  }

  void _toggleSettings() {
    setState(() => _settingsOpen = !_settingsOpen);
  }

  void _onSearchChanged(String _) {
    setState(() => _currentMatchIndex = 0);
  }

  String get _plainText {
    if (widget.error != null) {
      return widget.error!;
    }

    return widget.lines
        .map((line) => formatLogPlainLine(line, showTimestamp: _showTimestamp))
        .join('\n');
  }

  RegExp? _searchPattern() {
    final query = _searchController.text;
    if (query.isEmpty) {
      return null;
    }

    try {
      if (_regexEnabled) {
        return RegExp(query);
      }

      return RegExp(RegExp.escape(query), caseSensitive: false);
    } catch (_) {
      return null;
    }
  }

  List<_LogMatch> _findMatches() {
    final pattern = _searchPattern();
    if (pattern == null) {
      return const [];
    }

    final matches = <_LogMatch>[];
    for (var lineIndex = 0; lineIndex < widget.lines.length; lineIndex++) {
      for (final match in pattern.allMatches(widget.lines[lineIndex].text)) {
        matches.add(_LogMatch(lineIndex: lineIndex, start: match.start, end: match.end));
      }
    }

    return matches;
  }

  void _goToMatch(int direction, List<_LogMatch> matches) {
    if (matches.isEmpty) {
      return;
    }

    setState(() {
      _currentMatchIndex = (_currentMatchIndex + direction) % matches.length;
      if (_currentMatchIndex < 0) {
        _currentMatchIndex = matches.length - 1;
      }
    });

    final match = matches[_currentMatchIndex];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.scrollController.hasClients) {
        return;
      }

      final target = match.lineIndex * 18.0;
      widget.scrollController.animateTo(
        target.clamp(0, widget.scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: _plainText));
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final matches = _searchOpen ? _findMatches() : const <_LogMatch>[];
    if (matches.isNotEmpty && _currentMatchIndex >= matches.length) {
      _currentMatchIndex = 0;
    }

    return _LogsViewerChrome(
      theme: theme,
      searchOpen: _searchOpen,
      settingsOpen: _settingsOpen,
      regexEnabled: _regexEnabled,
      searchController: _searchController,
      onToggleSearch: _toggleSearch,
      onToggleSettings: _toggleSettings,
      onSearchChanged: _onSearchChanged,
      onRegexChanged: (value) => setState(() {
        _regexEnabled = value;
        _currentMatchIndex = 0;
      }),
      onPreviousMatch: matches.isEmpty ? null : () => _goToMatch(-1, matches),
      onNextMatch: matches.isEmpty ? null : () => _goToMatch(1, matches),
      onCopy: _copyToClipboard,
      onClear: widget.onClear,
      showTimestamp: _showTimestamp,
      wrapLines: _wrapLines,
      onShowTimestampChanged: _setShowTimestamp,
      onWrapLinesChanged: _setWrapLines,
      scrollController: widget.scrollController,
      scrollableContent: widget.error != null
          ? SelectableText(
              widget.error!,
              style: theme.textTheme.small.copyWith(
                fontFamily: 'Menlo',
                color: theme.colorScheme.destructive,
              ),
            )
          : widget.lines.isEmpty
              ? const SizedBox.shrink()
              : _LogTextView(
                  theme: theme,
                  logLines: widget.lines,
                  showTimestamp: _showTimestamp,
                  wrapLines: _wrapLines,
                  matches: matches,
                  currentMatchIndex: _currentMatchIndex,
                ),
    );
  }
}

class MixedLogsPanel extends StatefulWidget {
  const MixedLogsPanel({
    super.key,
    required this.blocks,
    required this.scrollController,
    required this.runningCount,
    required this.onClear,
  });

  final List<MixedLogBlock> blocks;
  final ScrollController scrollController;
  final int runningCount;
  final VoidCallback onClear;

  @override
  State<MixedLogsPanel> createState() => _MixedLogsPanelState();
}

class _MixedLogsPanelState extends State<MixedLogsPanel> {
  final _searchController = TextEditingController();
  bool _searchOpen = false;
  bool _regexEnabled = false;
  bool _showTimestamp = LogViewerPreferences.defaults.showTimestamp;
  bool _wrapLines = LogViewerPreferences.defaults.wrapLines;
  bool _settingsOpen = false;
  int _currentMatchIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final preferences = await LogViewerPreferences.load();
    if (!mounted) {
      return;
    }

    setState(() {
      _showTimestamp = preferences.showTimestamp;
      _wrapLines = preferences.wrapLines;
    });
  }

  void _setShowTimestamp(bool value) {
    setState(() => _showTimestamp = value);
    LogViewerPreferences.save(showTimestamp: value, wrapLines: _wrapLines);
  }

  void _setWrapLines(bool value) {
    setState(() => _wrapLines = value);
    LogViewerPreferences.save(showTimestamp: _showTimestamp, wrapLines: value);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchController.clear();
        _currentMatchIndex = 0;
      }
    });
  }

  void _toggleSettings() {
    setState(() => _settingsOpen = !_settingsOpen);
  }

  void _onSearchChanged(String _) {
    setState(() => _currentMatchIndex = 0);
  }

  String get _plainText {
    final parts = <String>[];
    for (final block in widget.blocks) {
      for (final line in block.lines) {
        parts.add(formatLogPlainLine(line, showTimestamp: _showTimestamp));
      }
    }

    return parts.join('\n');
  }

  RegExp? _searchPattern() {
    final query = _searchController.text;
    if (query.isEmpty) {
      return null;
    }

    try {
      if (_regexEnabled) {
        return RegExp(query);
      }

      return RegExp(RegExp.escape(query), caseSensitive: false);
    } catch (_) {
      return null;
    }
  }

  List<_LogMatch> _findMatches() {
    final pattern = _searchPattern();
    if (pattern == null) {
      return const [];
    }

    final matches = <_LogMatch>[];
    var lineIndex = 0;
    for (final block in widget.blocks) {
      for (final line in block.lines) {
        for (final match in pattern.allMatches(line.text)) {
          matches.add(_LogMatch(lineIndex: lineIndex, start: match.start, end: match.end));
        }
        lineIndex++;
      }
    }

    return matches;
  }

  void _goToMatch(int direction, List<_LogMatch> matches) {
    if (matches.isEmpty) {
      return;
    }

    setState(() {
      _currentMatchIndex = (_currentMatchIndex + direction) % matches.length;
      if (_currentMatchIndex < 0) {
        _currentMatchIndex = matches.length - 1;
      }
    });

    final match = matches[_currentMatchIndex];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.scrollController.hasClients) {
        return;
      }

      final target = match.lineIndex * 22.0;
      widget.scrollController.animateTo(
        target.clamp(0, widget.scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: _plainText));
  }

  int _lineOffsetForBlock(int blockIndex) {
    var offset = 0;
    for (var index = 0; index < blockIndex; index++) {
      offset += widget.blocks[index].lines.length;
    }

    return offset;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final matches = _searchOpen ? _findMatches() : const <_LogMatch>[];
    if (matches.isNotEmpty && _currentMatchIndex >= matches.length) {
      _currentMatchIndex = 0;
    }

    final emptyMessage = widget.runningCount == 0 ? 'No running containers in this stack.' : null;

    return _LogsViewerChrome(
      theme: theme,
      searchOpen: _searchOpen,
      settingsOpen: _settingsOpen,
      regexEnabled: _regexEnabled,
      searchController: _searchController,
      onToggleSearch: _toggleSearch,
      onToggleSettings: _toggleSettings,
      onSearchChanged: _onSearchChanged,
      onRegexChanged: (value) => setState(() {
        _regexEnabled = value;
        _currentMatchIndex = 0;
      }),
      onPreviousMatch: matches.isEmpty ? null : () => _goToMatch(-1, matches),
      onNextMatch: matches.isEmpty ? null : () => _goToMatch(1, matches),
      onCopy: _copyToClipboard,
      onClear: widget.onClear,
      showTimestamp: _showTimestamp,
      wrapLines: _wrapLines,
      onShowTimestampChanged: _setShowTimestamp,
      onWrapLinesChanged: _setWrapLines,
      scrollController: widget.scrollController,
      scrollableContent: emptyMessage != null
          ? Align(
              alignment: Alignment.topLeft,
              child: Text(emptyMessage, style: theme.textTheme.muted),
            )
          : widget.blocks.isEmpty
              ? const SizedBox.shrink()
              : ListView.builder(
                  controller: widget.scrollController,
                  itemCount: widget.blocks.length,
                  itemBuilder: (context, index) {
                    final block = widget.blocks[index];
                    final lineOffset = _lineOffsetForBlock(index);

                    return Padding(
                      padding: EdgeInsets.only(bottom: index == widget.blocks.length - 1 ? 0 : 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 96,
                            child: Text(
                              block.containerName,
                              style: theme.textTheme.small.copyWith(
                                color: block.color,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Expanded(
                            child: IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Container(
                                    width: 3,
                                    margin: const EdgeInsets.symmetric(horizontal: 8),
                                    decoration: BoxDecoration(
                                      color: block.color,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  Expanded(
                                    child: _LogTextView(
                                      theme: theme,
                                      logLines: block.lines,
                                      showTimestamp: _showTimestamp,
                                      wrapLines: _wrapLines,
                                      matches: matches,
                                      currentMatchIndex: _currentMatchIndex,
                                      lineOffset: lineOffset,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
      primaryListView: emptyMessage == null && widget.blocks.isNotEmpty,
    );
  }
}

class _LogMatch {
  const _LogMatch({
    required this.lineIndex,
    required this.start,
    required this.end,
  });

  final int lineIndex;
  final int start;
  final int end;
}

class _LogsViewerChrome extends StatelessWidget {
  const _LogsViewerChrome({
    required this.theme,
    required this.searchOpen,
    required this.settingsOpen,
    required this.regexEnabled,
    required this.searchController,
    required this.onToggleSearch,
    required this.onToggleSettings,
    required this.onSearchChanged,
    required this.onRegexChanged,
    required this.onPreviousMatch,
    required this.onNextMatch,
    required this.onCopy,
    required this.onClear,
    required this.showTimestamp,
    required this.wrapLines,
    required this.onShowTimestampChanged,
    required this.onWrapLinesChanged,
    required this.scrollController,
    required this.scrollableContent,
    this.primaryListView = false,
    this.showSettings = true,
  });

  final ShadThemeData theme;
  final bool searchOpen;
  final bool settingsOpen;
  final bool regexEnabled;
  final TextEditingController searchController;
  final VoidCallback onToggleSearch;
  final VoidCallback onToggleSettings;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<bool> onRegexChanged;
  final VoidCallback? onPreviousMatch;
  final VoidCallback? onNextMatch;
  final Future<void> Function() onCopy;
  final VoidCallback onClear;
  final bool showTimestamp;
  final bool wrapLines;
  final ValueChanged<bool> onShowTimestampChanged;
  final ValueChanged<bool> onWrapLinesChanged;
  final ScrollController scrollController;
  final Widget scrollableContent;
  final bool primaryListView;
  final bool showSettings;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.border),
                  borderRadius: theme.radius,
                  color: logsPanelBackground(theme),
                ),
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (searchOpen) ...[
                      _LogsSearchBar(
                        theme: theme,
                        controller: searchController,
                        regexEnabled: regexEnabled,
                        onChanged: onSearchChanged,
                        onRegexChanged: onRegexChanged,
                        onPreviousMatch: onPreviousMatch,
                        onNextMatch: onNextMatch,
                        onClose: onToggleSearch,
                      ),
                      const SizedBox(height: 8),
                    ],
                    Expanded(
                      child: primaryListView
                          ? scrollableContent
                          : SingleChildScrollView(
                              controller: scrollController,
                              child: scrollableContent,
                            ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            _LogsToolbar(
              theme: theme,
              searchOpen: searchOpen,
              settingsOpen: settingsOpen,
              onToggleSearch: onToggleSearch,
              onToggleSettings: onToggleSettings,
              onCopy: onCopy,
              onClear: onClear,
              showSettings: showSettings,
            ),
          ],
        ),
        if (showSettings && settingsOpen)
          Positioned(
            right: 40,
            top: 40,
            child: _LogsSettingsPopover(
              theme: theme,
              showTimestamp: showTimestamp,
              wrapLines: wrapLines,
              onShowTimestampChanged: onShowTimestampChanged,
              onWrapLinesChanged: onWrapLinesChanged,
            ),
          ),
      ],
    );
  }
}

class _LogsSearchBar extends StatelessWidget {
  const _LogsSearchBar({
    required this.theme,
    required this.controller,
    required this.regexEnabled,
    required this.onChanged,
    required this.onRegexChanged,
    required this.onPreviousMatch,
    required this.onNextMatch,
    required this.onClose,
  });

  final ShadThemeData theme;
  final TextEditingController controller;
  final bool regexEnabled;
  final ValueChanged<String> onChanged;
  final ValueChanged<bool> onRegexChanged;
  final VoidCallback? onPreviousMatch;
  final VoidCallback? onNextMatch;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ShadInput(
            controller: controller,
            placeholder: const Text('Search...'),
            onChanged: onChanged,
            leading: Icon(LucideIcons.search, size: 16, color: theme.colorScheme.mutedForeground),
          ),
        ),
        const SizedBox(width: 8),
        CalfButton.outline(
          width: 40,
          height: 36,
          padding: EdgeInsets.zero,
          backgroundColor: regexEnabled ? theme.colorScheme.primary : null,
          onPressed: () => onRegexChanged(!regexEnabled),
          child: Text(
            'Reg',
            style: theme.textTheme.small.copyWith(
              fontWeight: FontWeight.w600,
              color: regexEnabled
                  ? theme.colorScheme.primaryForeground
                  : theme.colorScheme.mutedForeground,
            ),
          ),
        ),
        const SizedBox(width: 4),
        _LogsSearchNavButton(
          theme: theme,
          icon: LucideIcons.chevronLeft,
          enabled: onPreviousMatch != null,
          onPressed: onPreviousMatch,
        ),
        _LogsSearchNavButton(
          theme: theme,
          icon: LucideIcons.chevronRight,
          enabled: onNextMatch != null,
          onPressed: onNextMatch,
        ),
        const SizedBox(width: 4),
        CalfButton.ghost(
          width: 36,
          height: 36,
          padding: EdgeInsets.zero,
          onPressed: onClose,
          child: Icon(LucideIcons.x, size: 16, color: theme.colorScheme.primary),
        ),
      ],
    );
  }
}

class _LogsSearchNavButton extends StatelessWidget {
  const _LogsSearchNavButton({
    required this.theme,
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final ShadThemeData theme;
  final IconData icon;
  final bool enabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return CalfButton.ghost(
      enabled: enabled,
      width: 32,
      height: 36,
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      child: Icon(
        icon,
        size: 16,
        color: enabled ? theme.colorScheme.foreground : theme.colorScheme.mutedForeground,
      ),
    );
  }
}

class _LogsToolbar extends StatelessWidget {
  const _LogsToolbar({
    required this.theme,
    required this.searchOpen,
    required this.settingsOpen,
    required this.onToggleSearch,
    required this.onToggleSettings,
    required this.onCopy,
    required this.onClear,
    this.showSettings = true,
  });

  final ShadThemeData theme;
  final bool searchOpen;
  final bool settingsOpen;
  final VoidCallback onToggleSearch;
  final VoidCallback onToggleSettings;
  final Future<void> Function() onCopy;
  final VoidCallback onClear;
  final bool showSettings;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      child: Column(
        children: [
          _LogsToolbarButton(
            theme: theme,
            icon: LucideIcons.search,
            tooltip: 'Search',
            selected: searchOpen,
            onPressed: onToggleSearch,
          ),
          if (showSettings)
            _LogsToolbarButton(
              theme: theme,
              icon: LucideIcons.slidersHorizontal,
              tooltip: 'Settings',
              selected: settingsOpen,
              onPressed: onToggleSettings,
            ),
          _LogsToolbarButton(
            theme: theme,
            icon: LucideIcons.copy,
            tooltip: 'Copy to clipboard',
            onPressed: () => onCopy(),
          ),
          _LogsToolbarButton(
            theme: theme,
            icon: LucideIcons.eraser,
            tooltip: 'Clear terminal',
            onPressed: onClear,
          ),
        ],
      ),
    );
  }
}

class _LogsToolbarButton extends StatelessWidget {
  const _LogsToolbarButton({
    required this.theme,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  final ShadThemeData theme;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Tooltip(
        message: tooltip,
        child: CalfButton.ghost(
          width: 36,
          height: 36,
          padding: EdgeInsets.zero,
          backgroundColor: selected ? theme.colorScheme.muted : null,
          onPressed: onPressed,
          child: Icon(icon, size: 16, color: theme.colorScheme.primary),
        ),
      ),
    );
  }
}

class _LogsSettingsPopover extends StatelessWidget {
  const _LogsSettingsPopover({
    required this.theme,
    required this.showTimestamp,
    required this.wrapLines,
    required this.onShowTimestampChanged,
    required this.onWrapLinesChanged,
  });

  final ShadThemeData theme;
  final bool showTimestamp;
  final bool wrapLines;
  final ValueChanged<bool> onShowTimestampChanged;
  final ValueChanged<bool> onWrapLinesChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.background,
        border: Border.all(color: theme.colorScheme.border),
        borderRadius: theme.radius,
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LogsSettingRow(
            theme: theme,
            label: 'Show Timestamp',
            value: showTimestamp,
            onChanged: onShowTimestampChanged,
          ),
          const SizedBox(height: 8),
          _LogsSettingRow(
            theme: theme,
            label: 'Wrap lines',
            value: wrapLines,
            onChanged: onWrapLinesChanged,
          ),
        ],
      ),
    );
  }
}

class _LogsSettingRow extends StatelessWidget {
  const _LogsSettingRow({
    required this.theme,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final ShadThemeData theme;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: theme.textTheme.small)),
        ShadSwitch(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _LogTextView extends StatelessWidget {
  const _LogTextView({
    required this.theme,
    required this.logLines,
    required this.showTimestamp,
    required this.wrapLines,
    required this.matches,
    required this.currentMatchIndex,
    this.lineOffset = 0,
  });

  final ShadThemeData theme;
  final List<LogLine> logLines;
  final bool showTimestamp;
  final bool wrapLines;
  final List<_LogMatch> matches;
  final int currentMatchIndex;
  final int lineOffset;

  @override
  Widget build(BuildContext context) {
    final baseStyle = theme.textTheme.small.copyWith(fontFamily: 'Menlo');
    final timestampStyle = baseStyle.copyWith(color: theme.colorScheme.mutedForeground);

    final column = Column(
      crossAxisAlignment: wrapLines ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < logLines.length; index++)
          _LogLineRow(
            theme: theme,
            timestamp: showTimestamp ? formatLogTimestamp(logLines[index].receivedAt) : null,
            text: logLines[index].text,
            lineIndex: lineOffset + index,
            baseStyle: baseStyle,
            timestampStyle: timestampStyle,
            wrapLines: wrapLines,
            matches: matches,
            currentMatchIndex: currentMatchIndex,
          ),
      ],
    );

    if (wrapLines) {
      return column;
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: column,
    );
  }
}

class _LogLineRow extends StatefulWidget {
  const _LogLineRow({
    required this.theme,
    required this.timestamp,
    required this.text,
    required this.lineIndex,
    required this.baseStyle,
    required this.timestampStyle,
    required this.wrapLines,
    required this.matches,
    required this.currentMatchIndex,
  });

  final ShadThemeData theme;
  final String? timestamp;
  final String text;
  final int lineIndex;
  final TextStyle baseStyle;
  final TextStyle timestampStyle;
  final bool wrapLines;
  final List<_LogMatch> matches;
  final int currentMatchIndex;

  @override
  State<_LogLineRow> createState() => _LogLineRowState();
}

class _LogLineRowState extends State<_LogLineRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final span = TextSpan(
      style: widget.baseStyle,
      children: _lineSpans(
        theme: widget.theme,
        line: widget.text,
        lineIndex: widget.lineIndex,
        baseStyle: widget.baseStyle,
      ),
    );

    final content = widget.wrapLines
        ? SelectableText.rich(span)
        : SelectionArea(
            child: Text.rich(
              span,
              softWrap: false,
              maxLines: 1,
            ),
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        color: _hovered ? widget.theme.colorScheme.muted.withValues(alpha: 1) : null,
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: widget.wrapLines ? MainAxisSize.max : MainAxisSize.min,
          children: [
            if (widget.timestamp != null)
              SizedBox(
                width: _logTimestampColumnWidth,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(widget.timestamp!, style: widget.timestampStyle),
                ),
              ),
            if (widget.wrapLines) Expanded(child: content) else content,
          ],
        ),
      ),
    );
  }

  List<InlineSpan> _lineSpans({
    required ShadThemeData theme,
    required String line,
    required int lineIndex,
    required TextStyle baseStyle,
  }) {
    final lineMatches = widget.matches.where((match) => match.lineIndex == lineIndex).toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    if (lineMatches.isEmpty) {
      return [TextSpan(text: line)];
    }

    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in lineMatches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: line.substring(cursor, match.start)));
      }

      final globalIndex = widget.matches.indexOf(match);
      final isCurrent = globalIndex == widget.currentMatchIndex;
      spans.add(
        TextSpan(
          text: line.substring(match.start, match.end),
          style: baseStyle.copyWith(
            backgroundColor: isCurrent
                ? theme.colorScheme.primary.withValues(alpha: 0.45)
                : theme.colorScheme.primary.withValues(alpha: 0.2),
          ),
        ),
      );
      cursor = match.end;
    }

    if (cursor < line.length) {
      spans.add(TextSpan(text: line.substring(cursor)));
    }

    return spans;
  }
}

class ExecPanel extends StatefulWidget {
  const ExecPanel({
    super.key,
    required this.terminal,
    required this.terminalTheme,
    required this.keyboardAppearance,
  });

  final Terminal terminal;
  final TerminalTheme terminalTheme;
  final Brightness keyboardAppearance;

  @override
  State<ExecPanel> createState() => _ExecPanelState();
}

class _ExecPanelState extends State<ExecPanel> {
  final _controller = TerminalController();
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  bool _searchOpen = false;
  bool _regexEnabled = false;
  int _currentMatchIndex = 0;
  final _searchHighlights = <TerminalHighlight>[];

  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_onTerminalChanged);
  }

  @override
  void didUpdateWidget(covariant ExecPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalChanged);
      widget.terminal.addListener(_onTerminalChanged);
      _clearSearchHighlights();
      _refreshSearchHighlights();
    }
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_onTerminalChanged);
    _clearSearchHighlights();
    _searchController.dispose();
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onTerminalChanged() {
    if (!_searchOpen || _searchController.text.isEmpty) {
      return;
    }

    _refreshSearchHighlights();
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchController.clear();
        _currentMatchIndex = 0;
        _clearSearchHighlights();
      } else {
        _refreshSearchHighlights();
      }
    });
  }

  void _onSearchChanged(String _) {
    setState(() {
      _currentMatchIndex = 0;
      _refreshSearchHighlights();
    });
  }

  RegExp? _searchPattern() {
    final query = _searchController.text;
    if (query.isEmpty) {
      return null;
    }

    try {
      if (_regexEnabled) {
        return RegExp(query);
      }

      return RegExp(RegExp.escape(query), caseSensitive: false);
    } catch (_) {
      return null;
    }
  }

  List<_TerminalMatch> _findMatches() {
    final pattern = _searchPattern();
    if (pattern == null) {
      return const [];
    }

    final matches = <_TerminalMatch>[];
    final lineCount = widget.terminal.buffer.lines.length;
    for (var lineIndex = 0; lineIndex < lineCount; lineIndex++) {
      final lineText = widget.terminal.buffer.lines[lineIndex].getText();
      for (final match in pattern.allMatches(lineText)) {
        if (match.end <= match.start) {
          continue;
        }

        matches.add(
          _TerminalMatch(
            start: CellOffset(match.start, lineIndex),
            end: CellOffset(match.end - 1, lineIndex),
          ),
        );
      }
    }

    return matches;
  }

  void _clearSearchHighlights() {
    for (final highlight in _searchHighlights) {
      highlight.dispose();
    }
    _searchHighlights.clear();
  }

  void _refreshSearchHighlights() {
    _clearSearchHighlights();

    if (!_searchOpen) {
      return;
    }

    final matches = _findMatches();
    if (matches.isEmpty) {
      if (mounted) {
        setState(() => _currentMatchIndex = 0);
      }
      return;
    }

    if (_currentMatchIndex >= matches.length) {
      _currentMatchIndex = 0;
    }

    for (var index = 0; index < matches.length; index++) {
      final match = matches[index];
      final isCurrent = index == _currentMatchIndex;
      _searchHighlights.add(
        _controller.highlight(
          p1: widget.terminal.buffer.createAnchorFromOffset(match.start),
          p2: widget.terminal.buffer.createAnchorFromOffset(match.end),
          color: isCurrent
              ? widget.terminalTheme.searchHitBackgroundCurrent
              : widget.terminalTheme.searchHitBackground,
        ),
      );
    }

    if (mounted) {
      setState(() {});
    }
  }

  void _goToMatch(int direction) {
    final matches = _findMatches();
    if (matches.isEmpty) {
      return;
    }

    setState(() {
      _currentMatchIndex = (_currentMatchIndex + direction) % matches.length;
      if (_currentMatchIndex < 0) {
        _currentMatchIndex = matches.length - 1;
      }
      _refreshSearchHighlights();
    });

    final match = matches[_currentMatchIndex];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }

      final target = match.start.y * 18.0;
      _scrollController.animateTo(
        target.clamp(0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _copyToClipboard() async {
    final selection = _controller.selection;
    final text = selection == null
        ? _terminalTextForCopy()
        : widget.terminal.buffer.getText(selection);

    await Clipboard.setData(ClipboardData(text: text));
  }

  String _terminalTextForCopy() {
    final buffer = widget.terminal.buffer;
    var lastLine = buffer.height - 1;
    while (lastLine >= 0) {
      final line = buffer.lines[lastLine];
      if (line.getText().isNotEmpty || line.isWrapped) {
        break;
      }
      lastLine--;
    }

    if (lastLine < 0) {
      return '';
    }

    return buffer.getText(
      BufferRangeLine(
        CellOffset(0, 0),
        CellOffset(buffer.viewWidth - 1, lastLine),
      ),
    );
  }

  void _clearTerminal() {
    final terminal = widget.terminal;
    final buffer = terminal.buffer;
    final inputLine = buffer.currentLine.getText();
    final inputCursorX = buffer.cursorX;

    buffer.clear();
    buffer.setCursor(0, 0);
    if (inputLine.isNotEmpty) {
      buffer.write(inputLine);
    }
    buffer.setCursor(inputCursorX.clamp(0, buffer.viewWidth - 1), 0);

    _controller.clearSelection();
    _clearSearchHighlights();
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    terminal.notifyListeners();
    setState(() {
      _currentMatchIndex = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final matches = _searchOpen ? _findMatches() : const <_TerminalMatch>[];

    return _LogsViewerChrome(
      theme: theme,
      searchOpen: _searchOpen,
      settingsOpen: false,
      regexEnabled: _regexEnabled,
      searchController: _searchController,
      onToggleSearch: _toggleSearch,
      onToggleSettings: () {},
      onSearchChanged: _onSearchChanged,
      onRegexChanged: (value) => setState(() {
        _regexEnabled = value;
        _currentMatchIndex = 0;
        _refreshSearchHighlights();
      }),
      onPreviousMatch: matches.isEmpty ? null : () => _goToMatch(-1),
      onNextMatch: matches.isEmpty ? null : () => _goToMatch(1),
      onCopy: _copyToClipboard,
      onClear: _clearTerminal,
      showTimestamp: false,
      wrapLines: true,
      onShowTimestampChanged: (_) {},
      onWrapLinesChanged: (_) {},
      scrollController: _scrollController,
      showSettings: false,
      scrollableContent: TerminalView(
        widget.terminal,
        controller: _controller,
        theme: widget.terminalTheme,
        backgroundOpacity: 0,
        keyboardAppearance: widget.keyboardAppearance,
        scrollController: _scrollController,
        autofocus: true,
      ),
      primaryListView: true,
    );
  }
}

class _TerminalMatch {
  const _TerminalMatch({
    required this.start,
    required this.end,
  });

  final CellOffset start;
  final CellOffset end;
}
