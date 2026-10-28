import 'package:intl/intl.dart';

/// Editable Arabic message templates. Placeholder labels are user-friendly;
/// users insert them through the settings UI, never by typing token syntax.
class MessageTemplateService {
  static const irrigationKey = 'message_template_irrigation';
  static const receiptKey = 'message_template_receipt';
  static const paymentKey = 'message_template_payment';

  static const defaults = <String, String>{
    irrigationKey: 'السلام عليكم {اسم العميل}،\nتم تسجيل سقاية جديدة.\nتاريخ السقاية: {تاريخ السقاية}\nمن: {وقت البداية}\nإلى: {وقت النهاية}\nإجمالي الدقائق: {إجمالي الدقائق}\nقيمة السقاية: {قيمة السقاية}\nالمدفوع: {المبلغ المدفوع}\nالمتبقي من السقاية: {المتبقي من السقاية}\nالرصيد السابق: {الرصيد السابق}\nالرصيد الحالي: {الرصيد الحالي}',
    receiptKey: 'السلام عليكم {اسم العميل}،\nتم استلام مبلغ.\nتاريخ القبض: {التاريخ}\nرقم السند: {رقم السند}\nالمبلغ المقبوض: {المبلغ}\nطريقة القبض: {طريقة الدفع}\nالبيان: {البيان}\nالرصيد السابق: {الرصيد السابق}\nالرصيد الحالي: {الرصيد الحالي}',
    paymentKey: 'السلام عليكم {اسم العميل}،\nتم صرف مبلغ لكم.\nتاريخ الدفع: {التاريخ}\nرقم السند: {رقم السند}\nالمبلغ المدفوع: {المبلغ}\nطريقة الدفع: {طريقة الدفع}\nالبيان: {البيان}\nالرصيد السابق: {الرصيد السابق}\nالرصيد الحالي: {الرصيد الحالي}',
  };

  static const fields = <String, List<String>>{
    irrigationKey: ['اسم العميل','تاريخ السقاية','وقت البداية','وقت النهاية','إجمالي الدقائق','قيمة السقاية','المبلغ المدفوع','المتبقي من السقاية','الرصيد السابق','الرصيد الحالي','رقم العملية'],
    receiptKey: ['اسم العميل','التاريخ','رقم السند','المبلغ','طريقة الدفع','البيان','الرصيد السابق','الرصيد الحالي'],
    paymentKey: ['اسم العميل','التاريخ','رقم السند','المبلغ','طريقة الدفع','البيان','الرصيد السابق','الرصيد الحالي'],
  };

  static String render(String? saved, String key, Map<String, Object?> values) {
    var result = (saved == null || saved.trim().isEmpty ? defaults[key] : saved) ?? '';
    for (final field in fields[key] ?? const <String>[]) {
      final value = values[field];
      result = result.replaceAll('{$field}', value?.toString() ?? '—');
    }
    // Never leak unknown placeholders to the recipient.
    result = result.replaceAll(RegExp(r'\{[^{}]+\}'), '—');
    return result;
  }

  static String preview(String template) => template.replaceAllMapped(
    RegExp(r'\{([^{}]+)\}'),
    (m) => switch (m.group(1)) {
      'اسم العميل' => 'أحمد محمد',
      'تاريخ السقاية' || 'التاريخ' => DateFormat('yyyy/MM/dd').format(DateTime(2026, 10, 28)),
      'وقت البداية' => '08:00 ص',
      'وقت النهاية' => '09:30 ص',
      'إجمالي الدقائق' => '90',
      'قيمة السقاية' => '2,000 ريال',
      'المبلغ المدفوع' || 'المبلغ' => '500 ريال',
      'المتبقي من السقاية' => '1,500 ريال',
      'الرصيد السابق' => '5,000 ريال عليه',
      'الرصيد الحالي' => '6,500 ريال عليه',
      'رقم السند' || 'رقم العملية' => '125',
      'طريقة الدفع' => 'نقدًا',
      'البيان' => 'تسديد حساب',
      _ => '—',
    },
  );
}
