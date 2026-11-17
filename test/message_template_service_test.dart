import 'package:saqia_station/core/message_time.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/services/message_template_service.dart';

void main() {
  group('MessageTemplateService live templates', () {
    test('message clocks use 12 hours with Arabic periods for every system', () {
      for (final system in ['diesel', 'solar', 'equivalent_hybrid']) {
        final values = <String,Object?>{
          'وقت البداية': MessageTime.time(DateTime(2026, 11, 17, 13, 5)),
          'وقت النهاية': MessageTime.time(DateTime(2026, 11, 17, 23, 45)),
        };
        expect(MessageTemplateService.render('{وقت البداية} / {وقت النهاية}', MessageTemplateService.irrigationKey, values, systemType: system), '01:05 م / 11:45 م');
      }
      expect(MessageTime.time(DateTime(2026, 1, 1)), '12:00 ص');
      expect(MessageTime.time(DateTime(2026, 1, 1, 12)), '12:00 م');
      expect(MessageTime.dateTime(DateTime(2026, 1, 2, 13, 5)), '2026/01/02 01:05 م');
    });

    test('fuel fields and defaults belong only to diesel irrigation templates', () {
      const key = MessageTemplateService.irrigationKey;
      const saved = 'رسالة خاصة\nالاسم: {اسم العميل}\nاستهلاك: {الديزل المستهلك}\nالوقود المتبقي: {رصيد الديزل المتبقي}';
      const values = {'اسم العميل':'سالم', 'الديزل المستهلك':'9.3 لتر', 'رصيد الديزل المتبقي':'عليه 3.55 لتر'};
      final diesel = MessageTemplateService.render(saved, key, values, systemType: 'diesel');
      expect(diesel, contains('9.3 لتر'));
      expect(diesel, contains('عليه 3.55 لتر'));
      expect(diesel, startsWith('رسالة خاصة'));
      expect(MessageTemplateService.availableFields(key, systemType: 'diesel'), containsAll(MessageTemplateService.dieselFields));
      expect(MessageTemplateService.defaultFor(key, systemType: 'diesel'), contains('{الديزل المستهلك}'));
      for (final system in ['solar', 'equivalent_hybrid']) {
        expect(MessageTemplateService.render(saved, key, values, systemType: system), 'رسالة خاصة\nالاسم: سالم');
        expect(MessageTemplateService.availableFields(key, systemType: system), isNot(contains('الديزل المستهلك')));
        expect(MessageTemplateService.defaultFor(key, systemType: system), isNot(contains('ديزل')));
      }
      for (final key in [MessageTemplateService.receiptKey, MessageTemplateService.paymentKey]) {
        expect(MessageTemplateService.availableFields(key, systemType: 'diesel'), isNot(contains('الديزل المستهلك')));
      }
      expect(MessageTemplateService.preview(saved, key: key, systemType: 'diesel'), contains('عليه 3.55 لتر'));
    });

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

    test('uses defaults only when no template was saved', () {
      final message = MessageTemplateService.render(
        null,
        MessageTemplateService.receiptKey,
        const {},
      );

      expect(message, contains('—'));
      expect(message, isNot(contains('{')));
    });
    test('explicitly cleared templates and previews never restore themselves', () {
      for (final system in ['diesel', 'solar', 'equivalent_hybrid']) {
        for (final key in MessageTemplateService.defaults.keys) {
          for (final deleted in ['', '   ']) {
            expect(MessageTemplateService.render(deleted, key, const {}, systemType: system), isEmpty);
            expect(MessageTemplateService.preview(deleted, key: key, systemType: system), isEmpty);
          }
          expect(MessageTemplateService.render(null, key, const {}, systemType: system), isNotEmpty);
        }
      }
    });
  });
}
