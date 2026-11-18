import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/core/diesel_quantity.dart';
import 'package:saqia_station/features/party_diesel_balance.dart';
import 'package:saqia_station/services/diesel_report_columns.dart';

void main() {
  test('fuel quantities keep two decimals at most and no negative zero', () {
    expect(DieselQuantity.format(5.75), '5.75');
    expect(DieselQuantity.format(5.5), '5.5');
    expect(DieselQuantity.format(5), '5');
    expect(DieselQuantity.format(100), '100');
    expect(DieselQuantity.format(-5.75), '-5.75');
    expect(DieselQuantity.format(-0.001), '0');
    expect(DieselQuantity.format(1.236), '1.24');
    expect(DieselQuantity.parseInput('5.75'), 5.75);
    for (final invalid in ['5.75000', 'NaN', '1e3', '-5', '0']) {
      expect(DieselQuantity.parseInput(invalid), isNull);
    }
  });

  testWidgets('fuel balances show credit, debt and zero on narrow cards', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body:
      Column(children: [PartyDieselBalance(5.75), PartyDieselBalance(-5.75), PartyDieselBalance(0)]))));
    expect(find.text('ديزل له 5.75 لتر'), findsOneWidget);
    expect(find.text('ديزل عليه 5.75 لتر'), findsOneWidget);
    expect(find.text('رصيد الديزل متعادل'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('diesel PDF replaces cloud, solar preserves it, mixed keeps both', () {
    const columns = ['minutes', 'cloud_minutes', 'cloud_status', 'total_amount'];
    expect(DieselReportColumns.select(columns, dieselOnly: true, hasDiesel: true),
      ['minutes', 'diesel_consumption_liters', 'total_amount']);
    expect(DieselReportColumns.select(columns, dieselOnly: false, hasDiesel: false), columns);
    expect(DieselReportColumns.select(columns, dieselOnly: false, hasDiesel: true),
      ['minutes', 'diesel_consumption_liters', 'cloud_minutes', 'cloud_status', 'total_amount']);
    expect(DieselReportColumns.dieselOnly([{'system_type': 'diesel'}, {'system_type': 'payment'}], 'all'), isTrue);
    expect(DieselReportColumns.dieselOnly([{'system_type': 'solar'}], 'diesel'), isFalse);
    expect(DieselReportColumns.dieselOnly([], 'diesel'), isTrue);
  });
}
