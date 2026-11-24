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

    test('semantic report status tokens remain distinct', () {
      expect(SaqiaTheme.reportError, isNot(SaqiaTheme.reportWarning));
      expect(SaqiaTheme.reportError, isNot(SaqiaTheme.reportPositive));
      expect(SaqiaTheme.reportWarning, isNot(SaqiaTheme.reportPositive));
    });

    test('dark theme defines readable surfaces and input contrast', () {
      final dark = SaqiaTheme.dark(themeKey: 'violet');
      expect(dark.scaffoldBackgroundColor, const Color(0xff111815));
      expect(dark.dialogTheme.backgroundColor, const Color(0xff202b26));
      expect(dark.inputDecorationTheme.filled, isTrue);
      expect(dark.colorScheme.onSurface, const Color(0xfff0f3ed));
    });

    test('all five palettes propagate to interactive component accents', () {
      for (final key in keys) {
        final accent = SaqiaTheme.accent(key);
        final light = SaqiaTheme.light(themeKey: key);
        final dark = SaqiaTheme.dark(themeKey: key);
        final darkAccent = Color.lerp(accent, Colors.white, .22)!;
        final darkSecondary = Color.lerp(
          SaqiaTheme.secondary(key),
          Colors.white,
          .22,
        )!;

        expect(light.colorScheme.primary, accent, reason: key);
        expect(light.colorScheme.secondary, SaqiaTheme.secondary(key), reason: key);
        expect(dark.colorScheme.primary, darkAccent, reason: key);
        expect(dark.colorScheme.secondary, darkSecondary, reason: key);

        for (final theme in [light, dark]) {
          final expected = identical(theme, light) ? accent : darkAccent;
          expect(
            theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
            expected,
            reason: '$key filled button',
          );
          expect(
            theme.outlinedButtonTheme.style!.foregroundColor!.resolve({}),
            expected,
            reason: '$key outlined button',
          );
          expect(
            theme.textButtonTheme.style!.foregroundColor!.resolve({}),
            expected,
            reason: '$key text button',
          );
          expect(theme.listTileTheme.iconColor, expected, reason: '$key list tile');
          expect(
            theme.checkboxTheme.fillColor!.resolve({WidgetState.selected}),
            expected,
            reason: '$key checkbox',
          );
          expect(
            theme.radioTheme.fillColor!.resolve({WidgetState.selected}),
            expected,
            reason: '$key radio',
          );
          expect(
            theme.switchTheme.trackColor!.resolve({WidgetState.selected}),
            expected.withValues(alpha: .55),
            reason: '$key switch',
          );
          expect(
            theme.chipTheme.selectedColor,
            expected.withValues(alpha: identical(theme, light) ? .14 : .2),
            reason: '$key chip',
          );
          expect(
            theme.navigationBarTheme.indicatorColor,
            expected.withValues(alpha: identical(theme, light) ? .14 : .22),
            reason: '$key navigation indicator',
          );
          expect(theme.progressIndicatorTheme.color, expected, reason: '$key progress');
        }
      }
    });

    test('light and dark modal surfaces stay consistent for every palette', () {
      for (final key in keys) {
        final light = SaqiaTheme.light(themeKey: key);
        final dark = SaqiaTheme.dark(themeKey: key);

        expect(light.scaffoldBackgroundColor, const Color(0xfff4f5ef));
        expect(light.cardTheme.color, Colors.white);
        expect(light.dialogTheme.backgroundColor, Colors.white);
        expect(light.bottomSheetTheme.backgroundColor, Colors.white);
        expect(light.popupMenuTheme.color, Colors.white);

        expect(dark.scaffoldBackgroundColor, const Color(0xff111815));
        expect(dark.cardTheme.color, const Color(0xff1c2522));
        expect(dark.dialogTheme.backgroundColor, const Color(0xff202b26));
        expect(dark.bottomSheetTheme.backgroundColor, const Color(0xff202b26));
        expect(dark.popupMenuTheme.color, const Color(0xff202b26));
      }
    });

    test('all accent palettes maintain accessible filled-button contrast', () {
      double contrastRatio(Color first, Color second) {
        final a = first.computeLuminance();
        final b = second.computeLuminance();
        final lighter = a > b ? a : b;
        final darker = a > b ? b : a;
        return (lighter + .05) / (darker + .05);
      }

      for (final key in keys) {
        final light = SaqiaTheme.light(themeKey: key);
        final dark = SaqiaTheme.dark(themeKey: key);
        final lightForeground =
            light.filledButtonTheme.style!.foregroundColor!.resolve({})!;
        final darkForeground =
            dark.filledButtonTheme.style!.foregroundColor!.resolve({})!;

        expect(
          contrastRatio(light.colorScheme.primary, lightForeground),
          greaterThanOrEqualTo(4.5),
          reason: '$key light filled button',
        );
        expect(
          contrastRatio(dark.colorScheme.primary, darkForeground),
          greaterThanOrEqualTo(4.5),
          reason: '$key dark filled button',
        );
      }
    });
  });
}
