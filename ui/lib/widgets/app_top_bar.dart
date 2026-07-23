import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';

import 'package:ui/api/client.dart';
import 'package:ui/platform/open_url.dart';
import 'package:ui/widgets/calf_button.dart';
import 'package:ui/theme/calf_theme.dart';

class AppTopBar extends StatelessWidget {
  /// Renders the app header with branding, settings, and registry sign-in.
  const AppTopBar({
    super.key,
    required this.registryStatus,
    required this.registryLoading,
    required this.signInPending,
    required this.onOpenSettings,
    required this.onSignIn,
    required this.onSignOut,
    required this.onOpenWhatsNew,
    this.updateAvailable = false,
  });

  final RegistryLoginStatus? registryStatus;
  final bool registryLoading;
  final bool signInPending;
  final bool updateAvailable;
  final VoidCallback onOpenSettings;
  final VoidCallback onSignIn;
  final Future<void> Function() onSignOut;
  final VoidCallback onOpenWhatsNew;

  /// Whether the user is signed in to Docker Hub.
  bool get _loggedIn => registryStatus?.loggedIn == true;

  /// The signed-in Docker Hub username, if any.
  String get _username => registryStatus?.username ?? '';

  /// The first letter of the username for the avatar, or "?".
  String get _initial {
    final name = _username.trim();
    if (name.isEmpty) {
      return '?';
    }
    return name[0].toUpperCase();
  }

  /// URL to the Docker Hub account settings page for the signed-in user.
  String get _accountSettingsUrl =>
      'https://app.docker.com/accounts/$_username/settings/account-information';

  /// Builds the top bar with settings and registry controls.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const barHeight = 52.0;

    return Container(
      height: barHeight,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
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
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  LucideIcons.settings,
                  size: 18,
                  color: theme.colorScheme.onSurface,
                ),
                if (updateAvailable)
                  Positioned(
                    top: -2,
                    right: -2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.surface,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
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
  /// Renders the Calf logo and wordmark.
  const _BrandMark({required this.theme});

  final ThemeData theme;

  /// Builds the logo and wordmark row.
  @override
  Widget build(BuildContext context) {
    final logoAsset = theme.brightness == Brightness.dark
        ? 'assets/brand/calf_logo_white.png'
        : 'assets/brand/calf_logo_black.png';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          logoAsset,
          width: 36,
          height: 36,
          fit: BoxFit.contain,
          excludeFromSemantics: true,
        ),
        const SizedBox(width: 5),
        Text(
          'calf',
          style: theme.textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _AccountMenuButton extends StatefulWidget {
  /// Button that opens the signed-in account popup menu.
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
  final ThemeData theme;
  final String accountSettingsUrl;
  final VoidCallback onOpenWhatsNew;
  final Future<void> Function() onSignOut;

  /// Creates the state for the account menu button.
  @override
  State<_AccountMenuButton> createState() => _AccountMenuButtonState();
}

class _AccountMenuButtonState extends State<_AccountMenuButton> {
  final _buttonKey = GlobalKey();

  /// Opens the account popup menu and handles the selected action.
  Future<void> _openMenu() async {
    final buttonContext = _buttonKey.currentContext;
    if (buttonContext == null || !buttonContext.mounted) {
      return;
    }

    final box = buttonContext.findRenderObject()! as RenderBox;
    final overlayBox =
        Overlay.of(buttonContext).context.findRenderObject()! as RenderBox;
    final offset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    const menuWidth = 240.0;
    final theme = Theme.of(buttonContext);
    final menuLeft = offset.dx + box.size.width - menuWidth;
    final menuTop = offset.dy + box.size.height + 8;

    final selected = await showMenu<String>(
      context: buttonContext,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(menuLeft, menuTop, menuWidth, 0),
        Offset.zero & overlayBox.size,
      ),
      color: theme.colorScheme.surface,
      surfaceTintColor: const Color(0x00000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      constraints: const BoxConstraints(minWidth: menuWidth),
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 56,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              _UserAvatar(
                initial: widget.initial,
                size: 32,
                theme: widget.theme,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.username,
                      style: theme.textTheme.titleMedium!.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
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
            color: theme.colorScheme.onSurface,
          ),
        ),
        PopupMenuItem<String>(
          value: 'settings',
          height: 40,
          child: _AccountMenuRow(
            icon: LucideIcons.user,
            label: 'Account Settings',
            color: theme.colorScheme.onSurface,
            trailing: Icon(
              LucideIcons.externalLink,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
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
            color: theme.colorScheme.error,
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

  /// Builds the avatar button that opens the account menu.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
            color: theme.colorScheme.onSurface,
          ),
        ],
      ),
    );
  }
}

class _AccountMenuRow extends StatelessWidget {
  /// Renders one icon-and-label row inside the account popup menu.
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

  /// Builds the menu row with icon, label, and optional trailing widget.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall!.copyWith(
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
  /// Renders a circular avatar showing the user's initial.
  const _UserAvatar({
    required this.initial,
    required this.size,
    required this.theme,
  });

  final String initial;
  final double size;
  final ThemeData theme;

  /// Builds the circular user initial avatar.
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
        style: (size >= 32
                ? theme.textTheme.titleMedium!
                : theme.textTheme.bodySmall!)
            .copyWith(
              color: theme.colorScheme.onPrimary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// Shows a modal dialog that polls until Docker Hub browser login completes.
Future<void> showRegistryLoginDialog({
  required BuildContext context,
  required CalfClient apiClient,
  required RegistryBrowserLoginStart start,
  required ValueChanged<String?> onComplete,
  required ValueChanged<String> onFailed,
}) {
  return showDialog<void>(
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
  /// Dialog that guides the user through Docker Hub browser login.
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

  /// Creates the state for the registry login dialog.
  @override
  State<_RegistryLoginDialog> createState() => _RegistryLoginDialogState();
}

class _RegistryLoginDialogState extends State<_RegistryLoginDialog> {
  String? _error;

  /// Opens the verification URL and starts polling for login completion.
  @override
  void initState() {
    super.initState();
    openExternalUrl(widget.start.verificationUrl);
    _poll();
  }

  /// Polls the backend until browser login succeeds or fails.
  Future<void> _poll() async {
    while (mounted) {
      await Future<void>.delayed(const Duration(seconds: 2));

      try {
        final status = await widget.apiClient.fetchRegistryBrowserLogin(
          widget.start.sessionId,
        );
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

  /// Reopens the Docker Hub verification page in the browser.
  Future<void> _openLoginPage() async {
    await openExternalUrl(widget.start.verificationUrl);
  }

  /// Copies the device login confirmation code to the clipboard.
  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: widget.start.userCode));
  }

  /// Builds the browser login waiting dialog with confirmation code.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Sign in to Docker Hub'),
      content: SizedBox(
        width: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Complete sign-in in your browser. This dialog closes when you are done.',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
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
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Confirmation code',
              style: theme.textTheme.bodySmall!.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.start.userCode,
                      style: theme.textTheme.titleLarge?.copyWith(
                        letterSpacing: 2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  CalfButton.ghost(
                    onPressed: _copyCode,
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
                  Icon(
                    LucideIcons.externalLink,
                    size: 14,
                    color: theme.colorScheme.onSurface,
                  ),
                  const SizedBox(width: 8),
                  const Text('Open login page'),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        CalfButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Shows a dialog listing recent Calf release highlights.
void showWhatsNewDialog(BuildContext context, String appVersion) {
  final theme = Theme.of(context);

  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text("What's new"),
      content: SizedBox(
        width: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Calf $appVersion'),
            const SizedBox(height: 12),
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
              description:
                  'Published container ports work on localhost, not just 127.0.0.1.',
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
      actions: [
        CalfButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _ReleaseNote extends StatelessWidget {
  /// Renders one icon, title, and description row in the What's New dialog.
  const _ReleaseNote({
    required this.theme,
    required this.icon,
    required this.title,
    required this.description,
  });

  final ThemeData theme;
  final IconData icon;
  final String title;
  final String description;

  /// Builds one release highlight row with icon and text.
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
              color: theme.colorScheme.surfaceContainerHighest,
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
                Text(
                  title,
                  style: theme.textTheme.titleMedium!.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(description, style: CalfTheme.muted(theme)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
