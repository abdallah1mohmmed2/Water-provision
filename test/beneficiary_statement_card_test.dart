import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/features/beneficiary_statement_card.dart';

Future<void> showCard(WidgetTester tester, Map<String, Object?> row,
    {double width = 360, double scale = 1}) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, 2400), textScaler: TextScaler.linear(scale)),
      child: Directionality(textDirection: TextDirection.rtl,
        child: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(18),
          child: BeneficiaryStatementCard(row: row)))),
    ),
  ));
}

void main() {
  testWidgets('irrigation shows only requested fields and saved times', (tester) async {
    final row = <String, Object?>{
      'type': 's', 'date': '2026-11-14',
      'start_datetime': '2026-11-14T09:15:00',
      'end_datetime': '2026-11-14T10:45:00',
      'minutes': 90, 'cloud_minutes': 10, 'total_amount': 9600,
      'paid_amount': 2000, 'balance': 12600, 'debit': 9600, 'credit': 0,
      'notes': 'لا تظهر ملاحظات السقاية', 'system_type': 'solar',
    };
    final original = Map<String, Object?>.from(row);
    await showCard(tester, row);
    for (final label in ['تسقية', 'تاريخ السقو', 'الوقت', 'المدة بالدقائق',
      'دقائق الغيم', 'الإجمالي', 'المدفوع', 'المتبقي']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('من 09:15 إلى 10:45'), findsOneWidget);
    expect(find.text('عليه 12,600'), findsOneWidget);
    expect(find.text('الرصيد السابق'), findsNothing);
    expect(find.text('الملاحظات'), findsNothing);
    expect(find.text('لا تظهر ملاحظات السقاية'), findsNothing);
    expect(row, original);
    expect(tester.takeException(), isNull);
  });

  testWidgets('receipt preserves previous and remaining balance signs', (tester) async {
    await showCard(tester, {
      'type': 'p', 'date': '2026-11-14', 'debit': 0, 'credit': 1500,
      'paid_amount': -1500, 'balance': -500, 'notes': 'دفعة الحساب',
    });
    expect(find.text('قبض'), findsOneWidget);
    expect(find.text('عليه 1,000'), findsOneWidget);
    expect(find.text('له 500'), findsOneWidget);
    expect(find.text('1,500'), findsOneWidget);
    expect(find.text('دفعة الحساب'), findsOneWidget);
    expect(find.text('الإجمالي'), findsNothing);
    expect(find.text('دقائق الغيم'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('debt with long notes fits narrow Android at enlarged text', (tester) async {
    await showCard(tester, {
      'type': 'manual_debt', 'date': '2026-11-14',
      'debit': 6000, 'credit': 0, 'balance': 3000,
      'notes': List.filled(15, 'تفاصيل المديونية السابقة').join(' '),
    }, width: 320, scale: 2);
    expect(find.text('مديونية سابقة'), findsOneWidget);
    expect(find.text('له 3,000'), findsOneWidget);
    expect(find.text('عليه 3,000'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disbursement and zero balance are explicit', (tester) async {
    await showCard(tester, {
      'type': 'p', 'date': '2026-11-14',
      'debit': 0, 'credit': -500, 'balance': 0,
    });
    expect(find.text('صرف'), findsOneWidget);
    expect(find.text('له 500'), findsOneWidget);
    expect(find.text('500'), findsOneWidget);
    expect(find.text('0 — متوازن'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
