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

  static const dieselFields = [
    'الديزل المستهلك', 'رصيد الديزل المتبقي', 'ديزل له', 'ديزل عليه',
  ];

  static List<String> availableFields(String key, {String? systemType}) => [
    ...(fields[key] ?? const <String>[]),
    if (key == irrigationKey && systemType == 'diesel') ...dieselFields,
  ];

  static String defaultFor(String key, {String? systemType}) =>
      '${defaults[key] ?? ''}${key == irrigationKey && systemType == 'diesel' ? '\nالديزل المستهلك: {الديزل المستهلك}\nرصيد الديزل المتبقي: {رصيد الديزل المتبقي}' : ''}';

  static String render(
    Object? savedTemplate,
    String key,
    Map<String, Object?> values, {
    String? systemType,
  }) {
    // A saved empty template is an explicit deletion, not a request to restore.
    var template = savedTemplate == null
        ? defaultFor(key, systemType: systemType)
        : savedTemplate.toString();
    final knownFields = availableFields(key, systemType: systemType);
    // Hide fuel-only lines in a template copied from a diesel station. Keep
    // mixed lines' ordinary fields; unavailable fuel tokens render empty.
    if (systemType != 'diesel') {
      template = template.split('\n').where((line) {
        final tokens = RegExp(r'\{([^{}]+)\}').allMatches(line).map((m) => m.group(1)!.trim()).toList();
        return !tokens.any(dieselFields.contains) || tokens.any(knownFields.contains);
      }).join('\n');
    }
    return template.replaceAllMapped(RegExp(r'\{([^{}]+)\}'), (match) {
      final name = match.group(1)!.trim();
      if (!knownFields.contains(name)) return '';
      final value = values[name];
      final text = value == null ? '' : value.toString().trim();
      return text.isEmpty ? '—' : text;
    }).trim();
  }

  static String preview(String template, {String? key, String? systemType}) {
    const samples = <String, Object?>{
      'اسم العميل': 'أحمد محمد',
      'تاريخ السقاية': '2026/10/28',
      'وقت البداية': '08:00 ص',
      'وقت النهاية': '09:30 ص',
      'إجمالي الدقائق': '90',
      'قيمة السقاية': '2000 ريال',
      'المبلغ المدفوع': '500 ريال',
      'المتبقي من السقاية': '1500 ريال',
      'التاريخ': '2026/10/28 01:15 م',
      'الديزل المستهلك': '9.3 لتر',
      'رصيد الديزل المتبقي': 'عليه 3.55 لتر',
      'ديزل له': '0 لتر',
      'ديزل عليه': '3.55 لتر',
      'رقم السند': 'R-125',
      'المبلغ': '700 ريال',
      'طريقة الدفع': 'نقدًا',
      'البيان': 'تسديد حساب',
      'الرصيد السابق': 'عليه 2000 ريال',
      'الرصيد الحالي': 'عليه 1300 ريال',
      'رقم العملية': '125',
    };
    if (key != null) {
      return render(template, key, samples, systemType: systemType);
    }
    for (final key in defaults.keys) {
      if (fields[key]!.any((field) => template.contains('{$field}'))) {
        return render(template, key, samples, systemType: systemType);
      }
    }
    return template.replaceAll(RegExp(r'\{[^{}]*\}'), '—');
  }
}
