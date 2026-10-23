import 'package:flutter/material.dart';

/// ثيمات موحّدة لواجهات ساقية، مع إبقاء الألوان الخاصة بالحالات واضحة.
class SaqiaTheme {
  static const Map<String, Color> accents = {
    'olive': Color(0xff657c35),
    'ocean': Color(0xff167d9a),
    'emerald': Color(0xff13866d),
    'violet': Color(0xff7654b8),
    'rose': Color(0xffb65369),
  };

  static const Map<String, String> names = {
    'olive': 'زيتوني طبيعي',
    'ocean': 'أزرق بحري',
    'emerald': 'أخضر زمردي',
    'violet': 'بنفسجي عصري',
    'rose': 'وردي هادئ',
  };

  static Color accent(String key) => accents[key] ?? accents['olive']!;
  static String name(String key) => names[key] ?? names['olive']!;

  static ThemeData light({String themeKey = 'olive'}) {
    final primary = accent(themeKey);
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
    ).copyWith(
      primary: primary,
      secondary: _secondary(themeKey),
      tertiary: const Color(0xffd3a65b),
      surface: Colors.white,
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'NotoNaskhArabic',
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xfff7f7f1),
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xfff7f7f1),
        foregroundColor: const Color(0xff253023),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: const TextStyle(
          color: Color(0xff253023),
          fontSize: 19,
          fontWeight: FontWeight.w800,
          fontFamily: 'NotoNaskhArabic',
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        surfaceTintColor: Colors.white,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0x1a253023)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        side: BorderSide(color: primary.withValues(alpha: .18)),
      ),
      dividerTheme: const DividerThemeData(color: Color(0x14253023), space: 1),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  static ThemeData dark({String themeKey = 'olive'}) {
    final primary = _lighten(accent(themeKey));
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.dark,
    ).copyWith(
      primary: primary,
      secondary: _lighten(_secondary(themeKey)),
      tertiary: const Color(0xffe0b96f),
      surface: const Color(0xff1c2522),
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'NotoNaskhArabic',
      colorScheme: scheme,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff111815),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xff111815),
        foregroundColor: Color(0xfff2f5ee),
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: const Color(0xff1c2522),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: .045),
        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: .1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: const Color(0xff101510),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        ),
      ),
      dividerTheme: DividerThemeData(color: Colors.white.withValues(alpha: .1)),
    );
  }

  static Color _secondary(String key) => switch (key) {
    'ocean' => const Color(0xff42a5c3),
    'emerald' => const Color(0xff61b99b),
    'violet' => const Color(0xffb29ae8),
    'rose' => const Color(0xffe4a0ad),
    _ => const Color(0xffb2bf87),
  };

  static Color _lighten(Color color) => Color.lerp(color, Colors.white, .22)!;
}
