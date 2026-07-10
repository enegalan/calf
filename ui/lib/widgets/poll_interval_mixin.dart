import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:ui/api/client.dart';
import 'package:ui/constants/calf_constants.dart';

mixin PollIntervalMixin<T extends StatefulWidget> on State<T> {
  Timer? pollTimer;
  int pollIntervalMs = CalfDefaults.defaultPollIntervalMs;

  void disposePollInterval() {
    pollTimer?.cancel();
    pollTimer = null;
  }

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
