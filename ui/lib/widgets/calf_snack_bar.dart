import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:ui/constants/calf_constants.dart';
import 'package:ui/theme/calf_theme.dart';
import 'package:ui/widgets/error_text.dart';

/// Default toast width for desktop layouts.
const double _calfSnackBarWidth = 440;

/// Clears space above [AppBottomBar] (32px) plus a small gap.
const double _calfSnackBarBottomInset = 48;

/// Gap between stacked toasts.
const double _calfSnackBarStackGap = 8;

/// Enter/exit motion for each toast.
const Duration _calfSnackBarMotion = Duration(milliseconds: 220);

/// Auto-dismiss for info and success toasts.
const Duration _calfSnackBarInfoDuration = Duration(milliseconds: 4000);

/// Auto-dismiss for error toasts.
const Duration _calfSnackBarErrorDuration = Duration(milliseconds: 6000);

/// Visual kind for a calf toast.
enum CalfToastKind {
  /// Neutral status or copy confirmation.
  info,

  /// Completed user action.
  success,

  /// Failed user action or load error.
  error,

  /// In-progress user action; stays until completed or failed.
  progress,
}

/// Shows a calf-styled floating toast stacked at the bottom-right.
///
/// Requires [CalfToastLayer] above the app shell content.
void showCalfSnackBar(
  BuildContext context,
  String message, {
  Duration? duration,
  CalfToastKind kind = CalfToastKind.info,
}) {
  CalfToastController.instance.show(
    message: message,
    kind: kind,
    duration: duration ?? _durationForKind(kind),
  );
}

/// Shows an error toast using a user-facing message from [error].
void showCalfErrorSnackBar(BuildContext context, Object error) {
  showCalfSnackBar(
    context,
    formatAsyncError(error),
    kind: CalfToastKind.error,
  );
}

/// Shows a sticky progress toast and returns a handle to finish it.
CalfToastHandle showCalfProgressToast(String message) {
  return CalfToastController.instance.showProgress(message);
}

/// Runs [action] with a progress toast, then success or error.
Future<bool> runCalfToastAction({
  required String pending,
  required String done,
  required Future<void> Function() action,
}) async {
  final toast = showCalfProgressToast(pending);
  try {
    await action();
    toast.complete(done);
    return true;
  } catch (error) {
    toast.fail(formatAsyncError(error));
    return false;
  }
}

/// Handle for a progress toast that can complete, fail, or dismiss.
class CalfToastHandle {
  /// Creates a handle for toast [id].
  CalfToastHandle(this._id);

  final int _id;

  /// Turns the toast into a success message and auto-dismisses it.
  void complete(String message) {
    CalfToastController.instance.update(
      _id,
      message: message,
      kind: CalfToastKind.success,
      duration: _calfSnackBarInfoDuration,
    );
  }

  /// Turns the toast into an error message and auto-dismisses it.
  void fail(String message) {
    CalfToastController.instance.update(
      _id,
      message: message,
      kind: CalfToastKind.error,
      duration: _calfSnackBarErrorDuration,
    );
  }

  /// Starts the exit animation without a follow-up message.
  void dismiss() {
    CalfToastController.instance.dismiss(_id);
  }
}

/// Shared controller for stacked calf toasts.
class CalfToastController extends ChangeNotifier {
  /// App-wide toast controller used by [showCalfSnackBar] and [CalfToastLayer].
  static final CalfToastController instance = CalfToastController._();

  CalfToastController._();

  final List<_CalfToastItem> _items = <_CalfToastItem>[];
  int _nextId = 0;

  /// Whether any toast is currently visible or animating.
  bool get hasItems => _items.isNotEmpty;

  /// Adds a toast to the stack. A null [duration] keeps it until dismissed.
  CalfToastHandle show({
    required String message,
    required CalfToastKind kind,
    Duration? duration,
  }) {
    final id = _nextId++;
    _items.add(
      _CalfToastItem(
        id: id,
        message: message,
        kind: kind,
        timer: duration == null ? null : Timer(duration, () => dismiss(id)),
      ),
    );
    notifyListeners();
    return CalfToastHandle(id);
  }

  /// Adds a sticky progress toast.
  CalfToastHandle showProgress(String message) {
    return show(
      message: message,
      kind: CalfToastKind.progress,
    );
  }

  /// Replaces an existing toast, or shows a new one if it was already dismissed.
  void update(
    int id, {
    required String message,
    required CalfToastKind kind,
    Duration? duration,
  }) {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) {
      show(message: message, kind: kind, duration: duration);
      return;
    }

    final item = _items[index];
    item.timer?.cancel();
    item.message = message;
    item.kind = kind;
    item.timer = duration == null ? null : Timer(duration, () => dismiss(id));
    notifyListeners();
  }

  /// Starts the exit animation for [id].
  void dismiss(int id) {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) {
      return;
    }

    final item = _items[index];
    if (item.dismissing) {
      return;
    }

    item.timer?.cancel();
    item.dismissing = true;
    notifyListeners();
  }

  /// Removes a toast after its exit animation finishes.
  void remove(int id) {
    void doRemove() {
      final index = _items.indexWhere((item) => item.id == id);
      if (index < 0) {
        return;
      }

      _items[index].timer?.cancel();
      _items.removeAt(index);
      notifyListeners();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => doRemove());
  }

  /// Cancels timers and clears all toasts (used after hot reload / remount).
  void clear() {
    for (final item in _items) {
      item.timer?.cancel();
    }
    if (_items.isEmpty) {
      return;
    }
    _items.clear();
    notifyListeners();
  }
}

/// Auto-dismiss duration for a non-progress [kind].
Duration? _durationForKind(CalfToastKind kind) {
  switch (kind) {
    case CalfToastKind.progress:
      return null;
    case CalfToastKind.error:
      return _calfSnackBarErrorDuration;
    case CalfToastKind.info:
    case CalfToastKind.success:
      return _calfSnackBarInfoDuration;
  }
}

/// Wraps app content and renders toasts in the root overlay via [OverlayPortal].
///
/// Avoids putting a [Stack] in [Scaffold.body], which breaks M3 [Slider]
/// value-indicator [OverlayPortal]s.
class CalfToastLayer extends StatefulWidget {
  /// Creates a toast layer around [child].
  const CalfToastLayer({super.key, required this.child});

  final Widget child;

  /// Creates the state object for [CalfToastLayer].
  @override
  State<CalfToastLayer> createState() => _CalfToastLayerState();
}

class _CalfToastLayerState extends State<CalfToastLayer> {
  final OverlayPortalController _portalController = OverlayPortalController();

  /// Clears stale toasts and listens for stack changes.
  @override
  void initState() {
    super.initState();
    CalfToastController.instance.clear();
    CalfToastController.instance.addListener(_syncPortal);
  }

  /// Stops listening when the layer is disposed.
  @override
  void dispose() {
    CalfToastController.instance.removeListener(_syncPortal);
    super.dispose();
  }

  /// Shows or hides the overlay portal to match the toast stack.
  void _syncPortal() {
    final hasItems = CalfToastController.instance.hasItems;
    if (hasItems && !_portalController.isShowing) {
      _portalController.show();
    } else if (!hasItems && _portalController.isShowing) {
      _portalController.hide();
    } else if (hasItems && mounted) {
      setState(() {});
    }
  }

  /// Builds the content child with an optional toast overlay.
  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portalController,
      overlayChildBuilder: _buildOverlay,
      child: widget.child,
    );
  }

  /// Builds the bottom-right toast stack inside the root overlay.
  Widget _buildOverlay(BuildContext context) {
    final items = CalfToastController.instance._items;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          right: 16,
          bottom: _calfSnackBarBottomInset,
          width: _calfSnackBarWidth,
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in items)
                  _CalfToastCard(
                    key: ValueKey<int>(item.id),
                    message: item.message,
                    kind: item.kind,
                    dismissing: item.dismissing,
                    showGapAbove: item.id != items.first.id,
                    onRequestDismiss: () =>
                        CalfToastController.instance.dismiss(item.id),
                    onExitComplete: () =>
                        CalfToastController.instance.remove(item.id),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One stacked toast entry and its auto-dismiss timer.
class _CalfToastItem {
  /// Creates a toast item owned by [CalfToastController].
  _CalfToastItem({
    required this.id,
    required this.message,
    required this.kind,
    required this.timer,
  });

  final int id;
  String message;
  CalfToastKind kind;
  Timer? timer;

  /// Whether the exit animation has been requested.
  bool dismissing = false;
}

/// Animated toast card with slide/fade enter and exit.
class _CalfToastCard extends StatefulWidget {
  /// Creates a toast card.
  const _CalfToastCard({
    super.key,
    required this.message,
    required this.kind,
    required this.dismissing,
    required this.showGapAbove,
    required this.onRequestDismiss,
    required this.onExitComplete,
  });

  final String message;
  final CalfToastKind kind;

  /// Snapshot of dismiss state for this build (must not share a mutable field).
  final bool dismissing;
  final bool showGapAbove;
  final VoidCallback onRequestDismiss;
  final VoidCallback onExitComplete;

  /// Creates the state object for [_CalfToastCard].
  @override
  State<_CalfToastCard> createState() => _CalfToastCardState();
}

class _CalfToastCardState extends State<_CalfToastCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  bool _exitStarted = false;

  /// Starts the enter animation after the first frame.
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _calfSnackBarMotion,
    );
    _fade = _controller.drive(CurveTween(curve: CalfTheme.animationCurve));
    _slide = _controller.drive(
      Tween<Offset>(
        begin: const Offset(0.15, 0),
        end: Offset.zero,
      ).chain(CurveTween(curve: CalfTheme.animationCurve)),
    );
    _controller.addStatusListener(_onStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (widget.dismissing) {
        _playExit();
        return;
      }
      _controller.forward();
    });
  }

  /// Plays exit when [dismissing] flips from false to true.
  @override
  void didUpdateWidget(covariant _CalfToastCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.dismissing && !oldWidget.dismissing) {
      _playExit();
    }
  }

  /// Removes the toast once the exit animation finishes.
  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _exitStarted && mounted) {
      widget.onExitComplete();
    }
  }

  /// Reverses the motion toward the right edge.
  void _playExit() {
    if (_exitStarted) {
      return;
    }
    _exitStarted = true;
    if (_controller.value <= 0.0) {
      widget.onExitComplete();
      return;
    }
    _controller.reverse();
  }

  /// Releases the animation controller.
  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  /// Accent color for the current toast kind.
  Color _accentColor(ColorScheme colorScheme) {
    switch (widget.kind) {
      case CalfToastKind.success:
        return CalfColors.success;
      case CalfToastKind.error:
        return colorScheme.error;
      case CalfToastKind.progress:
      case CalfToastKind.info:
        return CalfColors.primary;
    }
  }

  /// Leading icon or spinner for the current toast kind.
  Widget _leading(Color accent) {
    if (widget.kind == CalfToastKind.progress) {
      return SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: accent,
        ),
      );
    }

    final icon = switch (widget.kind) {
      CalfToastKind.success => LucideIcons.circleCheck,
      CalfToastKind.error => LucideIcons.circleAlert,
      CalfToastKind.info => LucideIcons.info,
      CalfToastKind.progress => LucideIcons.info,
    };
    return Icon(icon, size: 18, color: accent);
  }

  /// Builds the animated toast panel.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final accent = _accentColor(colorScheme);

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Padding(
          padding: EdgeInsets.only(
            top: widget.showGapAbove ? _calfSnackBarStackGap : 0,
          ),
          child: Material(
            color: colorScheme.surfaceContainerHigh,
            elevation: 12,
            shadowColor: colorScheme.onSurface.withValues(alpha: 0.22),
            shape: RoundedRectangleBorder(
              borderRadius: CalfTheme.radius,
              side: BorderSide(color: colorScheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(width: 5, color: accent),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 14, 0, 14),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: _leading(accent),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 14, 4, 14),
                      child: Text(
                        widget.message,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    onPressed: widget.dismissing
                        ? null
                        : widget.onRequestDismiss,
                    icon: Icon(
                      LucideIcons.x,
                      size: 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    style: IconButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(32, 32),
                      fixedSize: const Size(32, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
