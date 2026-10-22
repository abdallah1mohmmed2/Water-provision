import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/services/manual_message_service.dart';

void main() {
  group('ManualMessageService phone normalization', () {
    test('adds Yemen country code to a local mobile number', () {
      expect(
        ManualMessageService.normalizePhoneDigits('771234567'),
        '967771234567',
      );
      expect(
        ManualMessageService.normalizePhoneDigits('0771234567'),
        '967771234567',
      );
    });

    test('accepts international numbers and Arabic numerals', () {
      expect(
        ManualMessageService.normalizePhoneDigits('+967 77 123 4567'),
        '967771234567',
      );
      expect(
        ManualMessageService.normalizePhoneDigits('٠٧٧١٢٣٤٥٦٧'),
        '967771234567',
      );
    });

    test('rejects a number that is too short', () {
      expect(
        () => ManualMessageService.normalizePhoneDigits('1234'),
        throwsFormatException,
      );
    });
  });

  group('ManualMessageService message links', () {
    const phone = '771234567';
    const message = 'السلام عليكم، تم تسجيل دفعتكم: ١٠٠ ريال';

    test('creates an SMS composer URI with the message prefilled', () {
      final uri = ManualMessageService.smsUri(phone, message);

      expect(uri.scheme, 'sms');
      expect(uri.path, '967771234567');
      expect(uri.queryParameters['body'], message);
    });

    test('creates a WhatsApp one-to-one link with the message prefilled', () {
      final uri = ManualMessageService.whatsappUri(phone, message);

      expect(uri.scheme, 'https');
      expect(uri.host, 'wa.me');
      expect(uri.path, '/967771234567');
      expect(uri.queryParameters['text'], message);
    });
  });
}
