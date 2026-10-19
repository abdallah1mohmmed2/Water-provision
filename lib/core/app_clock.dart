import 'dart:convert';
import 'package:http/http.dart' as http;

/// مصدر الوقت الوحيد للتطبيق (إعداد «مصدر الوقت»).
///
/// - `device`: وقت الجهاز.
/// - `server`: وقت الخادم عبر `GET /api/v1/time` مع تعويض زمن الاتصال؛ إن تعذّر الوصول
///   يرجع إلى وقت الجهاز ويُحفظ [lastSyncOk] = false لتنبيه المستخدم.
///
/// كل الكود يستدعي [AppClock.now] بدل `DateTime.now()` حتى تتبع القيود والجلسات والتقارير
/// المصدر المختار.
class AppClock {
  AppClock._();
  static Duration _offset = Duration.zero;
  static String _source = 'device';
  static bool lastSyncOk = true;

  static String get source => _source;
  static Duration get offset => _offset;
  static DateTime now() => DateTime.now().add(_offset);

  static Future<void> configure({
    required String source,
    String? serverUrl,
    http.Client? client,
  }) async {
    _source = source == 'server' ? 'server' : 'device';
    if (_source != 'server') {
      _offset = Duration.zero;
      lastSyncOk = true;
      return;
    }
    final base = (serverUrl ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      _offset = Duration.zero;
      lastSyncOk = false;
      return;
    }
    final c = client ?? http.Client();
    try {
      final t0 = DateTime.now();
      final r = await c
          .get(Uri.parse('$base/api/v1/time'))
          .timeout(const Duration(seconds: 5));
      final t1 = DateTime.now();
      if (r.statusCode < 200 || r.statusCode >= 300) throw StateError('status');
      final serverNow = DateTime.parse(
        '${(jsonDecode(r.body) as Map)['now']}',
      ).toLocal();
      final midpoint = t0.add(Duration(microseconds: t1.difference(t0).inMicroseconds ~/ 2));
      _offset = serverNow.difference(midpoint);
      lastSyncOk = true;
    } catch (_) {
      _offset = Duration.zero;
      lastSyncOk = false;
    } finally {
      if (client == null) c.close();
    }
  }
}
