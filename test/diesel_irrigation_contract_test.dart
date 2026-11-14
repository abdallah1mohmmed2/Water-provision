import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('diesel: in-kind balance, fuel GL, edits/cancellation and station scope', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final folder = await Directory.systemTemp.createTemp('saqia-diesel-contract-');
    await databaseFactory.setDatabasesPath(folder.path);
    final app = AppDatabase.instance;
    addTearDown(() async {
      await app.close();
      await folder.delete(recursive: true);
    });
    final db = await app.db;
    final repo = StationRepository(app);
    for (final entry in const {
      'system_type': 'diesel',
      'diesel_hourly_water_rate': '6001',
      'diesel_liters_per_hour': '2',
      'diesel_price_per_liter': '500',
      'partial_hour': 'true',
      'rounding': 'nearest',
      'diesel_delivery_financial_credit': 'false',
    }.entries) {
      await repo.setSetting(entry.key, entry.value);
    }
    // Opening stock is a genuine inventory asset, unlike beneficiary fuel
    // credit, which cannot silently increase the station's tank.
    await repo.accounting.addDieselMovement(
      kind: 'opening_balance', liters: 10, unitPrice: 500,
      date: DateTime(2046, 1, 1), userId: 1,
    );
    expect(await repo.accounting.dieselStock(), closeTo(10, 1e-7));
    final start = DateTime(2046, 2, 1, 8);
    final beneficiary = await db.insert('beneficiaries', {
      'station_id': 1, 'name': 'Diesel in-kind test', 'status': 'active',
      'opening_diesel_liters': 3,
      'created_at': start.toIso8601String(),
      'updated_at': start.toIso8601String(),
    });
    Future<int> record({
      required DateTime at, int? beneficiaryId, int? workerId,
      int? partnerId, required String partyType,
      int lengthMinutes = 5,
    }) => repo.accounting.recordIrrigation(
      stationId: 1, pumpId: 1, beneficiaryId: beneficiaryId,
      workerId: workerId, partnerId: partnerId, partyType: partyType,
      start: at, end: at.add(Duration(minutes: lengthMinutes)),
      systemType: 'diesel', waterRate: 6001, litersPerHour: 2,
      dieselPrice: 500, solarRate: 0, thirdRate: 0,
      cloudMinutes: 0, paidAmount: 0, userId: 1,
    );
    Future<int> netAccount(String code) async {
      final rows = await db.rawQuery('''
        SELECT COALESCE(SUM(jl.debit-jl.credit),0) total
        FROM journal_lines jl
        JOIN accounts a ON a.id=jl.account_id
        JOIN journal_entries je ON je.id=jl.journal_entry_id
        WHERE a.code=? AND je.status='posted'
      ''', [code]);
      return (rows.single['total'] as num).round();
    }
    final inventoryBefore = await netAccount('1300');
    final fuelExpenseBefore = await netAccount('5010');

    final id = await record(
      at: start, beneficiaryId: beneficiary, partyType: 'beneficiary',
    );
    var row = (await db.query('irrigations', where: 'id=?', whereArgs: [id])).single;
    expect(row['water_amount'], 501); // always ceiling, not general rounding
    expect(row['diesel_amount'], 0); // beneficiary already owns 3 liters
    expect(row['total_amount'], 501);
    var dieselRows = await db.query('diesel_movements',
      where: 'irrigation_id=?', whereArgs: [id]);
    expect(dieselRows.where((x) => x['kind'] == 'advance'), isEmpty);
    expect(dieselRows.where((x) => x['kind'] == 'consumption').length, 1);
    expect(dieselRows.single['station_id'], 1);
    expect(dieselRows.single['amount'], 0); // quantity only
    expect(dieselRows.single['unit_price'], 0);
    expect(await netAccount('1300'), inventoryBefore);
    expect(await netAccount('5010'), fuelExpenseBefore);
    expect(await repo.accounting.dieselStock(), closeTo(10 - 1 / 6, 1e-7));

    await repo.accounting.updateIrrigationBasic(
      id: id, start: start, end: start.add(const Duration(minutes: 10)),
      userId: 1,
    );
    row = (await db.query('irrigations', where: 'id=?', whereArgs: [id])).single;
    expect(row['water_amount'], 1001);
    expect(row['diesel_amount'], 0);
    expect(await netAccount('1300'), inventoryBefore);
    expect(await netAccount('5010'), fuelExpenseBefore);
    expect(await repo.accounting.dieselStock(), closeTo(10 - 1 / 3, 1e-7));

    await repo.accounting.cancelIrrigation(id, 1, 'Diesel contract regression');
    expect(await repo.accounting.dieselStock(), closeTo(10, 1e-7));
    expect(await netAccount('1300'), inventoryBefore);
    expect(await netAccount('5010'), fuelExpenseBefore);

    // Negative legacy fuel balances must never generate an automatic
    // advance larger than the actual volume consumed in the new irrigation.
    final negativeParty = await db.insert('beneficiaries', {
      'station_id': 1, 'name': 'Negative legacy in-kind balance',
      'opening_diesel_liters': -2, 'status': 'active',
      'created_at': start.toIso8601String(),
      'updated_at': start.toIso8601String(),
    });
    final cappedId = await record(
      at: DateTime(2046, 2, 5, 8),
      beneficiaryId: negativeParty, partyType: 'beneficiary',
      lengthMinutes: 60,
    );
    final capped = (await db.query('irrigations',
      where: 'id=?', whereArgs: [cappedId])).single;
    expect(capped['diesel_amount'], 0); // 2 liters borrowed, no currency
    final advances = await db.query('diesel_movements',
      where: "irrigation_id=? AND kind='advance'", whereArgs: [cappedId]);
    expect(advances, hasLength(1));
    expect(advances.single['liters'], closeTo(2, 1e-7));
    expect(advances.single['amount'], 0);
    expect(advances.single['unit_price'], 0);
    await repo.accounting.cancelIrrigation(cappedId, 1, 'Capped shortage regression');
    expect(await repo.accounting.dieselStock(), closeTo(10, 1e-7));

    final worker = await repo.createWorker(
      name: 'Diesel personal worker', payType: 'fixed',
    );
    final partner = await repo.createPartner(
      name: 'Diesel personal partner', mode: 'shares', shares: 1,
    );
    final workerIrrigation = await record(
      at: DateTime(2046, 2, 10, 8), workerId: worker, partyType: 'worker',
      lengthMinutes: 60,
    );
    final partnerIrrigation = await record(
      at: DateTime(2046, 2, 11, 8), partnerId: partner, partyType: 'partner',
      lengthMinutes: 60,
    );
    for (final irrigationId in [workerIrrigation, partnerIrrigation]) {
      final moves = await db.query('diesel_movements',
        where: 'irrigation_id=? AND kind=?',
        whereArgs: [irrigationId, 'consumption']);
      expect(moves.length, 1);
      expect(moves.single['station_id'], 1);
      expect(moves.single['beneficiary_id'], isNull);
      expect(moves.single['liters'], closeTo(2, 1e-7));
      expect(moves.single['unit_price'], 0);
      expect(moves.single['amount'], 0);
    }
    expect(await repo.accounting.dieselStock(), closeTo(6, 1e-7));
    expect(await netAccount('1300'), inventoryBefore);
    expect(await netAccount('5010'), fuelExpenseBefore);

    // Unrelated station stock must never leak into this station's warning,
    // available stock or inventory list.
    await db.insert('stations', {
      'id': 2, 'name': 'Other station', 'active': 1,
      'created_at': start.toIso8601String(),
      'updated_at': start.toIso8601String(),
    });
    await db.insert('diesel_movements', {
      'station_id': 2, 'kind': 'receipt', 'liters': 100,
      'unit_price': 500, 'amount': 50000,
      'date': start.toIso8601String(), 'created_by': 1,
    });
    expect(await repo.accounting.dieselStock(), closeTo(6, 1e-7));
    expect((await repo.dieselWarning())['stock'], closeTo(6, 1e-7));
    expect((await repo.diesel()).every((row) => row['station_id'] == 1), isTrue);
  });
}
