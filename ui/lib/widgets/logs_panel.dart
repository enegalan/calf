import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'package:ui/storage/logs_viewer_preferences.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/theme/calf_theme.dart';

class LogLine {
  /// A single log line with its receive timestamp.
  const LogLine({required this.text, required this.receivedAt});

  final String text;
  final DateTime receivedAt;
}

class MixedLogBlock {
  /// A color-coded block of log lines from one container in a compose stack.
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

  /// Returns a copy of this block with an optional new [lines] list.
  MixedLogBlock copyWith({List<LogLine>? lines}) {
    return MixedLogBlock(
      containerId: containerId,
      containerName: containerName,
      color: color,
      lines: lines ?? this.lines,
    );
  }
}

/// Returns the muted background color used by log panels.
Color logsPanelBackground(ThemeData theme) {
  return Color.alphaBlend(
    theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
    theme.colorScheme.surface,
  );
}

const double _logTimestampColumnWidth = 184;
const double _logRowMinContentWidth = 40;

/// Formats [receivedAt] as a local `YYYY-MM-DD HH:MM:SS` string.
String formatLogTimestamp(DateTime receivedAt) {
  final local = receivedAt.toLocal();

  /// Pads a number to two digits for timestamp formatting.
  String two(int value) => value.toString().padLeft(2, '0');

  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// Formats a [LogLine] with an optional leading timestamp.
String formatLogPlainLine(LogLine line, {required bool showTimestamp}) {
  if (!showTimestamp) {
    return line.text;
  }

  return '${formatLogTimestamp(line.receivedAt)} ${line.text}';
}

class LogsPanel extends StatefulWidget {
  /// Scrollable log viewer for a single container with search and settings.
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

  /// Creates the state for this single-container log panel.
  @override
  State<LogsPanel> createState() => _LogsPanelState();
}

class _LogsPanelState extends State<LogsPanel>
    with LogViewerPreferencesMixin, _LogsSearchMixin {
  @override
  ScrollController get logsScrollController => widget.scrollController;

  @override
  double get logsMatchLineHeight => 18.0;

  /// Loads persisted log viewer preferences.
  @override
  void initState() {
    super.initState();
    initLogViewerPreferences();
  }

  /// Disposes controllers and listeners owned by this state.
  @override
  void dispose() {
    disposeLogsSearch();
    super.dispose();
  }

  /// Plain-text representation of visible log lines for copy and search.
  String get _plainText {
    if (widget.error != null) {
      return widget.error!;
    }

    return widget.lines
        .map((line) => formatLogPlainLine(line, showTimestamp: showTimestamp))
        .join('\n');
  }

  @override
  List<_LogMatch> findLogMatches() {
    return _findLogMatchesInLines(widget.lines, searchPattern());
  }

  /// Copies the visible log text to the clipboard.
  Future<void> _copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: _plainText));
  }

  /// Builds the single-container log viewer UI.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = activeMatches();
    syncMatchIndex(matches);

    return _LogsViewerChrome(
      theme: theme,
      searchOpen: searchOpen,
      settingsOpen: settingsOpen,
      regexEnabled: regexEnabled,
      searchController: searchController,
      onToggleSearch: toggleSearch,
      onToggleSettings: toggleSettings,
      onSearchChanged: onSearchChanged,
      onRegexChanged: onRegexChanged,
      onPreviousMatch: matches.isEmpty ? null : () => goToMatch(-1, matches),
      onNextMatch: matches.isEmpty ? null : () => goToMatch(1, matches),
      onCopy: _copyToClipboard,
      onClear: widget.onClear,
      showTimestamp: showTimestamp,
      wrapLines: wrapLines,
      onShowTimestampChanged: setLogViewerShowTimestamp,
      onWrapLinesChanged: setLogViewerWrapLines,
      scrollController: widget.scrollController,
      scrollableContent: widget.error != null
          ? SelectableText(
              widget.error!,
              style: theme.textTheme.bodySmall!.copyWith(
                fontFamily: 'Menlo',
                color: theme.colorScheme.error,
              ),
            )
          : widget.lines.isEmpty
          ? const SizedBox.shrink()
          : _LogTextView(
              theme: theme,
              logLines: widget.lines,
              showTimestamp: showTimestamp,
              wrapLines: wrapLines,
              matches: matches,
              currentMatchIndex: displayMatchIndex(matches),
              scrollController: widget.scrollController,
            ),
      primaryListView:
          widget.error == null && widget.lines.isNotEmpty && wrapLines,
    );
  }
}

class MixedLogsPanel extends StatefulWidget {
  /// Log viewer that merges color-coded blocks from multiple containers.
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

  /// Creates the state for this multi-container log panel.
  @override
  State<MixedLogsPanel> createState() => _MixedLogsPanelState();
}

class _MixedLogsPanelState extends State<MixedLogsPanel>
    with LogViewerPreferencesMixin, _LogsSearchMixin {
  @override
  ScrollController get logsScrollController => widget.scrollController;

  @override
  double get logsMatchLineHeight => 22.0;

  /// Loads persisted log viewer preferences.
  @override
  void initState() {
    super.initState();
    initLogViewerPreferences();
  }

  /// Disposes controllers and listeners owned by this state.
  @override
  void dispose() {
    disposeLogsSearch();
    super.dispose();
  }

  /// Plain-text representation of visible log lines for copy and search.
  String get _plainText {
    final parts = <String>[];
    for (final block in widget.blocks) {
      for (final line in block.lines) {
        parts.add(formatLogPlainLine(line, showTimestamp: showTimestamp));
      }
    }

    return parts.join('\n');
  }

  @override
  List<_LogMatch> findLogMatches() {
    final lines = <LogLine>[];
    for (final block in widget.blocks) {
      lines.addAll(block.lines);
    }

    return _findLogMatchesInLines(lines, searchPattern());
  }

  /// Copies the visible log text to the clipboard.
  Future<void> _copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: _plainText));
  }

  /// Returns the global line index offset for [blockIndex].
  int _lineOffsetForBlock(int blockIndex) {
    var offset = 0;
    for (var index = 0; index < blockIndex; index++) {
      offset += widget.blocks[index].lines.length;
    }

    return offset;
  }

  /// Builds the multi-container log viewer UI.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = activeMatches();
    syncMatchIndex(matches);
    final displayIndex = displayMatchIndex(matches);

    final emptyMessage = widget.runningCount == 0 ? '' : null;

    return _LogsViewerChrome(
      theme: theme,
      searchOpen: searchOpen,
      settingsOpen: settingsOpen,
      regexEnabled: regexEnabled,
      searchController: searchController,
      onToggleSearch: toggleSearch,
      onToggleSettings: toggleSettings,
      onSearchChanged: onSearchChanged,
      onRegexChanged: onRegexChanged,
      onPreviousMatch: matches.isEmpty ? null : () => goToMatch(-1, matches),
      onNextMatch: matches.isEmpty ? null : () => goToMatch(1, matches),
      onCopy: _copyToClipboard,
      onClear: widget.onClear,
      showTimestamp: showTimestamp,
      wrapLines: wrapLines,
      onShowTimestampChanged: setLogViewerShowTimestamp,
      onWrapLinesChanged: setLogViewerWrapLines,
      scrollController: widget.scrollController,
      scrollableContent: emptyMessage != null
          ? Align(
              alignment: Alignment.topLeft,
              child: Text(emptyMessage, style: CalfTheme.muted(theme)),
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
                  padding: EdgeInsets.only(
                    bottom: index == widget.blocks.length - 1 ? 0 : 12,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 96,
                        child: Text(
                          block.containerName,
                          style: theme.textTheme.bodySmall!.copyWith(
                            color: block.color,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Expanded(
                        child: Stack(
                          children: [
                            Positioned(
                              left: 8,
                              top: 0,
                              bottom: 0,
                              child: Container(
                                width: 3,
                                decoration: BoxDecoration(
                                  color: block.color,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 19),
                              child: _LogTextView(
                                theme: theme,
                                logLines: block.lines,
                                showTimestamp: showTimestamp,
                                wrapLines: wrapLines,
                                matches: matches,
                                currentMatchIndex: displayIndex,
                                lineOffset: lineOffset,
                              ),
                            ),
                          ],
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
  /// A character-range match within one log line.
  const _LogMatch({
    required this.lineIndex,
    required this.start,
    required this.end,
  });

  final int lineIndex;
  final int start;
  final int end;
}

/// Finds all [pattern] matches across [lines].
List<_LogMatch> _findLogMatchesInLines(List<LogLine> lines, RegExp? pattern) {
  if (pattern == null) {
    return const [];
  }

  final matches = <_LogMatch>[];
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    for (final match in pattern.allMatches(lines[lineIndex].text)) {
      matches.add(
        _LogMatch(lineIndex: lineIndex, start: match.start, end: match.end),
      );
    }
  }

  return matches;
}

/// Shared search state and navigation for single- and mixed-log panels.
mixin _LogsSearchMixin<T extends StatefulWidget> on State<T> {
  final TextEditingController searchController = TextEditingController();
  bool searchOpen = false;
  bool regexEnabled = false;
  bool settingsOpen = false;
  int currentMatchIndex = 0;

  /// Scroll controller used to bring the active match into view.
  ScrollController get logsScrollController;

  /// Estimated row height for scroll-to-match calculations.
  double get logsMatchLineHeight;

  /// Returns all search matches in the current log content.
  List<_LogMatch> findLogMatches();

  /// Disposes the search controller; call from [State.dispose].
  void disposeLogsSearch() {
    searchController.dispose();
  }

  /// Toggles the search bar open or closed.
  void toggleSearch() {
    setState(() {
      searchOpen = !searchOpen;
      if (!searchOpen) {
        searchController.clear();
        currentMatchIndex = 0;
      }
    });
  }

  /// Toggles the settings popover open or closed.
  void toggleSettings() {
    setState(() => settingsOpen = !settingsOpen);
  }

  /// Resets the current match index when the search query changes.
  void onSearchChanged(String _) {
    setState(() => currentMatchIndex = 0);
  }

  /// Resets the current match index when the regex toggle changes.
  void onRegexChanged(bool value) {
    setState(() {
      regexEnabled = value;
      currentMatchIndex = 0;
    });
  }

  /// Builds the current search [RegExp], or null when search is inactive.
  RegExp? searchPattern() {
    final query = searchController.text;
    if (query.isEmpty) {
      return null;
    }

    try {
      if (regexEnabled) {
        return RegExp(query);
      }

      return RegExp(RegExp.escape(query), caseSensitive: false);
    } catch (_) {
      return null;
    }
  }

  /// Returns active matches when search is open, otherwise an empty list.
  List<_LogMatch> activeMatches() {
    if (!searchOpen) {
      return const [];
    }

    return findLogMatches();
  }

  /// Schedules a post-frame [setState] when [currentMatchIndex] is out of range.
  void syncMatchIndex(List<_LogMatch> matches) {
    if (matches.isEmpty) {
      if (currentMatchIndex != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() => currentMatchIndex = 0);
          }
        });
      }
      return;
    }

    if (currentMatchIndex >= matches.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => currentMatchIndex = 0);
        }
      });
    }
  }

  /// Returns a clamped match index safe for the current frame's [matches].
  int displayMatchIndex(List<_LogMatch> matches) {
    if (matches.isEmpty) {
      return 0;
    }

    return math.min(currentMatchIndex, matches.length - 1);
  }

  /// Moves to the previous or next search match and scrolls it into view.
  void goToMatch(int direction, List<_LogMatch> matches) {
    if (matches.isEmpty) {
      return;
    }

    setState(() {
      currentMatchIndex = (currentMatchIndex + direction) % matches.length;
      if (currentMatchIndex < 0) {
        currentMatchIndex = matches.length - 1;
      }
    });

    final match = matches[currentMatchIndex];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!logsScrollController.hasClients) {
        return;
      }

      final target = match.lineIndex * logsMatchLineHeight;
      logsScrollController.animateTo(
        target.clamp(0, logsScrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }
}

class _LogsViewerChrome extends StatelessWidget {
  /// Shared chrome with search bar, toolbar, and scrollable log content.
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

  final ThemeData theme;
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

  /// Builds the bordered log area, toolbar, and optional settings popover.
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
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                  borderRadius: CalfTheme.radius,
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
  /// Search input with regex toggle and match navigation controls.
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

  final ThemeData theme;
  final TextEditingController controller;
  final bool regexEnabled;
  final ValueChanged<String> onChanged;
  final ValueChanged<bool> onRegexChanged;
  final VoidCallback? onPreviousMatch;
  final VoidCallback? onNextMatch;
  final VoidCallback onClose;

  /// Builds the search input row with regex and navigation buttons.
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            decoration: InputDecoration(
              hintText: 'Search...',
              prefixIcon: Icon(
                LucideIcons.search,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
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
            style: theme.textTheme.bodySmall!.copyWith(
              fontWeight: FontWeight.w600,
              color: regexEnabled
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.onSurfaceVariant,
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
          child: Icon(
            LucideIcons.x,
            size: 16,
            color: theme.colorScheme.primary,
          ),
        ),
      ],
    );
  }
}

class _LogsSearchNavButton extends StatelessWidget {
  /// Previous/next chevron button for stepping through search matches.
  const _LogsSearchNavButton({
    required this.theme,
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final ThemeData theme;
  final IconData icon;
  final bool enabled;
  final VoidCallback? onPressed;

  /// Builds the enabled or disabled search navigation chevron button.
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
        color: enabled
            ? theme.colorScheme.onSurface
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _LogsToolbar extends StatelessWidget {
  /// Vertical toolbar with search, settings, copy, and clear actions.
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

  final ThemeData theme;
  final bool searchOpen;
  final bool settingsOpen;
  final VoidCallback onToggleSearch;
  final VoidCallback onToggleSettings;
  final Future<void> Function() onCopy;
  final VoidCallback onClear;
  final bool showSettings;

  /// Builds the vertical stack of log viewer action buttons.
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
  /// One icon button in the logs side toolbar.
  const _LogsToolbarButton({
    required this.theme,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  final ThemeData theme;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool selected;

  /// Builds one tooltip-wrapped toolbar icon button.
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
          backgroundColor: selected
              ? theme.colorScheme.surfaceContainerHighest
              : null,
          onPressed: onPressed,
          child: Icon(icon, size: 16, color: theme.colorScheme.primary),
        ),
      ),
    );
  }
}

class _LogsSettingsPopover extends StatelessWidget {
  /// Floating popover with timestamp and wrap-line toggles.
  const _LogsSettingsPopover({
    required this.theme,
    required this.showTimestamp,
    required this.wrapLines,
    required this.onShowTimestampChanged,
    required this.onWrapLinesChanged,
  });

  final ThemeData theme;
  final bool showTimestamp;
  final bool wrapLines;
  final ValueChanged<bool> onShowTimestampChanged;
  final ValueChanged<bool> onWrapLinesChanged;

  /// Builds the settings popover panel.
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: CalfTheme.radius,
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
  /// One labeled switch row inside the settings popover.
  const _LogsSettingRow({
    required this.theme,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final ThemeData theme;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// Builds a label and switch on one row.
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _LogTextView extends StatelessWidget {
  /// Renders log lines with optional timestamps, wrapping, and search highlights.
  const _LogTextView({
    required this.theme,
    required this.logLines,
    required this.showTimestamp,
    required this.wrapLines,
    required this.matches,
    required this.currentMatchIndex,
    this.lineOffset = 0,
    this.scrollController,
  });

  final ThemeData theme;
  final List<LogLine> logLines;
  final bool showTimestamp;
  final bool wrapLines;
  final List<_LogMatch> matches;
  final int currentMatchIndex;
  final int lineOffset;
  final ScrollController? scrollController;

  /// Builds one highlighted log line row at [index].
  Widget _buildLineRow(int index) {
    final baseStyle = theme.textTheme.bodySmall!.copyWith(fontFamily: 'Menlo');
    final timestampStyle = baseStyle.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return _LogLineRow(
      theme: theme,
      timestamp: showTimestamp
          ? formatLogTimestamp(logLines[index].receivedAt)
          : null,
      text: logLines[index].text,
      lineIndex: lineOffset + index,
      baseStyle: baseStyle,
      timestampStyle: timestampStyle,
      wrapLines: wrapLines,
      matches: matches,
      currentMatchIndex: currentMatchIndex,
    );
  }

  /// Builds the scrollable log text with wrapping and horizontal scroll.
  @override
  Widget build(BuildContext context) {
    if (wrapLines) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final viewportWidth = constraints.maxWidth;
          final listWidth = showTimestamp
              ? math.max(
                  viewportWidth,
                  _logTimestampColumnWidth + _logRowMinContentWidth,
                )
              : viewportWidth;

          final listView = ListView.builder(
            controller: scrollController,
            shrinkWrap: scrollController == null,
            physics: scrollController == null
                ? const NeverScrollableScrollPhysics()
                : null,
            itemCount: logLines.length,
            itemBuilder: (context, index) => _buildLineRow(index),
          );

          if (!showTimestamp || listWidth <= viewportWidth) {
            return SelectionArea(child: listView);
          }

          return SelectionArea(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: listWidth, child: listView),
            ),
          );
        },
      );
    }

    final baseStyle = theme.textTheme.bodySmall!.copyWith(fontFamily: 'Menlo');
    final timestampStyle = baseStyle.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return SelectionArea(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < logLines.length; index++)
              _LogLineRow(
                theme: theme,
                timestamp: showTimestamp
                    ? formatLogTimestamp(logLines[index].receivedAt)
                    : null,
                text: logLines[index].text,
                lineIndex: lineOffset + index,
                baseStyle: baseStyle,
                timestampStyle: timestampStyle,
                wrapLines: wrapLines,
                matches: matches,
                currentMatchIndex: currentMatchIndex,
              ),
          ],
        ),
      ),
    );
  }
}

class _LogLineRow extends StatefulWidget {
  /// One log line with optional timestamp column and search highlight spans.
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

  final ThemeData theme;
  final String? timestamp;
  final String text;
  final int lineIndex;
  final TextStyle baseStyle;
  final TextStyle timestampStyle;
  final bool wrapLines;
  final List<_LogMatch> matches;
  final int currentMatchIndex;

  /// Creates the state for a single log line row.
  @override
  State<_LogLineRow> createState() => _LogLineRowState();
}

class _LogLineRowState extends State<_LogLineRow> {
  bool _hovered = false;

  /// Builds the hoverable log line with timestamp and highlighted matches.
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

    final content = Text.rich(
      span,
      softWrap: widget.wrapLines,
      maxLines: widget.wrapLines ? null : 1,
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        color: _hovered
            ? widget.theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 1,
              )
            : null,
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

  /// Builds rich text spans for [line] with search match highlighting.
  List<InlineSpan> _lineSpans({
    required ThemeData theme,
    required String line,
    required int lineIndex,
    required TextStyle baseStyle,
  }) {
    final lineMatches = <MapEntry<int, _LogMatch>>[];
    for (
      var globalIndex = 0;
      globalIndex < widget.matches.length;
      globalIndex++
    ) {
      final match = widget.matches[globalIndex];
      if (match.lineIndex == lineIndex) {
        lineMatches.add(MapEntry(globalIndex, match));
      }
    }
    lineMatches.sort((a, b) => a.value.start.compareTo(b.value.start));

    if (lineMatches.isEmpty) {
      return [TextSpan(text: line)];
    }

    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final entry in lineMatches) {
      final match = entry.value;
      if (match.start > cursor) {
        spans.add(TextSpan(text: line.substring(cursor, match.start)));
      }

      final isCurrent = entry.key == widget.currentMatchIndex;
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
  /// Interactive terminal panel with search, copy, and clear controls.
  const ExecPanel({
    super.key,
    required this.terminal,
    required this.terminalTheme,
    required this.keyboardAppearance,
  });

  final Terminal terminal;
  final TerminalTheme terminalTheme;
  final Brightness keyboardAppearance;

  /// Creates the state for the exec terminal panel.
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

  /// Attaches a terminal change listener when the panel is created.
  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_onTerminalChanged);
  }

  /// Rebinds listeners when the terminal instance changes.
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

  /// Disposes controllers and listeners owned by this state.
  @override
  void dispose() {
    widget.terminal.removeListener(_onTerminalChanged);
    _clearSearchHighlights();
    _searchController.dispose();
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Refreshes search highlights when terminal output changes.
  void _onTerminalChanged() {
    if (!_searchOpen || _searchController.text.isEmpty) {
      return;
    }

    _refreshSearchHighlights();
  }

  /// Toggles the search bar open or closed.
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

  /// Resets the current match index when the search query changes.
  void _onSearchChanged(String _) {
    setState(() {
      _currentMatchIndex = 0;
      _refreshSearchHighlights();
    });
  }

  /// Builds the current search [RegExp], or null when search is inactive.
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

  /// Finds all search matches in the terminal buffer.
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

  /// Removes all active terminal search highlight overlays.
  void _clearSearchHighlights() {
    for (final highlight in _searchHighlights) {
      highlight.dispose();
    }
    _searchHighlights.clear();
  }

  /// Recomputes and applies search highlights in the terminal view.
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

  /// Moves to the previous or next terminal search match.
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

  /// Copies the visible log text to the clipboard.
  Future<void> _copyToClipboard() async {
    final selection = _controller.selection;
    final text = selection == null
        ? _terminalTextForCopy()
        : widget.terminal.buffer.getText(selection);

    await Clipboard.setData(ClipboardData(text: text));
  }

  /// Returns all non-empty terminal buffer text for clipboard copy.
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

  /// Clears scrollback while preserving the current input line.
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

  /// Builds the exec terminal with shared log viewer chrome.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
  /// A start/end cell range for one terminal search match.
  const _TerminalMatch({required this.start, required this.end});

  final CellOffset start;
  final CellOffset end;
}
