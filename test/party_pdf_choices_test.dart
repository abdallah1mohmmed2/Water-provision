import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/data/repositories/repositories.dart';
import 'package:saqia_station/features/party_quick_actions.dart';

void main() {
  testWidgets('PDF picker shows diesel report only in diesel system',
      (tester) async {
    for (final type in ['beneficiary', 'worker', 'partner']) {
      for (final dieselEnabled in [false, true]) {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: PartyQuickActions(
              repository: StationRepository(),
              partyType: type,
              partyId: 10,
              name: 'اختبار',
              dieselEnabled: dieselEnabled,
              onNewIrrigation: () {},
            ),
          ),
        ));
        await tester.tap(find.text('PDF'));
        await tester.pumpAndSettle();
        expect(find.text('سقايات هذا الشخص'), findsOneWidget);
        expect(find.text('كشف حساب هذا الشخص'), findsOneWidget);
        if (dieselEnabled) {
          expect(find.text('المسلّم والمستهلك والمتبقي من الديزل'),
              findsOneWidget);
        } else {
          expect(find.text('المسلّم والمستهلك والمتبقي من الديزل'),
              findsNothing);
        }
        await tester.tapAt(const Offset(12, 12));
        await tester.pumpAndSettle();
      }
    }
  });
}
