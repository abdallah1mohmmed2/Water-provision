import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:saqia_server/server.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  const secret = 'test-secret-with-more-than-thirty-two-bytes';
  late Database database;
  late Handler handler;

  setUp(() {
    database = sqlite3.openInMemory();
    database.execute('''
      CREATE TABLE app_users (
        id INTEGER PRIMARY KEY,
        station_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        role TEXT NOT NULL,
        username TEXT NOT NULL,
        password_hash TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1
      )
    ''');
    database.execute(
      'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL)',
    );
    database.execute('CREATE TABLE station_settings (station_id INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY(station_id,key))');
    database.execute("INSERT INTO station_settings(station_id,key,value,updated_at) VALUES(7,'station_name','محطة أ','now'),(8,'station_name','محطة ب','now'),(7,'diesel_price_per_liter','100','now'),(8,'diesel_price_per_liter','900','now')");
    database.execute("INSERT INTO settings(key,value,updated_at) VALUES('station_name','إعداد عام قديم','now')");
    database.execute('''
      CREATE TABLE beneficiaries (
        id INTEGER PRIMARY KEY,
        station_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        phone TEXT,
        status TEXT NOT NULL DEFAULT 'active'
      )
    ''');
    database.execute('''
      CREATE TABLE pumps (
        id INTEGER PRIMARY KEY,
        station_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        system_type TEXT NOT NULL DEFAULT 'diesel'
      )
    ''');
    database.execute('''
      CREATE TABLE irrigations (
        id INTEGER PRIMARY KEY,
        station_id INTEGER NOT NULL,
        pump_id INTEGER NOT NULL,
        beneficiary_id INTEGER NOT NULL,
        status TEXT NOT NULL,
        start_datetime TEXT NOT NULL,
        override_reason TEXT
      )
    ''');
    database.execute('''
      CREATE TABLE queue_entries (
        id INTEGER PRIMARY KEY,
        beneficiary_id INTEGER NOT NULL,
        position INTEGER NOT NULL DEFAULT 1,
        cycle_number INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        postponed_count INTEGER NOT NULL DEFAULT 0,
        skip_reason TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    database.execute('''
      CREATE TABLE booking_requests (
        id INTEGER PRIMARY KEY,
        beneficiary_id INTEGER NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        scheduled_date TEXT,
        scheduled_start TEXT,
        scheduled_end TEXT,
        reviewed_by INTEGER,
        reviewed_at TEXT,
        cancel_reason TEXT
      )
    ''');
    database.execute('''
      CREATE TABLE irrigation_sessions (
        id INTEGER PRIMARY KEY,
        beneficiary_id INTEGER NOT NULL,
        queue_entry_id INTEGER,
        booking_id INTEGER,
        pump_id INTEGER NOT NULL,
        planned_start TEXT NOT NULL,
        actual_start TEXT,
        timer_started_at TEXT,
        status TEXT NOT NULL,
        postponement_reason TEXT
      )
    ''');
    database.execute(
      'INSERT INTO app_users(id,station_id,name,role,username,password_hash,active) VALUES(1,7,?,?,?,?,1)',
      [
        'مدير الاختبار',
        'manager',
        'manager-test',
        sha256.convert(utf8.encode('correct-password')).toString(),
      ],
    );
    database.execute(
      "INSERT INTO beneficiaries(id,station_id,name) VALUES(10,7,'مستفيد أ'),(20,8,'مستفيد ب')",
    );
    database.execute(
      "INSERT INTO pumps(id,station_id,name) VALUES(100,7,'مضخة أ'),(200,8,'مضخة ب')",
    );
    database.execute("""
      INSERT INTO irrigations(id,station_id,pump_id,beneficiary_id,status,start_datetime)
      VALUES(1000,7,100,10,'posted','2026-11-01T08:00:00'),
            (2000,8,200,20,'posted','2026-11-01T09:00:00')
    """);
    database.execute("""
      INSERT INTO queue_entries(id,beneficiary_id,position,status,created_at,updated_at)
      VALUES(3000,10,1,'waiting','2026-11-01','2026-11-01'),
            (4000,20,1,'waiting','2026-11-01','2026-11-01')
    """);
    database.execute("""
      INSERT INTO booking_requests(id,beneficiary_id,status,created_at)
      VALUES(5000,10,'new','2026-11-01'),
            (6000,20,'new','2026-11-01')
    """);
    database.execute("""
      INSERT INTO irrigation_sessions(id,beneficiary_id,pump_id,planned_start,status)
      VALUES(7000,10,100,'2026-11-01T08:00:00','running'),
            (8000,20,200,'2026-11-01T09:00:00','running')
    """);
    handler = SaqiaServer(database, jwtSecret: secret).router().call;
  });

  tearDown(() => database.dispose());

  Future<String> login() async {
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/auth/login'),
        body: jsonEncode({
          'username': 'manager-test',
          'password': 'correct-password',
        }),
      ),
    );
    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map;
    return body['token'] as String;
  }

  Future<Response> request(
    String method,
    String path,
    String token, {
    Object? body,
  }) async =>
      await handler(
        Request(
          method,
          Uri.parse('http://localhost$path'),
          headers: {
            'authorization': 'Bearer $token',
            if (body != null) 'content-type': 'application/json',
          },
          body: body == null ? null : jsonEncode(body),
        ),
      );

  test('settings are isolated by station and never expose legacy global values', () async {
    final token = await login();
    final response = await request('GET', '/api/v1/settings', token);
    final values = jsonDecode(await response.readAsString()) as Map;
    expect(response.statusCode, 200);
    expect(values['station_name'], 'محطة أ');
    expect(values['diesel_price_per_liter'], '100');
    expect(values.containsValue('محطة ب'), isFalse);
    expect(values.containsValue('إعداد عام قديم'), isFalse);
  });

  test('updating settings changes only the authenticated station', () async {
    final token = await login();
    final response = await request('PUT', '/api/v1/settings', token,
        body: {'station_name': 'محطة أ المعدلة'});
    expect(response.statusCode, 200);
    expect(database.select("SELECT value FROM station_settings WHERE station_id=7 AND key='station_name'").first['value'], 'محطة أ المعدلة');
    expect(database.select("SELECT value FROM station_settings WHERE station_id=8 AND key='station_name'").first['value'], 'محطة ب');
    expect(database.select("SELECT value FROM settings WHERE key='station_name'").first['value'], 'إعداد عام قديم');
  });

  test('new journal entries persist the authenticated station explicitly', () async {
    database.execute('CREATE TABLE partners (id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, name TEXT NOT NULL)');
    database.execute('CREATE TABLE partner_transactions (id INTEGER PRIMARY KEY, partner_id INTEGER NOT NULL, date TEXT NOT NULL, type TEXT NOT NULL, amount INTEGER NOT NULL, ownership_snapshot REAL, reference_type TEXT, reference_id INTEGER, notes TEXT, created_by INTEGER)');
    database.execute('CREATE TABLE accounts (id INTEGER PRIMARY KEY, code TEXT NOT NULL, name TEXT NOT NULL)');
    database.execute('CREATE TABLE journal_entries (id INTEGER PRIMARY KEY, station_id INTEGER, date TEXT NOT NULL, reference_type TEXT, reference_id INTEGER, description TEXT NOT NULL, status TEXT NOT NULL, created_by INTEGER, created_at TEXT NOT NULL)');
    database.execute('CREATE TABLE journal_lines (id INTEGER PRIMARY KEY, journal_entry_id INTEGER NOT NULL, account_id INTEGER NOT NULL, beneficiary_id INTEGER, worker_id INTEGER, partner_id INTEGER, debit INTEGER NOT NULL DEFAULT 0, credit INTEGER NOT NULL DEFAULT 0, memo TEXT)');
    database.execute("INSERT INTO partners(id,station_id,name) VALUES(10,7,'شريك أ')");
    database.execute("INSERT INTO accounts(id,code,name) VALUES(1,'5000','مصروف'),(2,'2200','مستحقات')");
    final token = await login();
    final response = await request('POST', '/api/v1/partners/10/transactions', token,
        body: {'type': 'share_accrual', 'amount': 1250});
    expect(response.statusCode, 200);
    final entry = database.select('SELECT station_id,created_by FROM journal_entries').first;
    expect(entry['station_id'], 7);
    expect(entry['created_by'], 1);
    expect(database.select('SELECT station_id FROM partner_transactions').first['station_id'], 7);
  });

  test('irrigation list only returns records belonging to the manager station',
      () async {
    final token = await login();
    final response = await request('GET', '/api/v1/irrigations', token);
    final rows = jsonDecode(await response.readAsString()) as List;

    expect(response.statusCode, 200);
    expect(rows.map((row) => row['id']), [1000]);
  });

  test('cannot cancel an irrigation belonging to another station', () async {
    final token = await login();
    final response = await request(
      'POST',
      '/api/v1/irrigations/2000/cancel',
      token,
      body: {'reason': 'اختبار عزل'},
    );

    expect(response.statusCode, 404);
    expect(
      database.select('SELECT status FROM irrigations WHERE id=2000').first['status'],
      'posted',
    );
  });

  test('beneficiary statement rejects a beneficiary from another station',
      () async {
    final token = await login();
    final response =
        await request('GET', '/api/v1/beneficiaries/20/statement', token);

    expect(response.statusCode, 404);
  });

  test('queue list only returns beneficiaries from the manager station',
      () async {
    final token = await login();
    final response = await request('GET', '/api/v1/queue', token);
    final rows = jsonDecode(await response.readAsString()) as List;

    expect(response.statusCode, 200);
    expect(rows.map((row) => row['id']), [3000]);
  });

  test('cannot postpone a queue entry belonging to another station',
      () async {
    final token = await login();
    final response = await request(
      'POST',
      '/api/v1/queue/4000/postpone',
      token,
      body: {'reason': 'اختبار عزل'},
    );

    expect(response.statusCode, 404);
    expect(
      database.select('SELECT status FROM queue_entries WHERE id=4000').first['status'],
      'waiting',
    );
  });

  test('booking list only returns requests from the manager station',
      () async {
    final token = await login();
    final response = await request('GET', '/api/v1/bookings', token);
    final rows = jsonDecode(await response.readAsString()) as List;

    expect(response.statusCode, 200);
    expect(rows.map((row) => row['id']), [5000]);
  });

  test('cannot schedule a booking belonging to another station', () async {
    final token = await login();
    final response = await request(
      'POST',
      '/api/v1/bookings/6000/schedule',
      token,
      body: {'date': '2026-11-08', 'start': '09:00', 'end': '10:00'},
    );

    expect(response.statusCode, 404);
    expect(
      database.select('SELECT status FROM booking_requests WHERE id=6000').first['status'],
      'new',
    );
  });

  test('session list only returns sessions from the manager station',
      () async {
    final token = await login();
    final response = await request('GET', '/api/v1/sessions', token);
    final rows = jsonDecode(await response.readAsString()) as List;

    expect(response.statusCode, 200);
    expect(rows.map((row) => row['id']), [7000]);
  });

  test('cannot postpone a session belonging to another station', () async {
    final token = await login();
    final response = await request(
      'POST',
      '/api/v1/sessions/8000/postpone',
      token,
      body: {'reason': 'اختبار عزل'},
    );

    expect(response.statusCode, 404);
    expect(
      database.select('SELECT status FROM irrigation_sessions WHERE id=8000').first['status'],
      'running',
    );
  });
  test('full database backup is blocked until station-scoped export exists', () async {
    final token = await login();
    final before = database.select('SELECT COUNT(*) AS total FROM beneficiaries').first['total'];
    final response = await request('POST', '/api/v1/backup', token,
        body: {'path': 'must_not_be_created.db'});
    final body = jsonDecode(await response.readAsString()) as Map;

    expect(response.statusCode, 409);
    expect(body['ok'], isNull);
    expect(database.select('SELECT COUNT(*) AS total FROM beneficiaries').first['total'], before);
  });

  test('full database restore is blocked without changing live database', () async {
    final token = await login();
    final before = database.select('SELECT COUNT(*) AS total FROM beneficiaries').first['total'];
    final response = await request('POST', '/api/v1/restore', token,
        body: {'base64': 'U1FMaXRlIGZvcm1hdCAz'});
    final body = jsonDecode(await response.readAsString()) as Map;

    expect(response.statusCode, 409);
    expect(body['ok'], isNull);
    expect(database.select('SELECT COUNT(*) AS total FROM beneficiaries').first['total'], before);
  });
}
