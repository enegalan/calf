import 'package:flutter/material.dart' show
    CircularProgressIndicator,
    PopupMenuDivider,
    PopupMenuItem,
    RelativeRect,
    RoundedRectangleBorder,
    showMenu;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/widgets/calf_button.dart';

class AppTopBar extends StatelessWidget {
  const AppTopBar({
    super.key,
    required this.registryStatus,
    required this.registryLoading,
    required this.signInPending,
    required this.onOpenSettings,
    required this.onSignIn,
    required this.onSignOut,
    required this.onOpenWhatsNew,
  });

  final RegistryLoginStatus? registryStatus;
  final bool registryLoading;
  final bool signInPending;
  final VoidCallback onOpenSettings;
  final VoidCallback onSignIn;
  final Future<void> Function() onSignOut;
  final VoidCallback onOpenWhatsNew;

  bool get _loggedIn => registryStatus?.loggedIn == true;

  String get _username => registryStatus?.username ?? '';

  String get _initial {
    final name = _username.trim();
    if (name.isEmpty) {
      return '?';
    }
    return name[0].toUpperCase();
  }

  String get _accountSettingsUrl =>
      'https://app.docker.com/accounts/$_username/settings/account-information';

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    const barHeight = 52.0;

    return Container(
      height: barHeight,
      decoration: BoxDecoration(
        color: theme.colorScheme.background,
        border: Border(bottom: BorderSide(color: theme.colorScheme.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _BrandMark(theme: theme),
          const Spacer(),
          CalfButton.ghost(
            width: 36,
            height: 36,
            padding: EdgeInsets.zero,
            onPressed: onOpenSettings,
            child: Icon(LucideIcons.settings, size: 18, color: theme.colorScheme.foreground),
          ),
          const SizedBox(width: 8),
          if (registryLoading)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (_loggedIn)
            _AccountMenuButton(
              initial: _initial,
              username: _username,
              theme: theme,
              accountSettingsUrl: _accountSettingsUrl,
              onOpenWhatsNew: onOpenWhatsNew,
              onSignOut: onSignOut,
            )
          else
            CalfButton(
              enabled: !signInPending,
              onPressed: signInPending ? null : onSignIn,
              child: Text(signInPending ? 'Signing in...' : 'Sign in'),
            ),
        ],
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.theme});

  final ShadThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Text(
            'C',
            style: theme.textTheme.small.copyWith(
              color: theme.colorScheme.primaryForeground,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text('calf', style: theme.textTheme.large.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _AccountMenuButton extends StatefulWidget {
  const _AccountMenuButton({
    required this.initial,
    required this.username,
    required this.theme,
    required this.accountSettingsUrl,
    required this.onOpenWhatsNew,
    required this.onSignOut,
  });

  final String initial;
  final String username;
  final ShadThemeData theme;
  final String accountSettingsUrl;
  final VoidCallback onOpenWhatsNew;
  final Future<void> Function() onSignOut;

  @override
  State<_AccountMenuButton> createState() => _AccountMenuButtonState();
}

class _AccountMenuButtonState extends State<_AccountMenuButton> {
  final _buttonKey = GlobalKey();

  Future<void> _openMenu() async {
    final buttonContext = _buttonKey.currentContext;
    if (buttonContext == null || !buttonContext.mounted) {
      return;
    }

    final box = buttonContext.findRenderObject()! as RenderBox;
    final overlayBox = Overlay.of(buttonContext).context.findRenderObject()! as RenderBox;
    final offset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    const menuWidth = 240.0;
    final theme = ShadTheme.of(buttonContext);
    final menuLeft = offset.dx + box.size.width - menuWidth;
    final menuTop = offset.dy + box.size.height + 8;

    final selected = await showMenu<String>(
      context: buttonContext,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(menuLeft, menuTop, menuWidth, 0),
        Offset.zero & overlayBox.size,
      ),
      color: theme.colorScheme.popover,
      surfaceTintColor: const Color(0x00000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.border),
      ),
      constraints: const BoxConstraints(minWidth: menuWidth),
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 56,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              _UserAvatar(initial: widget.initial, size: 32, theme: widget.theme),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.username,
                      style: theme.textTheme.large.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'whatsnew',
          height: 40,
          child: _AccountMenuRow(
            icon: LucideIcons.sparkles,
            label: "What's new",
            color: theme.colorScheme.foreground,
          ),
        ),
        PopupMenuItem<String>(
          value: 'settings',
          height: 40,
          child: _AccountMenuRow(
            icon: LucideIcons.user,
            label: 'Account Settings',
            color: theme.colorScheme.foreground,
            trailing: Icon(
              LucideIcons.externalLink,
              size: 14,
              color: theme.colorScheme.mutedForeground,
            ),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'signout',
          height: 40,
          child: _AccountMenuRow(
            icon: LucideIcons.logOut,
            label: 'Sign out',
            color: theme.colorScheme.destructive,
          ),
        ),
      ],
    );

    if (!mounted || selected == null) {
      return;
    }

    switch (selected) {
      case 'whatsnew':
        widget.onOpenWhatsNew();
      case 'settings':
        await openExternalUrl(widget.accountSettingsUrl);
      case 'signout':
        await widget.onSignOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return CalfButton.ghost(
      key: _buttonKey,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      onPressed: _openMenu,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _UserAvatar(initial: widget.initial, size: 28, theme: widget.theme),
          const SizedBox(width: 4),
          Icon(
            LucideIcons.chevronDown,
            size: 14,
            color: theme.colorScheme.foreground,
          ),
        ],
      ),
    );
  }
}

class _AccountMenuRow extends StatelessWidget {
  const _AccountMenuRow({
    required this.icon,
    required this.label,
    required this.color,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.small.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _UserAvatar extends StatelessWidget {
  const _UserAvatar({
    required this.initial,
    required this.size,
    required this.theme,
  });

  final String initial;
  final double size;
  final ShadThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: (size >= 32 ? theme.textTheme.large : theme.textTheme.small).copyWith(
          color: theme.colorScheme.primaryForeground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

Future<void> showRegistryLoginDialog({
  required BuildContext context,
  required CalfClient apiClient,
  required RegistryBrowserLoginStart start,
  required ValueChanged<String?> onComplete,
  required ValueChanged<String> onFailed,
}) {
  return showShadDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _RegistryLoginDialog(
      apiClient: apiClient,
      start: start,
      onComplete: onComplete,
      onFailed: onFailed,
    ),
  );
}

class _RegistryLoginDialog extends StatefulWidget {
  const _RegistryLoginDialog({
    required this.apiClient,
    required this.start,
    required this.onComplete,
    required this.onFailed,
  });

  final CalfClient apiClient;
  final RegistryBrowserLoginStart start;
  final ValueChanged<String?> onComplete;
  final ValueChanged<String> onFailed;

  @override
  State<_RegistryLoginDialog> createState() => _RegistryLoginDialogState();
}

class _RegistryLoginDialogState extends State<_RegistryLoginDialog> {
  String? _error;

  @override
  void initState() {
    super.initState();
    openExternalUrl(widget.start.verificationUrl);
    _poll();
  }

  Future<void> _poll() async {
    while (mounted) {
      await Future<void>.delayed(const Duration(seconds: 2));

      try {
        final status = await widget.apiClient.fetchRegistryBrowserLogin(widget.start.sessionId);
        if (!mounted) {
          return;
        }

        if (status.isComplete) {
          widget.onComplete(status.username);
          if (mounted) {
            Navigator.of(context).pop();
          }
          return;
        }

        if (status.isFailed) {
          final message = status.error ?? 'Browser login failed';
          widget.onFailed(message);
          if (mounted) {
            Navigator.of(context).pop();
          }
          return;
        }
      } catch (error) {
        if (!mounted) {
          return;
        }
        setState(() => _error = error.toString());
        widget.onFailed(error.toString());
        Navigator.of(context).pop();
        return;
      }
    }
  }

  Future<void> _openLoginPage() async {
    await openExternalUrl(widget.start.verificationUrl);
  }

  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: widget.start.userCode));
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return ShadDialog(
      scrollable: false,
      constraints: const BoxConstraints(maxWidth: 420),
      gap: 16,
      title: const Text('Sign in to Docker Hub'),
      description: const Text('Complete sign-in in your browser. This dialog closes when you are done.'),
      actions: [
        CalfButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.muted,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Waiting for browser sign-in...',
                      style: theme.textTheme.small,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Confirmation code',
              style: theme.textTheme.small.copyWith(color: theme.colorScheme.mutedForeground),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.start.userCode,
                      style: theme.textTheme.h4.copyWith(letterSpacing: 2),
                    ),
                  ),
                  CalfButton.ghost(
                    onPressed: _copyCode,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.copy, size: 14, color: theme.colorScheme.foreground),
                        const SizedBox(width: 6),
                        const Text('Copy'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            CalfButton.outline(
              onPressed: _openLoginPage,
              width: double.infinity,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.externalLink, size: 14, color: theme.colorScheme.foreground),
                  const SizedBox(width: 8),
                  const Text('Open login page'),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.small.copyWith(color: theme.colorScheme.destructive),
              ),
            ],
        ],
      ),
    );
  }
}

void showWhatsNewDialog(BuildContext context, String appVersion) {
  final theme = ShadTheme.of(context);

  showShadDialog<void>(
    context: context,
    builder: (context) => ShadDialog(
      scrollable: false,
      constraints: const BoxConstraints(maxWidth: 440),
      gap: 12,
      title: const Text("What's new"),
      description: Text('Calf $appVersion'),
      actions: [
        CalfButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
            _ReleaseNote(
              theme: theme,
              icon: LucideIcons.logIn,
              title: 'Docker Hub login',
              description: 'Browser sign-in with Google, GitHub and SSO.',
            ),
            const SizedBox(height: 8),
            _ReleaseNote(
              theme: theme,
              icon: LucideIcons.layers,
              title: 'Image management',
              description: 'Layers, run, pull and push from the Images screen.',
            ),
            const SizedBox(height: 8),
            _ReleaseNote(
              theme: theme,
              icon: LucideIcons.globe,
              title: 'localhost proxy',
              description: 'Published container ports work on localhost, not just 127.0.0.1.',
            ),
            const SizedBox(height: 8),
          _ReleaseNote(
            theme: theme,
            icon: LucideIcons.download,
            title: 'Docker Desktop migration',
            description: 'Import images, volumes, containers and settings.',
          ),
        ],
      ),
    ),
  );
}

class _ReleaseNote extends StatelessWidget {
  const _ReleaseNote({
    required this.theme,
    required this.icon,
    required this.title,
    required this.description,
  });

  final ShadThemeData theme;
  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: theme.colorScheme.muted,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 16, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.large.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(description, style: theme.textTheme.muted),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
