import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/domain/accounting/reconciliation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late ReconciliationService service;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.deleteDatabase(
      '${await databaseFactory.getDatabasesPath()}/saqia_station_v2.db',
    );
    database = AppDatabase.instance;
    await database.db;
    service = ReconciliationService(database);
  });

  setUp(() async {
    await database.delete(
      'accountant_reconciliation_months',
      '1=1',
      const [],
    );
  });

  test('monthKey pads single-digit months', () {
    expect(service.monthKey(DateTime(2026, 3, 1)), '2026-03');
    expect(service.monthKey(DateTime(2026, 12, 1)), '2026-12');
  });

  test('loadMonth returns an empty monthly reconciliation safely', () async {
    final result = await service.loadMonth(DateTime(2026, 4, 19));

    expect(result['station_id'], 1);
    expect(result['month_key'], '2026-04');
    expect(result['partner_profit'], 0);
    expect(result['partner_app_paid'], 0);
    expect(result['opening_balance'], 0);
    expect(result['manual_paid'], 0);
    expect(result['closing_balance'], 0);
    expect(result['beneficiary_due'], 0);
    expect(result['beneficiary_credit'], 0);
    expect(result['beneficiary_paid'], 0);
    expect(result['worker_due'], 0);
    expect(result['worker_credit'], 0);
    expect(result['worker_paid'], 0);
    expect(result['expenses'], 0);
    expect(result['has_previous'], isFalse);
    expect(result['has_saved'], isFalse);
    expect(result['history'], isEmpty);
  });

  test('saveMonth inserts a reconciliation and loadMonth reads it back', () async {
    await service.saveMonth(
      month: DateTime(2026, 5, 1),
      openingBalance: 12000,
      manualPaid: 2500,
      openingDetails: 'رصيد مرحّل من أبريل',
      userId: 1,
    );

    final result = await service.loadMonth(DateTime(2026, 5, 20));
    final rows = await database.query('accountant_reconciliation_months');

    expect(rows, hasLength(1));
    expect(result['has_saved'], isTrue);
    expect(result['opening_balance'], 12000);
    expect(result['manual_paid'], 2500);
    expect(result['opening_details'], 'رصيد مرحّل من أبريل');
    expect(result['closing_balance'], 9500);
  });

  test('saving the same month updates its row instead of duplicating it', () async {
    final month = DateTime(2026, 6, 1);
    await service.saveMonth(
      month: month,
      openingBalance: 10000,
      manualPaid: 1000,
      openingDetails: 'أول بيان',
      userId: 1,
    );
    await service.saveMonth(
      month: month,
      openingBalance: 15000,
      manualPaid: 3000,
      openingDetails: 'بيان محدّث',
      userId: 1,
    );

    final rows = await database.query('accountant_reconciliation_months');
    final result = await service.loadMonth(month);

    expect(rows, hasLength(1));
    expect(result['opening_balance'], 15000);
    expect(result['manual_paid'], 3000);
    expect(result['opening_details'], 'بيان محدّث');
    expect(result['closing_balance'], 12000);
  });

  test('negative manual payment is rejected without saving', () async {
    await expectLater(
      service.saveMonth(
        month: DateTime(2026, 7, 1),
        openingBalance: 0,
        manualPaid: -1,
        openingDetails: '',
        userId: 1,
      ),
      throwsA(isA<ArgumentError>()),
    );

    expect(
      await database.query('accountant_reconciliation_months'),
      isEmpty,
    );
  });

  test('later month carries forward the previous saved closing balance', () async {
    await service.saveMonth(
      month: DateTime(2026, 8, 1),
      openingBalance: 12000,
      manualPaid: 2000,
      openingDetails: 'افتتاح أغسطس',
      userId: 1,
    );
    await service.saveMonth(
      month: DateTime(2026, 10, 1),
      openingBalance: 999999,
      manualPaid: 1000,
      openingDetails: 'افتتاح أكتوبر',
      userId: 1,
    );

    final result = await service.loadMonth(DateTime(2026, 10, 1));
    final history = result['history'] as List;

    expect(result['has_previous'], isTrue);
    expect(result['opening_balance'], 10000);
    expect(result['closing_balance'], 9000);
    expect(history, hasLength(2));
    expect(history.first['month_key'], '2026-09');
    expect(history.first['closing_balance'], 10000);
    expect(history.last['month_key'], '2026-08');
    expect(history.last['closing_balance'], 10000);
  });

  test('editing an earlier month recalculates saved future month balances', () async {
    final august = DateTime(2026, 8, 1);
    await service.saveMonth(
      month: august,
      openingBalance: 12000,
      manualPaid: 2000,
      openingDetails: '',
      userId: 1,
    );
    await service.saveMonth(
      month: DateTime(2026, 10, 1),
      openingBalance: 0,
      manualPaid: 1000,
      openingDetails: '',
      userId: 1,
    );

    await service.saveMonth(
      month: august,
      openingBalance: 12000,
      manualPaid: 3000,
      openingDetails: 'تم تصحيح التسليم اليدوي',
      userId: 1,
    );

    final october = await service.loadMonth(DateTime(2026, 10, 1));
    expect(october['opening_balance'], 9000);
    expect(october['closing_balance'], 8000);

    final savedOctober = await database.query(
      'accountant_reconciliation_months',
      where: 'month_key=?',
      whereArgs: const ['2026-10'],
      limit: 1,
    );
    expect(savedOctober.single['opening_balance'], 9000);
    expect(savedOctober.single['closing_balance'], 8000);
  });
}
