import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/data/repositories/repositories.dart';
import 'package:saqia_station/features/app.dart';

class _Parties extends StationRepository {
  List<Map<String, Object?>> parties(String kind) => [
    {'id': 1, 'name': '$kind first'},
    {'id': 7, 'name': '$kind selected'},
  ];
  @override
  Future<List<Map<String, Object?>>> payments() async => [];
  @override
  Future<List<Map<String, Object?>>> beneficiaries([String q = '']) async => parties('beneficiary');
  @override
  Future<List<Map<String, Object?>>> workers({bool includeInactive = false, String search = ''}) async => parties('worker');
  @override
  Future<List<Map<String, Object?>>> partners({bool includeInactive = false, String search = ''}) async => parties('partner');
  @override
  Future<List<Map<String, Object?>>> paymentMethods() async => [];
  @override
  Future<List<Map<String, Object?>>> cashboxes() async => [];
}

void main() {
  for (final kind in ['beneficiary', 'worker', 'partner']) {
    for (final debt in [false, true]) {
      testWidgets('$kind ${debt ? 'debt' : 'payment'} selects clicked party and reloads after cancel', (tester) async {
        var reloads = 0;
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: PartyPaymentActions(
          repository: _Parties(), userId: 42, partyType: kind, partyId: 7,
          onChanged: () async { reloads++; },
        ))));
        await tester.tap(find.text(debt ? 'إضافة مديونية' : 'إضافة دفعة'));
        await tester.pumpAndSettle();
        final selectors = tester.widgetList<DropdownButtonFormField<int>>(
          find.byType(DropdownButtonFormField<int>));
        expect(selectors.first.initialValue, 7);
        expect(find.text(debt ? 'إضافة مديونية سابقة' : 'تسجيل دفعة'), findsOneWidget);
        if (!debt) {
          final type = tester.widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>));
          expect(type.initialValue, kind);
        }
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('إلغاء'));
        await tester.pumpAndSettle();
        expect(reloads, 1);
        expect(find.byType(PaymentsPage), findsNothing);
      });
    }
  }
}
