import 'package:flutter/services.dart';

/// Plays original Arabic MP3 time clips on Android, with native Arabic TTS
/// fallback. Audio is optional and must never block the irrigation form.
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

  /// Label, hour, optional conjunction + minute, then AM/PM.
  static List<String> clipSequence(DateTime time, {required bool isStart}) {
    final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final clips = <String>[isStart ? 'from' : 'to', 'h_$hour'];
    if (time.minute > 0) clips.addAll(['and', 'n_${time.minute}']);
    clips.add(time.hour < 12 ? 'am' : 'pm');
    return clips;
  }

  static Future<void> announce(DateTime time, {
    required bool isStart,
    required bool enabled,
  }) async {
    if (!enabled) return;
    final text = announcementText(time, isStart: isStart);
    try {
      final played = await _channel.invokeMethod<bool>(
        'playTimeClips', {'clips': clipSequence(time, isStart: isStart)},
      );
      if (played == true) return;
    } catch (_) {
      // MP3 playback may be unavailable on this platform or device.
    }
    try {
      await _channel.invokeMethod<bool>('announceTime', {'text': text});
    } catch (_) {
      // Optional sound must not affect irrigation entry or saving.
    }
  }
}
