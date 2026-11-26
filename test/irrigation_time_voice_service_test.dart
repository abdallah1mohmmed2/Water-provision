import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/services/irrigation_time_voice_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('saqia/irrigation_time_voice');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    channel.setMockMethodCallHandler((call) async {
      calls.add(call);
      return call.method == 'playTimeClips' ? true : true;
    });
  });
  tearDown(() => channel.setMockMethodCallHandler(null));

  test('original clips sequence start and minute', () {
    expect(IrrigationTimeVoiceService.clipSequence(
      DateTime(2026, 11, 26, 8, 25), isStart: true,
    ), ['from', 'h_8', 'and', 'n_25', 'am']);
    expect(IrrigationTimeVoiceService.announcementText(
      DateTime(2026, 11, 26, 8, 25), isStart: true,
    ), 'بداية السقاية، الساعة 8 و25 دقيقة صباحاً');
  });

  test('midnight and noon use hour 12 and correct period', () {
    expect(IrrigationTimeVoiceService.clipSequence(
      DateTime(2026, 11, 26, 0, 0), isStart: false,
    ), ['to', 'h_12', 'am']);
    expect(IrrigationTimeVoiceService.clipSequence(
      DateTime(2026, 11, 26, 12, 0), isStart: false,
    ), ['to', 'h_12', 'pm']);
  });

  test('minute zero skips conjunction and minute clip', () {
    expect(IrrigationTimeVoiceService.clipSequence(
      DateTime(2026, 11, 26, 21, 0), isStart: false,
    ), ['to', 'h_9', 'pm']);
  });

  test('minute and evening clips are mapped', () {
    expect(IrrigationTimeVoiceService.clipSequence(
      DateTime(2026, 11, 26, 21, 5), isStart: false,
    ), ['to', 'h_9', 'and', 'n_5', 'pm']);
  });

  test('falls back to TTS when clip playback fails', () async {
    calls.clear();
    channel.setMockMethodCallHandler((call) async {
      calls.add(call);
      if (call.method == 'playTimeClips') return false;
      return true;
    });
    await IrrigationTimeVoiceService.announce(
      DateTime(2026, 11, 26, 8, 25), isStart: true, enabled: true,
    );
    expect(calls.map((call) => call.method), ['playTimeClips', 'announceTime']);
  });

  test('disabled sound performs no channel calls', () async {
    calls.clear();
    await IrrigationTimeVoiceService.announce(
      DateTime(2026, 11, 26, 8, 25), isStart: true, enabled: false,
    );
    expect(calls, isEmpty);
  });
}
