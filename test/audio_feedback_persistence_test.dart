import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory testDirectory;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    testDirectory = await Directory.systemTemp.createTemp('saqia_audio_prefs_');
    await databaseFactory.setDatabasesPath(testDirectory.path);
    await databaseFactory.deleteDatabase(
      '${testDirectory.path}/saqia_station_v2.db',
    );
    database = AppDatabase.instance;
    await database.db;
  });

  setUp(() async {
    await StationRepository(database).setSetting('sound_notifications', 'true');
  });

  tearDownAll(() async {
    await database.close();
    await testDirectory.delete(recursive: true);
  });

  test('sound mute choice persists after closing and reopening SQLite', () async {
    final repository = StationRepository(database);
    await repository.setSetting('sound_notifications', 'false');
    expect((await repository.settings())['sound_notifications'], 'false');

    await database.close();
    // Re-open through the same database singleton; the setting must be stored,
    // not merely held in AppPrefs or widget state.
    await database.db;
    expect((await StationRepository(database).settings())['sound_notifications'], 'false');
  });

  test('turning sounds back on also persists across reopen', () async {
    final repository = StationRepository(database);
    await repository.setSetting('sound_notifications', 'false');
    await repository.setSetting('sound_notifications', 'true');
    await database.close();
    await database.db;
    expect((await StationRepository(database).settings())['sound_notifications'], 'true');
  });
}
