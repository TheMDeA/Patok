import 'package:flutter/material.dart';

/// Patok design system: field-dark theme with a hi-vis orange accent
/// ("survey-vest energy"). Built for outdoor readability.
class PatokTheme {
  PatokTheme._();

  /// Hi-vis safety orange — the brand accent.
  static const Color accent = Color(0xFFFF6B1A);
  static const Color accentDim = Color(0xFFB34A0F);

  static const Color bg = Color(0xFF101418);
  static const Color surface = Color(0xFF1A2027);
  static const Color surface2 = Color(0xFF232B34);
  static const Color onBg = Color(0xFFF2F5F7);
  static const Color onSurfaceDim = Color(0xFF9AA7B2);

  /// Sunlight mode: boosts contrast for bright outdoor use.
  static ThemeData dark({bool sunlightMode = false}) {
    final scheme = ColorScheme.dark(
      primary: accent,
      onPrimary: Colors.black,
      secondary: accent,
      surface: surface,
      onSurface: onBg,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: sunlightMode ? Colors.black : bg,
      appBarTheme: AppBarTheme(
        backgroundColor: sunlightMode ? Colors.black : bg,
        foregroundColor: onBg,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: Colors.black,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: surface2,
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.2),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.black : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent : null,
        ),
      ),
      textTheme: TextTheme(
        headlineSmall: TextStyle(
          color: onBg,
          fontWeight: FontWeight.w700,
          fontSize: sunlightMode ? 22 : 20,
        ),
        titleMedium: TextStyle(
          color: onBg,
          fontWeight: FontWeight.w600,
          fontSize: sunlightMode ? 17 : 16,
        ),
        bodyMedium: TextStyle(
          color: onBg,
          fontSize: sunlightMode ? 16 : 14,
        ),
        bodySmall: TextStyle(
          color: onSurfaceDim,
          fontSize: sunlightMode ? 15 : 13,
        ),
      ),
      dividerColor: surface2,
    );
  }
}
