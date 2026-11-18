import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('operational work difference posts beneficiary at special price but workers and partners at hourly base', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final folder = await Directory.systemTemp.createTemp('saqia-work-difference-');
    await databaseFactory.setDatabasesPath(folder.path);
    final app = AppDatabase.instance;
    addTearDown(() async {
      await app.close();
      await folder.delete(recursive: true);
    });
    final db = await app.db;
    final repo = StationRepository(app);
    for (final entry in const {
      'system_type': 'solar',
      'solar_hourly_rate': '7000',
      'partial_hour': 'true',
      'work_minute_rate': '120',
    }.entries) {
      await repo.setSetting(entry.key, entry.value);
    }
    final now = DateTime(2046, 1, 10, 8);
    final beneficiary = await db.insert('beneficiaries', {
      'station_id': 1,
      'name': 'TEST-WORK-DIFFERENCE-BENEFICIARY',
      'status': 'active',
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    final worker = await db.insert('workers', {
      'station_id': 1,
      'name': 'TEST-WORK-DIFFERENCE-WORKER',
      'pay_type': 'percentage',
      'percentage_rate': 10,
      'active': 1,
    });
    final partner = await db.insert('partners', {
      'station_id': 1,
      'name': 'TEST-WORK-DIFFERENCE-PARTNER',
      'ownership_mode': 'shares',
      'shares_count': 1,
      'active': 1,
    });

    Future<int> record(DateTime start) => repo.accounting.recordIrrigation(
      stationId: 1,
      pumpId: 1,
      beneficiaryId: beneficiary,
      start: start,
      end: start.add(const Duration(hours: 1)),
      systemType: 'solar',
      waterRate: 0,
      litersPerHour: 0,
      dieselPrice: 0,
      solarRate: 0,
      thirdRate: 0,
      cloudMinutes: 0,
      paidAmount: 0,
      userId: 1,
    );

    await repo.setWorkDifferenceEnabled(true);
    var settings = await repo.settings();
    expect(settings['work_price_difference_enabled'], 'true');
    expect(settings['work_price_report_display_special_rate'], 'true');
    final specialId = await record(now);
    var special = (await db.query('irrigations',
      where: 'id=?', whereArgs: [specialId])).single;
    expect(special['work_price_enabled_snapshot'], 1);
    expect(special['work_minute_rate_snapshot'], 120);
    expect(special['work_base_water_amount_snapshot'], 7000);
    expect(special['work_difference_snapshot'], 200);
    expect(special['water_amount'], 7200);
    expect(special['total_amount'], 7200);
    expect((await repo.accounting.workerBalance(worker))['balance'], 700);
    expect((await repo.accounting.partnerBalance(partner))['balance'], 6300);
    expect((await repo.accounting.beneficiaryBalance(beneficiary))['balance'], 7200);

    await repo.setWorkDifferenceEnabled(false);
    settings = await repo.settings();
    expect(settings['work_price_difference_enabled'], 'false');
    expect(settings['work_price_report_display_special_rate'], 'false');
    final regularId = await record(DateTime(2046, 1, 20, 8));
    final regular = (await db.query('irrigations',
      where: 'id=?', whereArgs: [regularId])).single;
    expect(regular['work_price_enabled_snapshot'], 0);
    expect(regular['total_amount'], 7000);
    expect(regular['work_difference_snapshot'], 0);
    expect((await repo.accounting.workerBalance(worker))['balance'], 1400);
    expect((await repo.accounting.partnerBalance(partner))['balance'], 12600);

    // Editing a special-rate irrigation after disabling the switch MUST
    // preserve its original 120/minute tariff and reverse/repost its journal.
    final corrected = await repo.accounting.updateIrrigationBasic(
      id: specialId,
      start: now,
      end: now.add(const Duration(minutes: 30)),
      userId: 1,
    );
    expect(corrected, 3600);
    special = (await db.query('irrigations',
      where: 'id=?', whereArgs: [specialId])).single;
    expect(special['work_price_enabled_snapshot'], 1);
    expect(special['work_minute_rate_snapshot'], 120);
    expect(special['work_base_water_amount_snapshot'], 3500);
    expect(special['work_difference_snapshot'], 100);
    expect(special['total_amount'], 3600);
    expect((await repo.accounting.workerBalance(worker))['balance'], 1050);
    expect((await repo.accounting.partnerBalance(partner))['balance'], 9450);
    expect((await repo.accounting.beneficiaryBalance(beneficiary))['balance'], 10600);
    final profitSummary = await repo.partnerProfitSummary(
      from: DateTime(2046, 1, 1), to: DateTime(2046, 1, 31),
    );
    expect(profitSummary['revenue'], 10600);
    expect(profitSummary['work_difference'], 100);
    expect(profitSummary['hourly_base_revenue'], 10500);
    expect(profitSummary['workers'], 1050);
    expect(profitSummary['distributable'], 9450);

    final statement = await repo.beneficiaryStatement(beneficiary);
    final invoiceRows = statement.where((row) => row['type'] == 's').toList();
    expect(invoiceRows, hasLength(2));
    // Customer statement is always displayed at its special minute snapshot,
    // even for a standard-hourly invoice when the switch was off.
    expect(invoiceRows.map((row) => row['alayh']).toSet(), {3600, 7200});
    expect((await repo.report('debts')).singleWhere(
      (row) => row['id'] == beneficiary)['balance'], 10800);

    final unbalanced = await db.rawQuery('''
      SELECT je.id, SUM(jl.debit-jl.credit) net
      FROM journal_entries je JOIN journal_lines jl
        ON jl.journal_entry_id=je.id
      WHERE je.reference_type='irrigation' AND je.reference_id=?
      GROUP BY je.id HAVING net!=0
    ''', [specialId]);
    expect(unbalanced, isEmpty);
  });
}
