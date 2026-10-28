/// تعريف قوالب رسائل السقاية والقبض والدفع واستبدال حقولها.
///
/// هذا الملف مستقل عن قاعدة البيانات؛ تُحفظ نصوص القوالب في إعدادات التطبيق.
class MessageTemplateService {
  static const irrigationKey = 'message_template_irrigation';
  static const receiptKey = 'message_template_receipt';
  static const paymentKey = 'message_template_payment';

  static const Map<String, String> defaults = {
    irrigationKey:
        'السقاية: {اسم العميل}\nالتاريخ: {تاريخ السقاية}\nمن {وقت البداية} إلى {وقت النهاية} ({إجمالي الدقائق} دقيقة)\nالقيمة: {قيمة السقاية}\nالمدفوع: {المبلغ المدفوع}\nالمتبقي: {المتبقي من السقاية}\nالرصيد السابق: {الرصيد السابق}\nالرصيد الحالي: {الرصيد الحالي}\nرقم العملية: {رقم العملية}',
    receiptKey:
        'سند قبض\nالاسم: {اسم العميل}\nالتاريخ: {التاريخ}\nرقم السند: {رقم السند}\nالمبلغ: {المبلغ}\nطريقة الدفع: {طريقة الدفع}\nالبيان: {البيان}\nالرصيد السابق: {الرصيد السابق}\nالرصيد الحالي: {الرصيد الحالي}',
    paymentKey:
        'سند دفع\nالاسم: {اسم العميل}\nالتاريخ: {التاريخ}\nرقم السند: {رقم السند}\nالمبلغ: {المبلغ}\nطريقة الدفع: {طريقة الدفع}\nالبيان: {البيان}\nالرصيد السابق: {الرصيد السابق}\nالرصيد الحالي: {الرصيد الحالي}',
  };

  static const Map<String, List<String>> fields = {
    irrigationKey: [
      'اسم العميل',
      'تاريخ السقاية',
      'وقت البداية',
      'وقت النهاية',
      'إجمالي الدقائق',
      'قيمة السقاية',
      'المبلغ المدفوع',
      'المتبقي من السقاية',
      'الرصيد السابق',
      'الرصيد الحالي',
      'رقم العملية',
    ],
    receiptKey: [
      'اسم العميل',
      'التاريخ',
      'رقم السند',
      'المبلغ',
      'طريقة الدفع',
      'البيان',
      'الرصيد السابق',
      'الرصيد الحالي',
    ],
    paymentKey: [
      'اسم العميل',
      'التاريخ',
      'رقم السند',
      'المبلغ',
      'طريقة الدفع',
      'البيان',
      'الرصيد السابق',
      'الرصيد الحالي',
    ],
  };

  static String render(
    Object? savedTemplate,
    String key,
    Map<String, Object?> values,
  ) {
    final saved = savedTemplate?.toString() ?? '';
    final template = saved.trim().isEmpty ? (defaults[key] ?? '') : saved;
    final knownFields = fields[key] ?? const <String>[];
    return template.replaceAllMapped(RegExp(r'\{([^{}]+)\}'), (match) {
      final name = match.group(1)!.trim();
      if (!knownFields.contains(name)) return '';
      final value = values[name];
      final text = value == null ? '' : value.toString().trim();
      return text.isEmpty ? '—' : text;
    }).trim();
  }

  static String preview(String template) {
    const samples = <String, Object?>{
      'اسم العميل': 'أحمد محمد',
      'تاريخ السقاية': '2026/10/28',
      'وقت البداية': '08:00 ص',
      'وقت النهاية': '09:30 ص',
      'إجمالي الدقائق': '90',
      'قيمة السقاية': '2000 ريال',
      'المبلغ المدفوع': '500 ريال',
      'المتبقي من السقاية': '1500 ريال',
      'التاريخ': '2026/10/28 10:15',
      'رقم السند': 'R-125',
      'المبلغ': '700 ريال',
      'طريقة الدفع': 'نقدًا',
      'البيان': 'تسديد حساب',
      'الرصيد السابق': 'عليه 2000 ريال',
      'الرصيد الحالي': 'عليه 1300 ريال',
      'رقم العملية': '125',
    };
    for (final key in defaults.keys) {
      if (fields[key]!.any((field) => template.contains('{$field}'))) {
        return render(template, key, samples);
      }
    }
    return template.replaceAll(RegExp(r'\{[^{}]*\}'), '—');
  }
}
