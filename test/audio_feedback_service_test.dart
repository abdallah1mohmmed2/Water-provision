import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/services/audio_feedback_service.dart';

void main() {
  setUp(AudioFeedbackService.resetForTesting);

  test('muted feedback does not invoke the sound player', () async {
    var calls = 0;
    AudioFeedbackService.soundPlayerForTesting = (_) async => calls++;
    await AudioFeedbackService.play(AudioFeedbackEvent.success, enabled: false);
    expect(calls, 0);
  });

  test('success uses click and important events use alert sound', () async {
    final played = <SystemSoundType>[];
    AudioFeedbackService.soundPlayerForTesting = (sound) async => played.add(sound);
    await AudioFeedbackService.play(AudioFeedbackEvent.success, enabled: true);
    await AudioFeedbackService.play(AudioFeedbackEvent.error, enabled: true);
    expect(played, [SystemSoundType.click, SystemSoundType.alert]);
  });

  test('repeated success feedback is throttled', () async {
    var calls = 0;
    AudioFeedbackService.soundPlayerForTesting = (_) async => calls++;
    await AudioFeedbackService.play(AudioFeedbackEvent.success, enabled: true);
    await AudioFeedbackService.play(AudioFeedbackEvent.success, enabled: true);
    expect(calls, 1);
  });

  test('platform sound failure is swallowed safely', () async {
    AudioFeedbackService.soundPlayerForTesting = (_) async => throw Exception('no audio');
    await expectLater(
      AudioFeedbackService.play(AudioFeedbackEvent.error, enabled: true),
      completes,
    );
  });
}
