import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';
import 'package:ui/widgets/calf_snack_bar.dart';

mixin PollIntervalMixin<T extends StatefulWidget> on State<T> {
  Timer? pollTimer;
  int pollIntervalMs = CalfDefaults.defaultPollIntervalMs;

  /// Cancels the active poll timer during widget disposal.
  void disposePollInterval() {
    pollTimer?.cancel();
    pollTimer = null;
  }

  /// Fetches poll interval from config and starts periodic [reload] calls.
  Future<void> startPollInterval(
    CalfClient client,
    Future<void> Function({bool silent}) reload,
  ) async {
    try {
      final config = await client.fetchConfig();
      if (!mounted) {
        return;
      }
      pollIntervalMs = config.pollIntervalMs;
    } catch (_) {
      // Keep default poll interval when config is unavailable.
    }

    if (!mounted) {
      return;
    }

    pollTimer?.cancel();
    pollTimer = Timer.periodic(
      Duration(milliseconds: pollIntervalMs),
      (_) => reload(silent: true),
    );
  }
}

/// Shared in-flight / silent-failure handling for resource list screens.
mixin ResourceListPollMixin<T extends StatefulWidget> on State<T> {
  static const _silentFailureThreshold = 3;

  bool refreshInFlight = false;
  int consecutiveSilentFailures = 0;
  bool listLoading = true;
  final listSearchController = TextEditingController();
  String listSearchQuery = '';

  /// Wires [listSearchController] to update [listSearchQuery] on each change.
  void initListSearchListener() {
    listSearchController.addListener(() {
      setState(
        () => listSearchQuery = listSearchController.text.trim().toLowerCase(),
      );
    });
  }

  /// Disposes the list search controller.
  void disposeListSearch() {
    listSearchController.dispose();
  }

  /// Marks a non-silent load as in progress.
  void beginListLoad({required bool silent}) {
    if (!silent) {
      setState(() => listLoading = true);
    }
  }

  /// Runs [body] with in-flight guarding and the 3-failure silent-error rule.
  ///
  /// [body] should fetch data and call [setState] on success (including
  /// setting [listLoading] to false). Callers may skip setState when a silent
  /// poll finds no visible changes.
  Future<void> runListLoad({
    required bool silent,
    required Future<void> Function() body,
  }) async {
    if (refreshInFlight) {
      return;
    }

    refreshInFlight = true;
    beginListLoad(silent: silent);

    try {
      await body();
      if (!mounted) {
        return;
      }
      consecutiveSilentFailures = 0;
    } catch (error) {
      if (!mounted) {
        return;
      }
      if (!silent) {
        setState(() => listLoading = false);
        showCalfErrorSnackBar(context, error);
      } else {
        consecutiveSilentFailures++;
        if (consecutiveSilentFailures == _silentFailureThreshold) {
          showCalfErrorSnackBar(context, error);
        }
      }
    } finally {
      refreshInFlight = false;
    }
  }
}
