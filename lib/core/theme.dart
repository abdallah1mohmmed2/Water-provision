import 'package:flutter/material.dart';

import 'app_prefs.dart';

/// نظام ألوان موحّد للتطبيق. ألوان الحالات المحاسبية تبقى دلالية وثابتة.
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

  static bool get isDark {
    final mode = AppPrefs.current.themeMode;
    if (mode == 'dark') return true;
    if (mode == 'light') return false;
    return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
  }

  // Semantic tokens used by the legacy report and form surfaces.
  static Color get reportAccent => accent(AppPrefs.current.themeKey);
  static Color get reportAccentDark => Color.lerp(
        reportAccent,
        Colors.black,
        isDark ? .18 : .28,
      )!;
  static Color get reportBackground =>
      isDark ? const Color(0xff111815) : const Color(0xfff4f3e9);
  static Color get reportSurface =>
      isDark ? const Color(0xff1c2522) : Colors.white;
  static Color get reportInk =>
      isDark ? const Color(0xfff0f3ed) : const Color(0xff263027);
  static Color get reportOutline =>
      isDark ? const Color(0xff39463f) : const Color(0xffdde1d5);
  static Color get reportPositive =>
      isDark ? const Color(0xff69d69b) : const Color(0xff169b58);
  static Color get reportNegative =>
      isDark ? const Color(0xffffad75) : const Color(0xffde7732);

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
      onSurface: const Color(0xff253023),
      surfaceContainerHighest: const Color(0xffeceee5),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: 'NotoNaskhArabic',
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xfff4f5ef),
      canvasColor: Colors.white,
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xfff4f5ef),
        foregroundColor: Color(0xff253023),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
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
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Colors.white,
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
          borderSide: BorderSide(color: primary, width: 1.6),
        ),
        labelStyle: const TextStyle(color: Color(0xff667064)),
        hintStyle: const TextStyle(color: Color(0xff858d80)),
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
          side: BorderSide(color: primary.withValues(alpha: .45)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: primary),
      ),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      listTileTheme: ListTileThemeData(
        iconColor: primary,
        textColor: scheme.onSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? primary : null),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? primary : null),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? Colors.white : null),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? primary.withValues(alpha: .55)
                : null),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: primary.withValues(alpha: .14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        side: BorderSide(color: primary.withValues(alpha: .18)),
      ),
      dividerTheme: const DividerThemeData(color: Color(0x14253023), space: 1),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: primary.withValues(alpha: .14),
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w700),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: primary),
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
      onSurface: const Color(0xfff0f3ed),
      surfaceContainerHighest: const Color(0xff293630),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'NotoNaskhArabic',
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xff111815),
      canvasColor: const Color(0xff1c2522),
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
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xff202b26),
        surfaceTintColor: Colors.transparent,
        titleTextStyle: const TextStyle(
          color: Color(0xfff2f5ee),
          fontWeight: FontWeight.w800,
          fontSize: 20,
        ),
        contentTextStyle: const TextStyle(color: Color(0xffd4ddd5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xff202b26),
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Color(0xff202b26),
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
          borderSide: BorderSide(color: primary, width: 1.6),
        ),
        labelStyle: const TextStyle(color: Color(0xffb5c0b6)),
        hintStyle: const TextStyle(color: Color(0xff89968c)),
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
          side: BorderSide(color: primary.withValues(alpha: .5)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: primary),
      ),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      listTileTheme: ListTileThemeData(
        iconColor: primary,
        textColor: scheme.onSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? primary : null),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? primary : null),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? Colors.white : null),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? primary.withValues(alpha: .55)
                : null),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: primary.withValues(alpha: .2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        side: BorderSide(color: primary.withValues(alpha: .22)),
        labelStyle: const TextStyle(color: Color(0xffedf2ec)),
      ),
      dividerTheme: DividerThemeData(color: Colors.white.withValues(alpha: .1)),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xff202b26),
        textStyle: const TextStyle(color: Color(0xffedf2ec)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xff1c2522),
        indicatorColor: primary.withValues(alpha: .22),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(color: Color(0xffedf2ec), fontWeight: FontWeight.w700),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: primary),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xff303c35),
        contentTextStyle: const TextStyle(color: Color(0xfff2f5ee)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  static Color _secondary(String key) => switch (key) {
        'ocean' => const Color(0xff42a5c3),
        'emerald' => const Color(0xff61b99b),
        'violet' => const Color(0xffb29ae8),
        'rose' => const Color(0xffe4a0ad),
        _ => const Color(0xffb2bf87),
      };

  static Color _lighten(Color color) =>
      Color.lerp(color, Colors.white, .22)!;
}
