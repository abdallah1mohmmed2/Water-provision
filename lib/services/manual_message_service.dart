import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

enum ManualMessageChannel { sms, whatsapp }

/// Opens a prefilled one-to-one message composer; it never sends the message.
class ManualMessageService {
  static String normalizePhoneDigits(String phone) {
    final westernDigits = phone.replaceAllMapped(RegExp(r'[٠-٩۰-۹]'), (match) {
      final code = match.group(0)!.codeUnitAt(0);
      final digit = code >= 0x06F0 ? code - 0x06F0 : code - 0x0660;
      return '$digit';
    });
    var digits = westernDigits.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('00')) digits = digits.substring(2);

    // The station is configured for Yemen; accept common local mobile forms.
    if (digits.length == 9 && digits.startsWith('7')) {
      digits = '967$digits';
    } else if (digits.length == 10 && digits.startsWith('07')) {
      digits = '967${digits.substring(1)}';
    }

    if (digits.length < 8 || digits.length > 15) {
      throw const FormatException(
        'أدخل رقمًا صحيحًا مع مفتاح الدولة، مثل +9677XXXXXXXX',
      );
    }
    return digits;
  }

  static Uri smsUri(String phone, String message) => Uri(
    scheme: 'sms',
    path: normalizePhoneDigits(phone),
    queryParameters: {'body': message},
  );

  static Uri whatsappUri(String phone, String message) {
    final digits = normalizePhoneDigits(phone);
    return Uri.https('wa.me', '/$digits', {'text': message});
  }

  static Uri _whatsappAppUri(String phone, String message) => Uri(
    scheme: 'whatsapp',
    host: 'send',
    queryParameters: {'phone': normalizePhoneDigits(phone), 'text': message},
  );

  static Future<bool> open(
    ManualMessageChannel channel, {
    required String phone,
    required String message,
  }) async {
    if (channel == ManualMessageChannel.sms) {
      return launchUrl(
        smsUri(phone, message),
        mode: LaunchMode.externalApplication,
      );
    }

    try {
      final openedApp = await launchUrl(
        _whatsappAppUri(phone, message),
        mode: LaunchMode.externalApplication,
      );
      if (openedApp) return true;
    } catch (_) {
      // If WhatsApp is not installed, try its official wa.me link below.
    }
    return launchUrl(
      whatsappUri(phone, message),
      mode: LaunchMode.externalApplication,
    );
  }

  static Future<void> offerChoices(
    BuildContext context, {
    required String title,
    required String recipientName,
    required String phone,
    required String message,
  }) async {
    if (phone.trim().isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(
            'تم حفظ العملية، لكن لا يوجد رقم هاتف مسجل لـ$recipientName. أضف الرقم إلى بيانات الطرف لإتاحة الإرسال.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('حسنًا'),
            ),
          ],
        ),
      );
      return;
    }

    final channel = await showDialog<ManualMessageChannel>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(
          'اختر تطبيقًا لفتح رسالة فردية جاهزة إلى $recipientName. لن تُرسل الرسالة إلا بعد ضغطك على زر الإرسال داخل التطبيق.',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, ManualMessageChannel.sms),
            child: const Text('فتح SMS'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, ManualMessageChannel.whatsapp),
            child: const Text('فتح WhatsApp'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('لاحقًا'),
          ),
        ],
      ),
    );
    if (channel == null || !context.mounted) return;

    try {
      final opened = await open(channel, phone: phone, message: message);
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تعذر فتح التطبيق. تأكد من تثبيت تطبيق الرسائل أو WhatsApp.',
            ),
          ),
        );
      }
    } on FormatException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message.toString())));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر فتح تطبيق الرسائل لهذا الرقم.')),
        );
      }
    }
  }
}
