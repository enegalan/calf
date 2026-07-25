import 'package:flutter/material.dart';

/// Primary-colored text that underlines on hover and runs [onTap] on click.
class HoverTextLink extends StatefulWidget {
  /// Creates a [HoverTextLink] widget.
  const HoverTextLink({
    super.key,
    required this.text,
    required this.onTap,
    this.style,
    this.overflow,
  });

  final String text;
  final VoidCallback onTap;
  final TextStyle? style;
  final TextOverflow? overflow;

  /// Creates the mutable state for [HoverTextLink].
  @override
  State<HoverTextLink> createState() => _HoverTextLinkState();
}

class _HoverTextLinkState extends State<HoverTextLink> {
  bool _hovering = false;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base =
        widget.style ??
        theme.textTheme.bodySmall!.copyWith(color: theme.colorScheme.primary);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Text(
          widget.text,
          overflow: widget.overflow,
          style: base.copyWith(
            decoration: _hovering
                ? TextDecoration.underline
                : TextDecoration.none,
            decorationColor: base.color,
          ),
        ),
      ),
    );
  }
}

/// Clickable published host ports; collapses to the first port plus a count.
class HostPortLinks extends StatefulWidget {
  /// Creates a [HostPortLinks] widget.
  const HostPortLinks({
    super.key,
    required this.ports,
    required this.onOpenPort,
    this.style,
  });

  final List<int> ports;
  final void Function(int port) onOpenPort;
  final TextStyle? style;

  /// Creates the mutable state for [HostPortLinks].
  @override
  State<HostPortLinks> createState() => _HostPortLinksState();
}

class _HostPortLinksState extends State<HostPortLinks> {
  bool _expanded = false;

  /// Builds the widget tree for the current screen state.
  @override
  Widget build(BuildContext context) {
    final ports = widget.ports;
    if (ports.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final linkStyle =
        widget.style ??
        theme.textTheme.bodySmall!.copyWith(color: theme.colorScheme.primary);
    final visible = _expanded || ports.length == 1 ? ports : ports.take(1);

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final port in visible)
          HoverTextLink(
            text: 'localhost:$port',
            onTap: () => widget.onOpenPort(port),
            style: linkStyle,
          ),
        if (ports.length > 1)
          HoverTextLink(
            text: '(${ports.length})',
            onTap: () => setState(() => _expanded = !_expanded),
            style: linkStyle,
          ),
      ],
    );
  }
}
