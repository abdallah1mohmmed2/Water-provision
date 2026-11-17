import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/data/repositories/repositories.dart';
import 'package:saqia_station/features/app.dart';
import 'package:saqia_station/services/report_service.dart';

class InvoiceRepository extends StationRepository {
  final List<Map<String, Object?>> records;
  InvoiceRepository(this.records);

  @override
  Future<Map<String, String>> settings() async => {'system_type': 'solar'};

  @override
  Future<List<Map<String, Object?>>> report(String key, {
    DateTime? from, DateTime? to, int? beneficiaryId, int? workerId,
    int? partnerId, String? systemType, int? cashboxId,
    int? paymentMethodId, String? category, String? status,
  }) async => records;
}

Map<String, Object?> invoice(String name, String type, int cloud) => {
  'party_name': name, 'system_type': type, 'minutes': 60,
  'cloud_minutes': cloud, 'chargeable_minutes': 60 - cloud,
  'total_amount': 6000, 'paid_amount': 1000, 'notes': 'بيان $name',
  'start_datetime': '2026-11-17T08:00:00',
  'end_datetime': '2026-11-17T09:00:00',
  'diesel_consumption_liters': 2.5,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('invoice cloud column preserves adjacent cells and sort mapping', (tester) async {
    tester.view.physicalSize = const Size(2200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = InvoiceRepository([
      invoice('شمسي', 'solar', 5), invoice('ديزل', 'diesel', 0),
    ]);
    await tester.pumpWidget(MaterialApp(home: InvoicesReportPage(repo, autoSelectPeriod: false)));
    await tester.pumpAndSettle();
    DataTable table() => tester.widget<DataTable>(find.byType(DataTable));
    expect(table().columns.length, 10);
    expect((table().columns[5].label as Text).data, 'الغيم (دقيقة)');
    for (final row in table().rows) {
      expect(row.cells.length, table().columns.length);
      final name = (row.cells[1].child as Text).data;
      expect((row.cells[4].child as Text).data, name == 'شمسي' ? '55' : '60');
      expect((row.cells[5].child as Text).data, name == 'شمسي' ? '5' : '0');
      expect((row.cells[6].child as Text).data, '6,000');
      expect((row.cells[7].child as Text).data, '1,000');
      expect(row.cells[8].child, isA<SizedBox>());
      expect(row.cells[9].child, isA<IconButton>());
    }
    table().columns[5].onSort!(5, true);
    await tester.pump();
    expect(table().sortColumnIndex, 5);
    expect((table().rows.first.cells[1].child as Text).data, 'ديزل');
    table().columns[6].onSort!(6, true);
    await tester.pump();
    expect(table().sortColumnIndex, 6);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('invoice PDF builds with cloud column for solar diesel mixed and empty rows', () async {
    final solar = invoice('شمسي', 'solar', 5);
    final diesel = invoice('ديزل', 'diesel', 0);
    for (final rows in [[solar], [diesel], [solar, diesel], <Map<String, Object?>>[]]) {
      final bytes = await ReportService(InvoiceRepository(rows)).invoicesPdf(rows: rows);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(1000));
    }
    expect(solar['cloud_minutes'], 5);
    expect(solar['minutes'], 60);
    expect(solar['total_amount'], 6000);
  });
}
