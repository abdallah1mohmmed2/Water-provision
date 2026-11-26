import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/services/irrigation_time_voice_service.dart';

void main() {
  test('announces start time in Arabic', () {
    expect(
      IrrigationTimeVoiceService.announcementText(
        DateTime(2026, 11, 26, 8, 25),
        isStart: true,
      ),
      'بداية السقاية، الساعة 8 و25 دقيقة صباحاً',
    );
  });

  test('handles midnight and noon without a zero-minute phrase', () {
    expect(
      IrrigationTimeVoiceService.announcementText(
        DateTime(2026, 11, 26, 0, 0),
        isStart: false,
      ),
      'نهاية السقاية، الساعة 12 صباحاً',
    );
    expect(
      IrrigationTimeVoiceService.announcementText(
        DateTime(2026, 11, 26, 12, 0),
        isStart: false,
      ),
      'نهاية السقاية، الساعة 12 مساءً',
    );
  });

  test('announces non-zero minutes', () {
    expect(
      IrrigationTimeVoiceService.announcementText(
        DateTime(2026, 11, 26, 21, 5),
        isStart: false,
      ),
      'نهاية السقاية، الساعة 9 و5 دقيقة مساءً',
    );
  });
}
