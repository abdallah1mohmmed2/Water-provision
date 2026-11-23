import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/core/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SaqiaTheme', () {
    const keys = ['olive', 'ocean', 'emerald', 'violet', 'rose'];

    test('defines five distinct named accent palettes', () {
      expect(SaqiaTheme.accents.keys.toSet(), keys.toSet());
      expect(SaqiaTheme.names.keys.toSet(), keys.toSet());
      expect(SaqiaTheme.accents.values.toSet().length, 5);
      for (final key in keys) {
        expect(SaqiaTheme.name(key), isNotEmpty);
        expect(SaqiaTheme.accent(key), isNot(Colors.transparent));
      }
    });

    test('light and dark themes retain selected accent and brightness', () {
      for (final key in keys) {
        final light = SaqiaTheme.light(themeKey: key);
        final dark = SaqiaTheme.dark(themeKey: key);
        expect(light.brightness, Brightness.light);
        expect(dark.brightness, Brightness.dark);
        expect(light.colorScheme.primary, SaqiaTheme.accent(key));
        expect(dark.colorScheme.primary, isNot(Colors.transparent));
        expect(light.cardTheme.color, Colors.white);
        expect(dark.cardTheme.color, const Color(0xff1c2522));
      }
    });

    test('dark theme defines readable surfaces and input contrast', () {
      final dark = SaqiaTheme.dark(themeKey: 'violet');
      expect(dark.scaffoldBackgroundColor, const Color(0xff111815));
      expect(dark.dialogTheme.backgroundColor, const Color(0xff202b26));
      expect(dark.inputDecorationTheme.filled, isTrue);
      expect(dark.colorScheme.onSurface, const Color(0xfff0f3ed));
    });
  });
}
