import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/domain/accounting/accounting_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  final db = AppDatabase.instance;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    folder = await Directory.systemTemp.createTemp('third-cloud-irrigation-');
    await databaseFactory.setDatabasesPath(folder.path);
    await db.db;
  });

  tearDownAll(() async {
    await db.close();
    await folder.delete(recursive: true);
  });

  test('third-type cloud is recorded but does not discount the charge', () async {
    await db.update('settings', {'value': 'equivalent_hybrid'},
        'key=?', ['system_type']);
    await db.update('settings', {'value': '6000'},
        'key=?', ['third_type_hourly_rate']);

    final start = DateTime(2050, 4, 12, 8);
    final beneficiary = await db.insert('beneficiaries', {
      'station_id': 1,
      'name': 'مستفيد النوع الثالث',
      'created_at': start.toIso8601String(),
      'updated_at': start.toIso8601String(),
    });
    final id = await AccountingService(db).recordIrrigation(
      stationId: 1,
      pumpId: 1,
      beneficiaryId: beneficiary,
      start: start,
      end: start.add(const Duration(hours: 1)),
      systemType: 'equivalent_hybrid',
      waterRate: 0,
      litersPerHour: 0,
      dieselPrice: 0,
      solarRate: 0,
      thirdRate: 6000,
      cloudMinutes: 0,
      cloudPeriods: [
        {
          'start': start.add(const Duration(minutes: 10)).toIso8601String(),
          'end': start.add(const Duration(minutes: 25)).toIso8601String(),
        },
      ],
      paidAmount: 0,
    );

    final row = (await db.query(
      'SELECT cloud_minutes,chargeable_minutes,total_amount,water_amount '
      'FROM irrigations WHERE id=?',
      args: [id],
    )).single;
    expect(row['cloud_minutes'], 15);
    expect(row['chargeable_minutes'], 60);
    expect(row['total_amount'], 6000);
    expect(row['water_amount'], 6000);
    final periods = await db.query(
      'SELECT minutes FROM cloud_periods WHERE irrigation_id=?',
      args: [id],
    );
    expect(periods.length, 1);
    expect(periods.single['minutes'], 15);

    await AccountingService(db).updateIrrigationBasic(
      id: id,
      start: start,
      end: start.add(const Duration(hours: 2)),
      userId: 1,
    );
    final edited = (await db.query(
      'SELECT cloud_minutes,chargeable_minutes,total_amount '
      'FROM irrigations WHERE id=?', args: [id],
    )).single;
    expect(edited['cloud_minutes'], 15);
    expect(edited['chargeable_minutes'], 120);
    expect(edited['total_amount'], 12000);
  });
}
