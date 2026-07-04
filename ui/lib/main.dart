import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ui/api/client.dart';
import 'package:ui/app_shell.dart';

const _calfPrimary = Color(0xFF2496ED);

final _lightShadTheme = ShadThemeData(
  brightness: Brightness.light,
  colorScheme: const ShadBlueColorScheme.light(
    primary: _calfPrimary,
    ring: _calfPrimary,
  ),
);

final _darkShadTheme = ShadThemeData(
  brightness: Brightness.dark,
  colorScheme: const ShadBlueColorScheme.dark(
    primary: _calfPrimary,
    ring: _calfPrimary,
  ),
);

ThemeData _materialTheme(ShadThemeData shadTheme) {
  return ThemeData(
    fontFamily: shadTheme.textTheme.family,
    colorScheme: ColorScheme(
      brightness: shadTheme.brightness,
      primary: shadTheme.colorScheme.primary,
      onPrimary: shadTheme.colorScheme.primaryForeground,
      secondary: shadTheme.colorScheme.secondary,
      onSecondary: shadTheme.colorScheme.secondaryForeground,
      error: shadTheme.colorScheme.destructive,
      onError: shadTheme.colorScheme.destructiveForeground,
      surface: shadTheme.colorScheme.background,
      onSurface: shadTheme.colorScheme.foreground,
    ),
    scaffoldBackgroundColor: shadTheme.colorScheme.background,
    brightness: shadTheme.brightness,
    dividerTheme: DividerThemeData(
      color: shadTheme.separatorTheme.color ?? shadTheme.colorScheme.border,
      thickness: shadTheme.separatorTheme.thickness ?? 1,
    ),
    useMaterial3: true,
  );
}

void main() {
  runApp(const MainApp());
}

class MainApp extends StatefulWidget {
  const MainApp({super.key, this.apiClient});

  final CalfClient? apiClient;

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: _materialTheme(_lightShadTheme),
      darkTheme: _materialTheme(_darkShadTheme),
      builder: (context, child) {
        final brightness = Theme.of(context).brightness;
        final shadTheme = brightness == Brightness.dark ? _darkShadTheme : _lightShadTheme;

        return ShadTheme(
          data: shadTheme,
          child: DefaultTextStyle(
            style: TextStyle(
              color: shadTheme.colorScheme.foreground,
              fontFamily: shadTheme.textTheme.family,
            ),
            child: ColoredBox(
              color: shadTheme.colorScheme.background,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        );
      },
      home: AppShell(
        apiClient: widget.apiClient,
        themeMode: _themeMode,
        onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
      ),
    );
  }
}
