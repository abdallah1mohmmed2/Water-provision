import 'package:flutter/services.dart';

/// Arabic voice confirmation for start/end selection in the quick irrigation form.
/// Voice feedback is optional and must never block accounting or navigation.
class IrrigationTimeVoiceService {
  IrrigationTimeVoiceService._();

  static const MethodChannel _channel =
      MethodChannel('saqia/irrigation_time_voice');

  static String announcementText(DateTime time, {required bool isStart}) {
    final hour12 = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final minuteText = time.minute == 0 ? '' : ' و${time.minute} دقيقة';
    final period = time.hour < 12 ? 'صباحاً' : 'مساءً';
    final label = isStart ? 'بداية السقاية' : 'نهاية السقاية';
    return '$label، الساعة $hour12$minuteText $period';
  }

  static Future<void> announce(
    DateTime time, {
    required bool isStart,
    required bool enabled,
  }) async {
    if (!enabled) return;
    try {
      // Native Android returns immediately after enqueueing speech. Avoid a timeout
      // timer here: fire-and-forget widget flows may dispose before it fires.
      await _channel.invokeMethod<bool>(
        'announceTime',
        {'text': announcementText(time, isStart: isStart)},
      );
    } catch (_) {
      // Arabic TTS may be unavailable; that is harmless and does not affect the form.
    }
  }
}
