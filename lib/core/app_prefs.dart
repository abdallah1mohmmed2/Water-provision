import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'app_clock.dart';

/// تفضيلات تُقرأ من جدول الإعدادات وتؤثر على الواجهة كلها:
/// اسم التطبيق، تقليل الحركة، النوافذ المنبثقة، التنبيهات الصوتية، ومصدر الوقت.
class AppPrefsData {
  final String appName, themeKey, themeMode;
  final bool reducedMotion, popup, sound;
  const AppPrefsData({
    this.appName = 'منظومة',
    this.themeKey = 'olive',
    this.themeMode = 'system',
    this.reducedMotion = false,
    this.popup = true,
    this.sound = true,
  });
}

class AppPrefs {
  AppPrefs._();
  static final ValueNotifier<AppPrefsData> notifier =
      ValueNotifier(const AppPrefsData());
  static AppPrefsData get current => notifier.value;

  /// تُستدعى عند فتح التطبيق وبعد حفظ أي إعداد.
  static Future<void> apply(Map<String, String> s) async {
    final name = (s['app_name'] ?? '').trim();
    notifier.value = AppPrefsData(
      appName: name.isEmpty || name == 'ساقية لإدارة محطة ضخ مياه الري'
          ? const AppPrefsData().appName
          : name,
      themeKey: (s['theme_key'] ?? 'olive').trim(),
      themeMode: (s['theme_mode'] ?? 'system').trim(),
      reducedMotion: s['reduced_motion'] == 'true',
      popup: (s['popup_notifications'] ?? 'true') == 'true',
      sound: (s['sound_notifications'] ?? 'true') == 'true',
    );
    await AppClock.configure(
      source: s['time_source'] ?? 'device',
      serverUrl: s['server_url'],
    );
  }
}

class AppAlert {
  final String title, body;
  const AppAlert(this.title, this.body);
}

/// ناقل التنبيهات الداخلية: كل إشعار يُنشأ في التطبيق يمر من هنا، فيُشغَّل الصوت
/// (إن كان مفعّلًا) وتعرض الواجهة نافذة منبثقة (إن كانت مفعّلة).
class AppAlerts {
  AppAlerts._();
  static final StreamController<AppAlert> _c = StreamController.broadcast();
  static Stream<AppAlert> get stream => _c.stream;

  static void emit(String title, String body) {
    if (AppPrefs.current.sound) {
      try {
        SystemSound.play(SystemSoundType.alert);
      } catch (_) {}
    }
    if (AppPrefs.current.popup && _c.hasListener) {
      _c.add(AppAlert(title, body));
    }
  }
}
