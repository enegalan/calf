import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/api/client.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/theme/calf_theme.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/widgets/confirm_dialog.dart';

/// Troubleshoot panel with restart, support, purge, reset, and uninstall actions.
class TroubleshootScreen extends StatefulWidget {
  /// Creates a [TroubleshootScreen] instance.
  const TroubleshootScreen({
    super.key,
    required this.apiClient,
    required this.onClose,
    required this.onRestart,
    required this.onQuit,
    this.onGiveFeedback,
  });

  final CalfClient apiClient;
  final VoidCallback onClose;
  final Future<void> Function() onRestart;
  final Future<void> Function() onQuit;
  final VoidCallback? onGiveFeedback;

  /// Creates the state object for [TroubleshootScreen].
  @override
  State<TroubleshootScreen> createState() => _TroubleshootScreenState();
}

class _TroubleshootScreenState extends State<TroubleshootScreen> {
  bool _busy = false;
  String? _statusMessage;

  /// Runs [action] with busy state and snackbar feedback.
  Future<void> _runAction(
    String busyLabel,
    Future<void> Function() action, {
    String? successMessage,
  }) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _statusMessage = busyLabel;
    });
    try {
      await action();
      if (!mounted) {
        return;
      }
      setState(() => _statusMessage = successMessage);
      if (successMessage != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successMessage)));
      }
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _statusMessage = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } on TimeoutException {
      if (!mounted) {
        return;
      }
      setState(() => _statusMessage = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Action timed out')));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// Restarts Calf while preserving containers and settings.
  Future<void> _restart() async {
    await _runAction(
      'Restarting Calf…',
      widget.onRestart,
      successMessage: 'Calf restarted',
    );
  }

  /// Opens the support / feedback channel.
  Future<void> _getSupport() async {
    final opened = await openExternalUrl(calfReportIssueUrl);
    if (!mounted) {
      return;
    }
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open support page')),
      );
    }
  }

  /// Purges guest/engine data after confirmation.
  Future<void> _purgeData() async {
    final confirmed = await confirmDialog(
      context,
      title: 'Clean / Purge data',
      description:
          'Stop the engine and delete the guest disk and build history. '
          'Settings are kept. Images, containers, and volumes inside the engine will be removed.',
      confirmLabel: 'Clean / Purge data',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    await _runAction(
      'Purging engine data…',
      () => widget.apiClient.purgeEngineData(),
      successMessage: 'Engine data purged',
    );
  }

  /// Resets Calf to factory defaults after confirmation.
  Future<void> _factoryReset() async {
    final confirmed = await confirmDialog(
      context,
      title: 'Reset to factory defaults',
      description:
          'All settings and data under ~/.config/calf will be removed and '
          'defaults restored. This cannot be undone.',
      confirmLabel: 'Reset to factory defaults',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    await _runAction(
      'Resetting to factory defaults…',
      () => widget.apiClient.factoryReset(),
      successMessage: 'Factory defaults restored',
    );
  }

  /// Uninstalls Calf data and quits after confirmation.
  Future<void> _uninstall() async {
    final confirmed = await confirmDialog(
      context,
      title: 'Uninstall Calf',
      description:
          'Calf will wipe local data, then quit. Remove the app with your '
          'installer afterward'
          '${Platform.isMacOS ? ' (for example: brew uninstall --cask calf)' : ''}.',
      confirmLabel: 'Uninstall',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }
    await _runAction('Uninstalling…', () async {
      await widget.apiClient.factoryReset();
      await widget.onQuit();
    });
  }

  /// Builds the troubleshoot list layout.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                children: [
                  Text('Troubleshoot', style: theme.textTheme.headlineSmall),
                  CalfButton.ghost(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    onPressed:
                        widget.onGiveFeedback ?? () => unawaited(_getSupport()),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Give feedback',
                          style: theme.textTheme.bodySmall!.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          LucideIcons.externalLink,
                          size: 12,
                          color: theme.colorScheme.primary,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Tooltip(
              message: 'Close troubleshoot',
              child: CalfButton.ghost(
                width: 36,
                height: 36,
                onPressed: _busy ? null : widget.onClose,
                child: Icon(
                  LucideIcons.x,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
        if (_statusMessage != null) ...[
          const SizedBox(height: 12),
          Text(_statusMessage!, style: CalfTheme.muted(theme)),
        ],
        const SizedBox(height: 16),
        Expanded(
          child: ListView(
            children: [
              _TroubleshootRow(
                title: 'Restart Calf',
                description: 'All containers and settings are preserved.',
                actionLabel: 'Restart',
                destructive: false,
                enabled: !_busy,
                onPressed: () => unawaited(_restart()),
              ),
              _TroubleshootRow(
                title: 'Support',
                description: 'Get help with Calf.',
                actionLabel: 'Get support',
                destructive: false,
                enabled: !_busy,
                onPressed: () => unawaited(_getSupport()),
              ),
              _TroubleshootRow(
                title: 'Clean / Purge data',
                description:
                    'This solves problems with disk corruption or the engine not booting.',
                actionLabel: 'Clean / Purge data',
                destructive: true,
                enabled: !_busy,
                onPressed: () => unawaited(_purgeData()),
              ),
              _TroubleshootRow(
                title: 'Reset to factory defaults',
                description: 'All settings and data will be removed.',
                actionLabel: 'Reset to factory defaults',
                destructive: true,
                enabled: !_busy,
                onPressed: () => unawaited(_factoryReset()),
              ),
              _TroubleshootRow(
                title: 'Uninstall Calf',
                description:
                    'We\'re sorry to see you go. This completely uninstalls Calf data and quits the app.',
                actionLabel: 'Uninstall',
                destructive: true,
                enabled: !_busy,
                onPressed: () => unawaited(_uninstall()),
                showDivider: false,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One troubleshoot action row with title, description, and trailing button.
class _TroubleshootRow extends StatelessWidget {
  /// Creates a troubleshoot list row.
  const _TroubleshootRow({
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.destructive,
    required this.enabled,
    required this.onPressed,
    this.showDivider = true,
  });

  final String title;
  final String description;
  final String actionLabel;
  final bool destructive;
  final bool enabled;
  final VoidCallback onPressed;
  final bool showDivider;

  /// Builds the row and optional bottom divider.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final button = destructive
        ? OutlinedButton(
            onPressed: enabled ? onPressed : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
              disabledForegroundColor: theme.colorScheme.error.withValues(
                alpha: 0.4,
              ),
              side: BorderSide(
                color: enabled
                    ? theme.colorScheme.error
                    : theme.colorScheme.error.withValues(alpha: 0.35),
              ),
              textStyle: theme.textTheme.bodySmall,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            child: Text(actionLabel),
          )
        : CalfButton.outline(
            enabled: enabled,
            onPressed: enabled ? onPressed : null,
            child: Text(actionLabel),
          );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
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
              const SizedBox(width: 16),
              button,
            ],
          ),
        ),
        if (showDivider)
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
      ],
    );
  }
}
