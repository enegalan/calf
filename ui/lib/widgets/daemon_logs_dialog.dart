import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/theme/calf_theme.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/calf_snack_bar.dart';
import 'package:ui/widgets/confirm_dialog.dart';

/// Opens a dialog that shows recent daemon logs for copying and sharing.
Future<void> showDaemonLogsDialog({
  required BuildContext context,
  required CalfClient apiClient,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _DaemonLogsDialog(apiClient: apiClient),
  );
}

class _DaemonLogsDialog extends StatefulWidget {
  /// Dialog that loads and refreshes daemon logs while it is open.
  const _DaemonLogsDialog({required this.apiClient});

  final CalfClient apiClient;

  /// Creates the state for the daemon logs dialog.
  @override
  State<_DaemonLogsDialog> createState() => _DaemonLogsDialogState();
}

class _DaemonLogsDialogState extends State<_DaemonLogsDialog> {
  final _scrollController = ScrollController();
  Timer? _pollTimer;
  bool _loading = true;
  String _text = '';
  String _path = '';
  String? _error;

  /// Starts polling daemon logs after the first load.
  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_load(silent: true));
    });
  }

  /// Stops polling and releases the log scroll controller.
  @override
  void dispose() {
    _pollTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// Loads daemon logs from the API, keeping previous text on silent refresh errors.
  Future<void> _load({bool silent = false}) async {
    try {
      final logs = await widget.apiClient.fetchDaemonLogs();
      if (!mounted) {
        return;
      }
      setState(() {
        _text = logs.text;
        _path = logs.path;
        _error = null;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      if (silent && _text.isNotEmpty) {
        return;
      }
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } on TimeoutException catch (error) {
      if (!mounted) {
        return;
      }
      if (silent && _text.isNotEmpty) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  /// Copies the current log text to the clipboard.
  Future<void> _copy() async {
    final text = _text.trim().isEmpty ? _error ?? '' : _text;
    if (text.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    showCalfSnackBar(context, 'Copied', duration: const Duration(seconds: 2));
  }

  /// Opens the daemon log file in the platform file manager.
  Future<void> _openFile() async {
    if (_path.isEmpty) {
      return;
    }
    final opened = await openInFileExplorer(_path);
    if (opened || !mounted) {
      return;
    }
    final directory = p.dirname(_path);
    await openInFileExplorer(directory);
  }

  /// Builds the daemon logs dialog with copy and open-file actions.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var body = _text;
    var bodyColor = theme.colorScheme.onSurface;
    if (_error != null && _text.isEmpty) {
      body = _error!;
      bodyColor = theme.colorScheme.error;
    } else if (_text.isEmpty) {
      body = 'No logs yet. Reproduce the issue, then copy from here.';
    }
    final canCopy = _text.isNotEmpty || (_error != null && _error!.isNotEmpty);

    return CalfAlertDialog(
      title: const Text('Daemon logs'),
      width: 720,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Copy these logs and send them when reporting a problem.',
            style: CalfTheme.muted(theme),
          ),
          const SizedBox(height: 12),
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: theme.brightness == Brightness.dark ? 0.55 : 1,
              ),
              borderRadius: CalfTheme.radius,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 160, maxHeight: 320),
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Scrollbar(
                      controller: _scrollController,
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                        child: SelectableText(
                          body,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: CalfFonts.mono,
                            color: bodyColor,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
      actions: [
        if (_path.isNotEmpty)
          CalfButton.ghost(
            onPressed: _openFile,
            child: const Text('Open log file'),
          ),
        CalfButton.outline(
          onPressed: canCopy ? _copy : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.copy,
                size: 14,
                color: theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 6),
              const Text('Copy'),
            ],
          ),
        ),
        CalfButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
