import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/core/app_clock.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';
import 'package:saqia_station/domain/accounting/beneficiary_irrigation_actions.dart';
import 'package:saqia_station/services/beneficiary_irrigation_message_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase.instance;
  late Directory dir;
  late StationRepository repo;
  late int workerId, partnerId, workerIrrigationId, partnerIrrigationId;
  late DateTime start;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('party-irrigation-actions-');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  setUp(() async {
    await db.close();
    await databaseFactory.deleteDatabase('${dir.path}/saqia_station_v2.db');
    await db.db;
    repo = StationRepository(db);
    final now = AppClock.now();
    start = DateTime(now.year, now.month, now.day, 8);
    workerId = await repo.createWorker(
      name: 'عامل الاختبار', payType: 'hourly', hourlyRate: 100);
    partnerId = await repo.createPartner(
      name: 'شريك الاختبار', mode: 'shares', shares: 1);
    for (final setting in {
      'system_type': 'diesel',
      'diesel_hourly_water_rate': '6000',
      'diesel_liters_per_hour': '2',
      'partial_hour': 'true',
      'min_wait_days': '0',
    }.entries) {
      await repo.setSetting(setting.key, setting.value);
    }
    Future<int> record(String type, int id, int hour) =>
        repo.accounting.recordIrrigation(
          stationId: 1, pumpId: 1, partyType: type,
          workerId: type == 'worker' ? id : null,
          partnerId: type == 'partner' ? id : null,
          start: DateTime(start.year, start.month, start.day, hour),
          end: DateTime(start.year, start.month, start.day, hour + 1),
          systemType: 'diesel', waterRate: 6000, litersPerHour: 2,
          dieselPrice: 0, solarRate: 6000, thirdRate: 6000,
          cloudMinutes: 0, paidAmount: 0, userId: 1,
        );
    workerIrrigationId = await record('worker', workerId, 8);
    partnerIrrigationId = await record('partner', partnerId, 11);
  });
  tearDownAll(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  PartyIrrigationActions action(String type, int id, int irrigation) =>
      PartyIrrigationActions(db, userId: 1,
          partyType: type, partyId: id, irrigationId: irrigation);

  test('worker/partner are authorized only for their own account irrigations', () async {
    expect((await action('worker', workerId, workerIrrigationId).record())['party_type'], 'worker');
    expect((await action('partner', partnerId, partnerIrrigationId).record())['party_type'], 'partner');
    await expectLater(action('worker', workerId, partnerIrrigationId).record(), throwsStateError);
    await expectLater(action('partner', partnerId, workerIrrigationId).record(), throwsStateError);
    await db.update('app_users', {'role': 'operations'}, 'id=?', [1]);
    await expectLater(action('worker', workerId, workerIrrigationId).cancel('غير مسموح'), throwsStateError);
    await expectLater(action('partner', partnerId, partnerIrrigationId).record(), throwsStateError);
  });

  test('worker edit and partner cancellation use audited accounting reversals', () async {
    final before = (await db.query('SELECT * FROM irrigations WHERE id=?',
      args: [workerIrrigationId])).single;
    expect(before['minutes'], 60);
    await action('worker', workerId, workerIrrigationId)
      .edit(start, start.add(const Duration(hours: 2)));
    final edited = (await db.query('SELECT * FROM irrigations WHERE id=?',
      args: [workerIrrigationId])).single;
    expect(edited['minutes'], 120);
    await action('partner', partnerId, partnerIrrigationId).cancel('تصحيح إدخال');
    final cancelled = (await db.query('SELECT status,cancel_reason FROM irrigations WHERE id=?',
      args: [partnerIrrigationId])).single;
    expect(cancelled['status'], 'cancelled');
    expect(cancelled['cancel_reason'], 'تصحيح إدخال');
    await expectLater(action('partner', partnerId, partnerIrrigationId).record(), throwsStateError);
    final total = await db.query(
      "SELECT COALESCE(SUM(liters),0) liters FROM diesel_movements "
      "WHERE irrigation_id=? AND kind='consumption'",
      args: [partnerIrrigationId]);
    expect((total.single['liters'] as num).toDouble(), 0);
  });

  test('worker/partner message regeneration is read-only and owner scoped', () async {
    final service = BeneficiaryIrrigationMessageService(repo);
    final before = (await db.query('SELECT COUNT(*) n FROM sync_queue')).single['n'];
    for (final entry in [
      ('worker', workerId, workerIrrigationId, 'عامل الاختبار'),
      ('partner', partnerId, partnerIrrigationId, 'شريك الاختبار'),
    ]) {
      final message = await service.prepareForParty(
        userId: 1, partyType: entry.$1,
        partyId: entry.$2, irrigationId: entry.$3);
      expect(message.name, entry.$4);
      expect(message.text, contains(entry.$4));
      // Re-sending must reconstruct the balance before the irrigation instead
      // of displaying the unavailable historical snapshot placeholder.
      expect(message.text, isNot(contains('غير محفوظ لهذه السقاية')));
      expect(message.text, contains('الرصيد السابق: متوازن (0 ريال)'));
    }
    await expectLater(service.prepareForParty(
      userId: 1, partyType: 'worker',
      partyId: workerId, irrigationId: partnerIrrigationId), throwsStateError);
    expect((await db.query('SELECT COUNT(*) n FROM sync_queue')).single['n'], before);
  });
}
