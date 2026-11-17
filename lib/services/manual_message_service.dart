import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/message_time.dart';
import 'package:url_launcher/url_launcher.dart';

enum ManualMessageChannel { sms, whatsapp }

/// Opens a prefilled one-to-one message composer; it never sends the message.
class ManualMessageService {
  static String accountSummaryMessage({
    required String recipientName,
    required String partyLabel,
    required String balanceLabel,
    required DateTime asOf,
  }) => [
    'كشف حساب مختصر',
    '$partyLabel: $recipientName',
    'الرصيد الحالي: $balanceLabel',
    'أُعدّ بتاريخ: ${MessageTime.dateTime(asOf)}',
  ].join('\n');

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
    query: 'body=${Uri.encodeComponent(message)}',
  );

  static Uri whatsappUri(String phone, String message) {
    final digits = normalizePhoneDigits(phone);
    return Uri.https('wa.me', '/$digits', {'text': message});
  }

  static Uri _whatsappAppUri(String phone, String message) => Uri(
    scheme: 'whatsapp',
    host: 'send',
    query: 'phone=${normalizePhoneDigits(phone)}&text=${Uri.encodeComponent(message)}',
  );

  static const smsComposerChannel = MethodChannel('saqia/message_composer');

  /// Android's native composer receives the complete text as an Intent extra.
  /// No SEND_SMS permission or automatic sending is involved.
  static Future<bool> openNativeSms(String phone, String message) async {
    try {
      return await smsComposerChannel.invokeMethod<bool>('composeSms', {
        'phone': normalizePhoneDigits(phone),
        'message': message,
      }) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> open(
    ManualMessageChannel channel, {
    required String phone,
    required String message,
  }) async {
    if (channel == ManualMessageChannel.sms) {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android &&
          await openNativeSms(phone, message)) {
        return true;
      }
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

  static bool _choosing = false;

  static Future<void> offerChoices(
    BuildContext context, {
    required String title,
    required String recipientName,
    required String phone,
    required String message,
    String? notice,
  }) async {
    // A double tap must not stack a second composer with the original text.
    if (_choosing) return;
    _choosing = true;
    try {
      final choice = await showDialog<_MessageChoice>(
        context: context,
        builder: (_) => _MessageDraftDialog(
          title: title,
          recipientName: recipientName,
          phone: phone,
          initialMessage: message,
          notice: notice,
        ),
      );
      if (choice == null || !context.mounted) return;
      try {
        final opened = await open(choice.channel, phone: phone, message: choice.message);
        if (!opened && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تعذر فتح التطبيق. يمكنك نسخ النص والمحاولة مجددًا.')),
          );
        }
      } on FormatException catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message.toString())));
        }
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تعذر فتح تطبيق الرسائل لهذا الرقم.')),
          );
        }
      }
    } finally {
      _choosing = false;
    }
  }
}

class _MessageChoice {
  final ManualMessageChannel channel;
  final String message;
  const _MessageChoice(this.channel, this.message);
}

class _MessageDraftDialog extends StatefulWidget {
  const _MessageDraftDialog({
    required this.title,
    required this.recipientName,
    required this.phone,
    required this.initialMessage,
    this.notice,
  });
  final String title, recipientName, phone, initialMessage;
  final String? notice;
  @override
  State<_MessageDraftDialog> createState() => _MessageDraftDialogState();
}

class _MessageDraftDialogState extends State<_MessageDraftDialog> {
  late final TextEditingController draft;
  bool chosen = false;
  @override
  void initState() {
    super.initState();
    draft = TextEditingController(text: widget.initialMessage);
  }
  @override
  void dispose() {
    draft.dispose();
    super.dispose();
  }
  void choose(ManualMessageChannel channel) {
    if (chosen || draft.text.trim().isEmpty || widget.phone.trim().isEmpty) return;
    chosen = true;
    Navigator.pop(context, _MessageChoice(channel, draft.text));
  }
  @override
  Widget build(BuildContext context) {
    final hasText = draft.text.trim().isNotEmpty;
    final canOpen = hasText && widget.phone.trim().isNotEmpty && !chosen;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: SizedBox(
        width: 480,
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.phone.trim().isEmpty
                ? 'لا يوجد رقم هاتف مسجل لـ${widget.recipientName}. يمكنك نسخ النص أو إضافة الرقم إلى بياناته.'
                : 'راجع رسالة ${widget.recipientName} وعدّلها قبل فتح التطبيق. الإرسال النهائي من داخل تطبيق الرسائل.'),
              if (widget.notice != null) ...[
                const SizedBox(height: 8),
                Text(widget.notice!),
              ],
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('manual-message-draft'),
                controller: draft,
                minLines: 3,
                maxLines: 7,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'نص الرسالة', border: OutlineInputBorder()),
              ),
              TextButton.icon(
                onPressed: () => setState(() => draft.text = widget.initialMessage),
                icon: const Icon(Icons.restore),
                label: const Text('إعادة تجهيز النص'),
              ),
            ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: !hasText ? null : () async {
            await Clipboard.setData(ClipboardData(text: draft.text));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('تم نسخ نص الرسالة')),
              );
            }
          },
          icon: const Icon(Icons.copy_rounded),
          label: const Text('نسخ نص الرسالة'),
        ),
        TextButton(onPressed: canOpen ? () => choose(ManualMessageChannel.sms) : null, child: const Text('فتح SMS')),
        TextButton(onPressed: canOpen ? () => choose(ManualMessageChannel.whatsapp) : null, child: const Text('فتح WhatsApp')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('لاحقًا')),
      ],
    );
  }
}
