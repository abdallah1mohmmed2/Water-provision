import 'package:saqia_station/domain/accounting/report_minute_pricing.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';
import 'package:saqia_station/domain/accounting/calculations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('beneficiary report-only price follows saved minute snapshot, not current price or ledger', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final folder = await Directory.systemTemp.createTemp('saqia-minute-report-');
    await databaseFactory.setDatabasesPath(folder.path);
    final app = AppDatabase.instance;
    addTearDown(() async {
      await app.close();
      await folder.delete(recursive: true);
    });
    final db = await app.db;
    final repo = StationRepository(app);
    final now = DateTime(2026, 11, 5, 8).toIso8601String();
    final personId = await db.insert('beneficiaries', {
      'station_id': 1,
      'name': 'TEST-REPORT-SPECIAL-PRICE',
      'status': 'active',
      'created_at': now,
      'updated_at': now,
    });
    final irrigationId = await db.insert('irrigations', {
      'station_id': 1,
      'pump_id': 1,
      'beneficiary_id': personId,
      'party_type': 'beneficiary',
      'date': '2026-11-05',
      'start_datetime': now,
      'end_datetime': DateTime(2026, 11, 5, 9).toIso8601String(),
      'minutes': 60,
      'cloud_minutes': 5,
      'chargeable_minutes': 55,
      'system_type': 'solar',
      'solar_hourly_rate_snapshot': 7000,
      'work_minute_rate_snapshot': 120,
      'water_amount': 6417,
      'diesel_amount': 0,
      'total_amount': 6417,
      'status': 'posted',
      'created_at': now,
      'updated_at': now,
    });

    final beforeLedgerCount = (await db.rawQuery(
      'SELECT COUNT(*) c FROM journal_entries',
    )).single['c'];
    final original = (await repo.report('invoices', systemType: 'all'))
        .singleWhere((row) => row['invoice_id'] == irrigationId);
    expect(original['total_amount'], 6417);
    expect(original['work_minute_rate_snapshot'], 120);
    expect(ReportMinutePricing.amountAtMinuteRate(
      (original['chargeable_minutes'] as num).toInt(),
      (original['work_minute_rate_snapshot'] as num).toInt(),
    ), 6600);

    Map<String, Object?> findBalance(List<Map<String, Object?>> rows) =>
        rows.singleWhere((row) => row['id'] == personId);
    final baseline = findBalance(await repo.report('debts'));
    expect(baseline['balance'], 6417);
    await repo.setSetting('work_minute_rate', '120');
    await repo.setSetting('work_price_report_display_special_rate', 'true');
    final special = findBalance(await repo.report('debts'));
    expect(special['balance'], 6600);
    await repo.setSetting('work_minute_rate', '300');
    expect(findBalance(await repo.report('debts'))['balance'], 6600);
    await repo.setSetting('work_price_report_display_special_rate', 'false');
    expect(findBalance(await repo.report('debts'))['balance'], 6417);
    expect((await db.query('irrigations', where: 'id=?', whereArgs: [irrigationId]))
        .single['total_amount'], 6417);
    expect((await db.rawQuery('SELECT COUNT(*) c FROM journal_entries'))
        .single['c'], beforeLedgerCount);
  });
}
