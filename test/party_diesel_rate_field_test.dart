import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/core/party_diesel_rate.dart';
import 'package:saqia_station/features/party_diesel_rate_field.dart';

void main() {
  testWidgets('personal rate field accepts decimal rate and clearing means inherit', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PartyDieselRateField(controller))));
    await tester.enterText(find.byType(TextField), '4.65');
    expect(PartyDieselRate.parseOptional(controller.text), 4.65);
    await tester.enterText(find.byType(TextField), '');
    expect(PartyDieselRate.parseOptional(controller.text), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
