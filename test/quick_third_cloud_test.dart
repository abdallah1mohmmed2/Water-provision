import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/domain/accounting/accounting_service.dart';
import 'package:saqia_station/data/repositories/repositories.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  final db = AppDatabase.instance;
  late AccountingService accounting;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    folder = await Directory.systemTemp.createTemp('hybrid-source-pricing-');
    await databaseFactory.setDatabasesPath(folder.path);
    await db.db;
    accounting = AccountingService(db);
    await db.update('settings', {'value': 'equivalent_hybrid'},
        'key=?', ['system_type']);
    await db.update('settings', {'value': '6000'},
        'key=?', ['hybrid_diesel_hourly_rate']);
    await db.update('settings', {'value': '6000'},
        'key=?', ['solar_hourly_rate']);
    await db.update('settings', {'value': '6000'},
        'key=?', ['third_type_hourly_rate']);
  });

  tearDownAll(() async {
    await db.close();
    await folder.delete(recursive: true);
  });

  Future<int> beneficiary(String name, DateTime start) => db.insert('beneficiaries', {
    'station_id': 1,
    'name': name,
    'created_at': start.toIso8601String(),
    'updated_at': start.toIso8601String(),
  });

  List<Map<String, String>> cloudPeriod(DateTime start) => [
    {
      'start': start.add(const Duration(minutes: 10)).toIso8601String(),
      'end': start.add(const Duration(minutes: 25)).toIso8601String(),
    },
  ];

  test('hybrid diesel uses its own hourly rate and never applies cloud minutes', () async {
    final start = DateTime(2050, 4, 12, 8);
    final owner = await beneficiary('مستفيد هجين ديزل', start);
    final id = await accounting.recordIrrigation(
      stationId: 1,
      pumpId: 1,
      beneficiaryId: owner,
      start: start,
      end: start.add(const Duration(hours: 1)),
      systemType: 'equivalent_hybrid',
      hybridSource: 'diesel',
      waterRate: 0,
      litersPerHour: 0,
      dieselPrice: 0,
      solarRate: 6000,
      thirdRate: 6000,
      cloudMinutes: 15,
      cloudPeriods: cloudPeriod(start),
      paidAmount: 0,
    );

    final row = (await db.query(
      'SELECT hybrid_source,hybrid_diesel_hourly_rate_snapshot,solar_hourly_rate_snapshot,'
      'third_type_hourly_rate_snapshot,cloud_minutes,chargeable_minutes,total_amount,water_amount '
      'FROM irrigations WHERE id=?',
      args: [id],
    )).single;
    expect(row['hybrid_source'], 'diesel');
    expect(row['hybrid_diesel_hourly_rate_snapshot'], 6000);
    expect(row['solar_hourly_rate_snapshot'], 0);
    expect(row['third_type_hourly_rate_snapshot'], 0);
    expect(row['cloud_minutes'], 0);
    expect(row['chargeable_minutes'], 60);
    expect(row['total_amount'], 6000);
    expect(row['water_amount'], 6000);
    expect(await db.query(
      'SELECT id FROM cloud_periods WHERE irrigation_id=?',
      args: [id],
    ), isEmpty);

    await accounting.updateIrrigationBasic(
      id: id,
      start: start,
      end: start.add(const Duration(hours: 2)),
      userId: 1,
    );
    final edited = (await db.query(
      'SELECT cloud_minutes,chargeable_minutes,total_amount FROM irrigations WHERE id=?',
      args: [id],
    )).single;
    expect(edited['cloud_minutes'], 0);
    expect(edited['chargeable_minutes'], 120);
    expect(edited['total_amount'], 12000);
  });

  test('hybrid solar reuses solar rate and discounts recorded cloud minutes', () async {
    final start = DateTime(2050, 4, 13, 8);
    final owner = await beneficiary('مستفيد هجين شمسي', start);
    final id = await accounting.recordIrrigation(
      stationId: 1,
      pumpId: 1,
      beneficiaryId: owner,
      start: start,
      end: start.add(const Duration(hours: 1)),
      systemType: 'equivalent_hybrid',
      hybridSource: 'solar',
      waterRate: 0,
      litersPerHour: 0,
      dieselPrice: 0,
      solarRate: 6000,
      thirdRate: 6000,
      cloudMinutes: 15,
      cloudPeriods: cloudPeriod(start),
      paidAmount: 0,
    );

    final row = (await db.query(
      'SELECT hybrid_source,hybrid_diesel_hourly_rate_snapshot,solar_hourly_rate_snapshot,'
      'cloud_minutes,chargeable_minutes,total_amount,water_amount '
      'FROM irrigations WHERE id=?',
      args: [id],
    )).single;
    expect(row['hybrid_source'], 'solar');
    expect(row['hybrid_diesel_hourly_rate_snapshot'], 0);
    expect(row['solar_hourly_rate_snapshot'], 6000);
    expect(row['cloud_minutes'], 15);
    expect(row['chargeable_minutes'], 45);
    expect(row['total_amount'], 4500);
    expect(row['water_amount'], 4500);
    final periods = await db.query(
      'SELECT minutes FROM cloud_periods WHERE irrigation_id=?',
      args: [id],
    );
    expect(periods.single['minutes'], 15);

    await accounting.updateIrrigationBasic(
      id: id,
      start: start,
      end: start.add(const Duration(hours: 2)),
      userId: 1,
    );
    final edited = (await db.query(
      'SELECT cloud_minutes,chargeable_minutes,total_amount FROM irrigations WHERE id=?',
      args: [id],
    )).single;
    expect(edited['cloud_minutes'], 15);
    expect(edited['chargeable_minutes'], 105);
    expect(edited['total_amount'], 10500);
  });
  test('party irrigation report rows expose hybrid source and diesel liters', () async {
    final start = DateTime(2050, 4, 14, 8);
    final owner = await beneficiary('تقرير مصدر هجين', start);
    for (final source in ['solar', 'diesel']) {
      await accounting.recordIrrigation(
        stationId: 1,
        pumpId: 1,
        beneficiaryId: owner,
        start: start.add(Duration(hours: source == 'solar' ? 0 : 2)),
        end: start.add(Duration(hours: source == 'solar' ? 1 : 3)),
        systemType: 'equivalent_hybrid',
        hybridSource: source,
        waterRate: 0,
        litersPerHour: 0,
        dieselPrice: 0,
        solarRate: 6000,
        thirdRate: 6000,
        cloudMinutes: source == 'solar' ? 15 : 0,
        cloudPeriods: source == 'solar' ? cloudPeriod(start) : const [],
        paidAmount: 0,
      );
    }
    final rows = await StationRepository(db).report(
      'irrigations', beneficiaryId: owner, systemType: 'equivalent_hybrid');
    expect(rows.map((row) => row['hybrid_source']).toSet(), {'solar', 'diesel'});
    expect(rows.every((row) => row.containsKey('diesel_consumption_liters')), isTrue);
    final solar = rows.singleWhere((row) => row['hybrid_source'] == 'solar');
    final diesel = rows.singleWhere((row) => row['hybrid_source'] == 'diesel');
    expect(solar['cloud_minutes'], 15);
    expect(diesel['cloud_minutes'], 0);
    expect(diesel['diesel_consumption_liters'], 0);
  });

}
