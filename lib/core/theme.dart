import 'package:flutter/material.dart';

class SaqiaTheme {
  static const _cyan = Color(0xff00d7ff);
  static const _blue = Color(0xff287bff);
  static const _purple = Color(0xff7c4dff);
  static const _green = Color(0xff18e58c);
  static const _dark = Color(0xff0b1020);
  static const _surface = Color(0xff111a2d);

  static ThemeData light() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: _blue,
          brightness: Brightness.light,
        ).copyWith(
          primary: _blue,
          secondary: _purple,
          tertiary: _cyan,
          surface: Colors.white,
        );
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'NotoNaskhArabic',
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xfff4f7fb),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        surfaceTintColor: Colors.white,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.black.withOpacity(.07)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: _blue, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        ),
      ),
    );
  }

  static ThemeData dark() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: _cyan,
          brightness: Brightness.dark,
        ).copyWith(
          primary: _cyan,
          secondary: _purple,
          tertiary: _green,
          surface: _surface,
        );
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'NotoNaskhArabic',
      colorScheme: scheme,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _dark,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withOpacity(.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
    );
  }
}
