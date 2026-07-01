import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/app_shell.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key, this.apiClient});

  final StatusClient? apiClient;

  @override
  Widget build(BuildContext context) {
    return ShadApp(
      home: AppShell(apiClient: apiClient),
    );
  }
}
