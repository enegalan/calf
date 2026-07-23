import 'package:flutter/material.dart';

import 'package:ui/constants/calf_constants.dart';

/// Shared Material 3 theme helpers for the Calf UI.
abstract final class CalfTheme {
  /// Default corner radius used across panels and inputs.
  static const BorderRadius radius = BorderRadius.all(Radius.circular(8));

  /// Light Material 3 theme with Calf brand primary.
  static ThemeData get light => _build(Brightness.light);

  /// Dark Material 3 theme with Calf brand primary.
  static ThemeData get dark => _build(Brightness.dark);

  /// Returns a muted body text style for secondary labels.
  static TextStyle muted(ThemeData theme) {
    return theme.textTheme.bodyMedium!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  /// Builds a Material 3 [ThemeData] for the given brightness.
  static ThemeData _build(Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: CalfColors.primary,
      onPrimary: Colors.white,
      secondary: isLight ? const Color(0xFFF1F5F9) : const Color(0xFF1E293B),
      onSecondary: isLight ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      secondaryContainer: isLight
          ? const Color(0xFFD6EAF8)
          : const Color(0xFF1E3A5F),
      onSecondaryContainer: isLight
          ? const Color(0xFF0F172A)
          : const Color(0xFFE2E8F0),
      error: isLight ? const Color(0xFFEF4444) : const Color(0xFF7F1D1D),
      onError: Colors.white,
      surface: isLight ? const Color(0xFFFFFFFF) : const Color(0xFF020817),
      onSurface: isLight ? const Color(0xFF020817) : const Color(0xFFF8FAFC),
      surfaceContainerHighest: isLight
          ? const Color(0xFFF1F5F9)
          : const Color(0xFF1E293B),
      onSurfaceVariant: isLight
          ? const Color(0xFF64748B)
          : const Color(0xFF94A3B8),
      outline: isLight ? const Color(0xFFCBD5E1) : const Color(0xFF334155),
      outlineVariant: isLight
          ? const Color(0xFFE2E8F0)
          : const Color(0xFF1E293B),
      inverseSurface: isLight
          ? const Color(0xFF1E293B)
          : const Color(0xFFE2E8F0),
      onInverseSurface: isLight
          ? const Color(0xFFF8FAFC)
          : const Color(0xFF0F172A),
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant,
        thickness: 1,
      ),
      cardTheme: const CardThemeData(
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
      // Opt into Material 3 2024 slider (gapped track + handle thumb).
      // thumbSize/trackGap are required by HandleThumbShape/GappedSliderTrackShape.
      // ignore: deprecated_member_use
      sliderTheme: SliderThemeData(
        // ignore: deprecated_member_use
        year2023: false,
        trackHeight: 16,
        trackGap: 6,
        thumbSize: const WidgetStatePropertyAll(Size(4, 44)),
        thumbShape: const HandleThumbShape(),
        trackShape: const GappedSliderTrackShape(),
        tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 2),
        valueIndicatorShape: const RoundedRectSliderValueIndicatorShape(),
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.secondaryContainer,
        disabledActiveTrackColor: colorScheme.onSurface.withValues(alpha: 0.38),
        disabledInactiveTrackColor: colorScheme.onSurface.withValues(
          alpha: 0.12,
        ),
        thumbColor: colorScheme.primary,
        disabledThumbColor: colorScheme.onSurface.withValues(alpha: 0.38),
        activeTickMarkColor: colorScheme.onPrimary,
        inactiveTickMarkColor: colorScheme.onSecondaryContainer,
        valueIndicatorColor: colorScheme.inverseSurface,
        valueIndicatorTextStyle: TextStyle(color: colorScheme.onInverseSurface),
        overlayColor: colorScheme.primary.withValues(alpha: 0.12),
        showValueIndicator: ShowValueIndicator.onlyForDiscrete,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: radius),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: colorScheme.primary),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        isDense: true,
      ),
    );

    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: colorScheme.onSurface,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          fontSize: 14,
          color: colorScheme.onSurface,
        ),
        bodySmall: base.textTheme.bodySmall?.copyWith(
          fontSize: 12,
          color: colorScheme.onSurface,
        ),
      ),
    );
  }
}
