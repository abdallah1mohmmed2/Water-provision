import 'package:flutter/services.dart';

/// Short, offline, device-native feedback. No bundled audio assets or network use.
enum AudioFeedbackEvent { success, error, notification, warning }

class AudioFeedbackService {
  AudioFeedbackService._();

  static Future<void> Function(SystemSoundType type)? soundPlayerForTesting;
  static DateTime? _lastSuccessAt;
  static DateTime? _lastAlertAt;

  static Future<void> play(
    AudioFeedbackEvent event, {
    required bool enabled,
  }) async {
    if (!enabled) return;
    final now = DateTime.now();
    if (event == AudioFeedbackEvent.success) {
      if (_lastSuccessAt != null &&
          now.difference(_lastSuccessAt!) < const Duration(milliseconds: 260)) {
        return;
      }
      _lastSuccessAt = now;
    } else {
      if (_lastAlertAt != null &&
          now.difference(_lastAlertAt!) < const Duration(milliseconds: 850)) {
        return;
      }
      _lastAlertAt = now;
    }

    final sound = event == AudioFeedbackEvent.success
        ? SystemSoundType.click
        : SystemSoundType.alert;
    try {
      final testPlayer = soundPlayerForTesting;
      if (testPlayer != null) {
        await testPlayer(sound);
      } else {
        await SystemSound.play(sound);
      }
    } catch (_) {
      // Audio is optional; failure must never interrupt accounting or navigation.
    }
  }

  static void resetForTesting() {
    soundPlayerForTesting = null;
    _lastSuccessAt = null;
    _lastAlertAt = null;
  }
}
