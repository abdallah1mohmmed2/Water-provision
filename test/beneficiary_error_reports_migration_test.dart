import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/data/local/database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ترقية قاعدة إصدار 26 تنشئ جدول بلاغات المستفيدين المفقود دون حذف البيانات', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await databaseFactory.getDatabasesPath();
    final path = '$directory/saqia_station_v2.db';
    await databaseFactory.deleteDatabase(path);

    // محاكاة جهاز لديه مخطط 26 لكنه يفتقد الجدول بسبب ترحيل سابق غير مكتمل.
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 26,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE stations (id INTEGER PRIMARY KEY)');
          await db.execute('CREATE TABLE beneficiaries (id INTEGER PRIMARY KEY, station_id INTEGER, status TEXT)');
          await db.execute('CREATE TABLE legacy_marker (id INTEGER PRIMARY KEY, value TEXT)');
          await db.insert('legacy_marker', {'id': 1, 'value': 'preserve-me'});
        },
      ),
    );
    await legacy.close();

    final appDb = AppDatabase.instance;
    final upgraded = await appDb.db;
    final tables = await upgraded.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='beneficiary_error_reports'",
    );
    expect(tables, hasLength(1));

    final preserved = await upgraded.query('legacy_marker');
    expect(preserved.single['value'], 'preserve-me');

    final indexes = await upgraded.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' AND name IN "
      "('idx_beneficiary_reports_owner','idx_beneficiary_reports_station_status','idx_beneficiary_reports_movement')",
    );
    expect(indexes, hasLength(3));
    await upgraded.close();
    await databaseFactory.deleteDatabase(path);
  });
}
