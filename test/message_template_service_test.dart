import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/services/message_template_service.dart';

void main() {
  group('MessageTemplateService live templates', () {
    test('renders irrigation fields and hides unknown placeholders', () {
      final message = MessageTemplateService.render(
        '{اسم العميل}|{تاريخ السقاية}|{وقت البداية}|{وقت النهاية}|'
        '{إجمالي الدقائق}|{قيمة السقاية}|{المبلغ المدفوع}|'
        '{المتبقي من السقاية}|{الرصيد السابق}|{الرصيد الحالي}|{رقم العملية}|'
        '{حقل غير معروف}',
        MessageTemplateService.irrigationKey,
        {
          'اسم العميل': 'أحمد',
          'تاريخ السقاية': '2026/10/28',
          'وقت البداية': '08:00',
          'وقت النهاية': '09:30',
          'إجمالي الدقائق': '90',
          'قيمة السقاية': '2000 ريال',
          'المبلغ المدفوع': '500 ريال',
          'المتبقي من السقاية': '1500 ريال',
          'الرصيد السابق': 'عليه 5000 ريال',
          'الرصيد الحالي': 'عليه 6500 ريال',
          'رقم العملية': '125',
        },
      );

      expect(message, contains('أحمد|2026/10/28|08:00|09:30|90'));
      expect(message, contains('عليه 5000 ريال|عليه 6500 ريال|125'));
      expect(message, isNot(contains('{')));
    });

    test('renders receipt and payment templates with actual transaction fields', () {
      final values = <String, Object?>{
        'اسم العميل': 'سالم',
        'التاريخ': '2026/10/28 10:15',
        'رقم السند': 'R-125',
        'المبلغ': '700 ريال',
        'طريقة الدفع': 'نقدًا',
        'البيان': 'تسديد حساب',
        'الرصيد السابق': 'عليه 2000 ريال',
        'الرصيد الحالي': 'عليه 1300 ريال',
      };

      final receipt = MessageTemplateService.render(
        '{اسم العميل}|{التاريخ}|{رقم السند}|{المبلغ}|{طريقة الدفع}|'
        '{البيان}|{الرصيد السابق}|{الرصيد الحالي}',
        MessageTemplateService.receiptKey,
        values,
      );
      final payment = MessageTemplateService.render(
        '{اسم العميل}|{التاريخ}|{رقم السند}|{المبلغ}|{طريقة الدفع}|'
        '{البيان}|{الرصيد السابق}|{الرصيد الحالي}',
        MessageTemplateService.paymentKey,
        values,
      );

      expect(receipt, 'سالم|2026/10/28 10:15|R-125|700 ريال|نقدًا|تسديد حساب|عليه 2000 ريال|عليه 1300 ريال');
      expect(payment, receipt);
      expect(receipt, isNot(contains('{')));
    });

    test('uses defaults when the saved template is empty', () {
      final message = MessageTemplateService.render(
        '   ',
        MessageTemplateService.receiptKey,
        const {},
      );

      expect(message, contains('{اسم العميل}'));
    });
  });
}
