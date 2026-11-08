import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../lib/server.dart';

void main() {
  const secret = 'sync-protocol-test-secret-at-least-32-bytes';
  late Database database;
  late SaqiaServer server;
  late String stationOneToken;
  late String stationTwoToken;

  setUp(() {
    database = sqlite3.openInMemory();
    database.execute('CREATE TABLE stations(id INTEGER PRIMARY KEY, name TEXT NOT NULL)');
    database.execute('INSERT INTO stations(id,name) VALUES(1,\'Station One\'),(2,\'Station Two\')');
    database.execute('''CREATE TABLE beneficiaries(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      station_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      phone TEXT,
      address TEXT,
      location TEXT,
      jerba_number TEXT,
      area TEXT,
      is_needy INTEGER NOT NULL DEFAULT 0,
      notes TEXT,
      status TEXT NOT NULL DEFAULT 'active',
      created_at TEXT,
      updated_at TEXT
    )''');
    database.execute('''CREATE TABLE app_users(
      id INTEGER PRIMARY KEY, station_id INTEGER, role TEXT, active INTEGER
    )''');
    database.execute("INSERT INTO app_users(id,station_id,role,active) VALUES(11,1,'manager',1),(22,2,'manager',1)");
    server = SaqiaServer(database, jwtSecret: secret);
    stationOneToken = JWT({'kind':'admin','userId':11,'stationId':1,'role':'manager'})
        .sign(SecretKey(secret));
    stationTwoToken = JWT({'kind':'admin','userId':22,'stationId':2,'role':'manager'})
        .sign(SecretKey(secret));
  });

  tearDown(() => database.dispose());

  Future<Map<String, dynamic>> postEvents(
    String token,
    List<Map<String, dynamic>> events, {
    String device = 'device-a',
  }) async {
    final response = await server.router().call(Request(
      'POST',
      Uri.parse('http://localhost/api/v1/sync/events'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: jsonEncode({'device_id':device,'events':events}),
    ));
    return jsonDecode(await response.readAsString()) as Map<String,dynamic>;
  }

  Future<Map<String, dynamic>> getInbox(
    String token, {
    String device = 'device-b',
  }) async {
    final response = await server.router().call(Request(
      'GET',
      Uri.parse('http://localhost/api/v1/sync/inbox?after=0&device_id=$device'),
      headers: {'authorization':'Bearer $token'},
    ));
    return jsonDecode(await response.readAsString()) as Map<String,dynamic>;
  }

  Map<String,dynamic> event({
    String id = '11111111-1111-4111-8111-111111111111',
    String globalId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    int baseVersion = 0,
    String operation = 'create',
    Map<String,dynamic>? payload,
  }) => {
    'event_id':id,
    'entity_type':'beneficiaries',
    'entity_key':'beneficiaries:$globalId',
    'operation':operation,
    'base_version':baseVersion,
    'payload':{
      '_global_id':globalId,
      'name':'Test Beneficiary',
      ...?payload,
    },
  };

  void prepareReceiptFixture({String beneficiaryGlobalId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'}) {
    database.execute("INSERT INTO beneficiaries(id,station_id,name,status) VALUES(1,1,'Receipt Beneficiary','active')");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(1,'beneficiaries',?,1,'2026-11-08T00:00:00Z')", [beneficiaryGlobalId]);
    database.execute('''CREATE TABLE cashboxes(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, name TEXT NOT NULL,
      opening_balance INTEGER NOT NULL DEFAULT 0, current_balance INTEGER NOT NULL DEFAULT 0,
      currency TEXT NOT NULL DEFAULT 'YER', active INTEGER NOT NULL DEFAULT 1,
      ledger_account_code TEXT
    )''');
    database.execute('''CREATE TABLE payment_methods(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, name TEXT NOT NULL,
      type TEXT NOT NULL, cashbox_id INTEGER, ledger_account_code TEXT, active INTEGER NOT NULL DEFAULT 1
    )''');
    database.execute('''CREATE TABLE payments(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, beneficiary_id INTEGER,
      partner_id INTEGER, worker_id INTEGER, amount INTEGER NOT NULL, date TEXT NOT NULL,
      payment_method_id INTEGER NOT NULL, cashbox_id INTEGER NOT NULL, reference_number TEXT,
      notes TEXT, status TEXT NOT NULL, created_by INTEGER
    )''');
    database.execute('CREATE TABLE accounts(id INTEGER PRIMARY KEY, code TEXT UNIQUE NOT NULL, name TEXT NOT NULL, type TEXT NOT NULL)');
    database.execute('''CREATE TABLE journal_entries(
      id INTEGER PRIMARY KEY, station_id INTEGER, date TEXT NOT NULL, reference_type TEXT,
      reference_id INTEGER, description TEXT NOT NULL, status TEXT NOT NULL,
      created_by INTEGER, created_at TEXT NOT NULL
    )''');
    database.execute('''CREATE TABLE journal_lines(
      id INTEGER PRIMARY KEY, journal_entry_id INTEGER NOT NULL, account_id INTEGER NOT NULL,
      beneficiary_id INTEGER, worker_id INTEGER, partner_id INTEGER, debit INTEGER NOT NULL DEFAULT 0,
      credit INTEGER NOT NULL DEFAULT 0, memo TEXT
    )''');
    database.execute("INSERT INTO cashboxes(id,station_id,name,current_balance,currency,active,ledger_account_code) VALUES(1,1,'Main Cashbox',500,'YER',1,'1000')");
    database.execute("INSERT INTO payment_methods(id,station_id,name,type,cashbox_id,ledger_account_code,active) VALUES(1,1,'Cash','cash',1,'1000',1)");
    database.execute("INSERT INTO accounts(id,code,name,type) VALUES(1,'1000','Cash','asset'),(2,'1200','Beneficiary receivables','asset')");
  }

  Map<String,dynamic> receiptEvent({
    String id = '33333333-3333-4333-8333-333333333333',
    String paymentGlobalId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    String beneficiaryGlobalId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    int amount = 250,
  }) => {
    'event_id': id,
    'entity_type': 'payments',
    'entity_key': 'payments:$paymentGlobalId',
    'operation': 'create',
    'base_version': 0,
    'payload': {
      '_global_id': paymentGlobalId, 'beneficiary_id': 1, 'partner_id': null, 'worker_id': null,
      'amount': amount, 'date': '2026-11-08T08:30:00.000', 'status': 'posted',
      'payment_method_id': 1, 'cashbox_id': 1, 'reference_number': 'RCPT-001', 'notes': 'test receipt',
      '_global_refs': {
        'beneficiary_id': {'table':'beneficiaries','global_id':beneficiaryGlobalId},
        'payment_method_id': {'table':'payment_methods','global_id':'dddddddd-dddd-4ddd-8ddd-dddddddddddd','name':'Cash','type':'cash'},
        'cashbox_id': {'table':'cashboxes','global_id':'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','name':'Main Cashbox','currency':'YER'},
      },
      '_unresolved_refs': {},
    },
  };

  test('beneficiary receipt applies once and replay returns duplicate without double posting', () async {
    prepareReceiptFixture();
    final command = receiptEvent();
    final first = await postEvents(stationOneToken, [command]);
    final replay = await postEvents(stationOneToken, [command]);
    expect((first['results'] as List).first['status'], 'accepted');
    expect((replay['results'] as List).first['status'], 'duplicate');
    expect(database.select('SELECT COUNT(*) AS n FROM payments').single['n'], 1);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'], 750);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_entries').single['n'], 1);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_lines').single['n'], 2);
    expect(database.select('SELECT SUM(debit) AS debit,SUM(credit) AS credit FROM journal_lines').single['debit'], 250);
    expect(database.select('SELECT SUM(debit) AS debit,SUM(credit) AS credit FROM journal_lines').single['credit'], 250);
  });

  test('receipt rejects a beneficiary identity owned by another station without writes', () async {
    prepareReceiptFixture();
    database.execute("INSERT INTO beneficiaries(id,station_id,name,status) VALUES(2,2,'Foreign Beneficiary','active')");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(2,'beneficiaries','ffffffff-ffff-4fff-8fff-ffffffffffff',2,'2026-11-08T00:00:00Z')");
    final result = await postEvents(stationOneToken, [receiptEvent(beneficiaryGlobalId:'ffffffff-ffff-4fff-8fff-ffffffffffff')]);
    expect((result['results'] as List).first['status'], 'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM payments').single['n'], 0);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'], 500);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_entries').single['n'], 0);
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').single['n'], 0);
  });

  test('receipt rejects a globally identified payment method from another station', () async {
    prepareReceiptFixture();
    database.execute("INSERT INTO payment_methods(id,station_id,name,type,cashbox_id,ledger_account_code,active) VALUES(2,2,'Cash','cash',NULL,'1000',1)");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(2,'payment_methods','ffffffff-ffff-4fff-8fff-ffffffffffff',2,'2026-11-08T00:00:00Z')");
    final command = receiptEvent();
    final payload = Map<String,dynamic>.from(command['payload'] as Map);
    final refs = Map<String,dynamic>.from(payload['_global_refs'] as Map);
    refs['payment_method_id'] = {'table':'payment_methods','global_id':'ffffffff-ffff-4fff-8fff-ffffffffffff','name':'Cash','type':'cash'};
    payload['_global_refs'] = refs;
    command['payload'] = payload;
    final result = await postEvents(stationOneToken,[command]);
    expect((result['results'] as List).first['status'],'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM payments').single['n'],0);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],500);
  });

  test('operations role cannot submit beneficiary receipt commands', () async {
    prepareReceiptFixture();
    final operationsToken = JWT({'kind':'admin','userId':11,'stationId':1,'role':'operations'}).sign(SecretKey(secret));
    final result = await postEvents(operationsToken,[receiptEvent()]);
    expect((result['results'] as List).first['status'],'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM payments').single['n'],0);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],500);
  });

  test('receipt rejects zero amount without creating any financial rows', () async {
    prepareReceiptFixture();
    final result = await postEvents(stationOneToken,[receiptEvent(amount:0)]);
    expect((result['results'] as List).first['status'],'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM payments').single['n'],0);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],500);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_entries').single['n'],0);
  });

  test('receipt event id cannot be reused with a changed amount', () async {
    prepareReceiptFixture();
    final first = await postEvents(stationOneToken,[receiptEvent()]);
    final changed = await postEvents(stationOneToken,[receiptEvent(amount:999)]);
    expect((first['results'] as List).first['status'],'accepted');
    expect((changed['results'] as List).first['status'],'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM payments').single['n'],1);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],750);
  });

  test('receipt journal failure rolls back payment and cashbox balance', () async {
    prepareReceiptFixture();
    database.execute("DELETE FROM accounts WHERE code='1200'");
    final result = await postEvents(stationOneToken, [receiptEvent()]);
    expect((result['results'] as List).first['status'], 'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM payments').single['n'], 0);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'], 500);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_entries').single['n'], 0);
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').single['n'], 0);
  });

  test('replayed event is acknowledged as duplicate and stored once', () async {
    final first = await postEvents(stationOneToken,[event()]);
    final replay = await postEvents(stationOneToken,[event()]);
    expect((first['results'] as List).first['status'],'accepted');
    expect((replay['results'] as List).first['status'],'duplicate');
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').first['n'],1);
    expect(database.select('SELECT COUNT(*) AS n FROM beneficiaries WHERE station_id=1').first['n'],1);
  });

  test('reusing an event id with a different payload is rejected', () async {
    final first = await postEvents(stationOneToken, [event()]);
    final changed = event();
    changed['payload'] = {
      '_global_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'name': 'Tampered Beneficiary',
    };
    final replay = await postEvents(stationOneToken, [changed]);
    expect((first['results'] as List).first['status'], 'accepted');
    expect((replay['results'] as List).first['status'], 'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').first['n'], 1);
    expect(database.select('SELECT payload_json FROM sync_event_log').first['payload_json'],
        '{"_global_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Test Beneficiary"}');
  });

  test('unsupported entity types are rejected before entering the event log', () async {
    final invalid = event();
    invalid['entity_type'] = 'app_users';
    invalid['entity_key'] = 'app_users:admin';
    final response = await postEvents(stationOneToken, [invalid]);
    expect((response['results'] as List).first['status'], 'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').first['n'], 0);
    expect(database.select('SELECT COUNT(*) AS n FROM sync_entity_versions').first['n'], 0);
  });

  test('recognized but unimplemented financial events are rejected without acknowledgement', () async {
    final invalid = event();
    invalid['entity_type'] = 'payments';
    invalid['entity_key'] = 'payments:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final response = await postEvents(stationOneToken, [invalid]);
    expect((response['results'] as List).first['status'], 'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').single['n'], 0);
  });

  test('stale base version is recorded as conflict without advancing version', () async {
    await postEvents(stationOneToken,[event()]);
    final stale = event(
      id:'22222222-2222-4222-8222-222222222222',
      baseVersion:0,
    );
    final result = await postEvents(stationOneToken,[stale],device:'device-c');
    expect((result['results'] as List).first['status'],'conflict');
    expect(database.select(
      "SELECT version FROM sync_entity_versions WHERE station_id=1 AND entity_key='beneficiaries:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'",
    ).first['version'],1);
  });

  test('inbox is isolated by authenticated station', () async {
    await postEvents(stationOneToken,[event()]);
    final one = await getInbox(stationOneToken);
    final two = await getInbox(stationTwoToken);
    expect((one['events'] as List).length,1);
    expect((two['events'] as List),isEmpty);
  });

  test('inbox does not echo events back to their originating device', () async {
    await postEvents(stationOneToken,[event()],device:'device-a');
    final inbox = await getInbox(stationOneToken,device:'device-a');
    expect((inbox['events'] as List),isEmpty);
  });
  test('beneficiary create and update are applied atomically to business rows', () async {
    const globalId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final first = await postEvents(stationOneToken, [
      event(globalId: globalId, payload: {'phone': '777'}),
    ]);
    expect((first['results'] as List).first['status'], 'accepted');
    final row = database.select(
      "SELECT id,name,phone,station_id FROM beneficiaries WHERE station_id=1",
    ).single;
    expect(row['name'], 'Test Beneficiary');
    expect(row['phone'], '777');
    expect(row['station_id'], 1);

    final second = await postEvents(stationOneToken, [
      event(
        id: '44444444-4444-4444-8444-444444444444',
        globalId: globalId,
        baseVersion: 1,
        operation: 'update',
        payload: {'name': 'Updated Beneficiary'},
      ),
    ]);
    expect((second['results'] as List).first['status'], 'accepted');
    expect(database.select(
      "SELECT name FROM beneficiaries WHERE station_id=1",
    ).single['name'], 'Updated Beneficiary');
    expect(database.select(
      "SELECT version FROM sync_entity_versions WHERE station_id=1 AND entity_key='beneficiaries:$globalId'",
    ).single['version'], 2);
  });

  test('failed business application rolls back event log and entity version', () async {
    final invalid = event(payload: {'name': ''});
    final response = await postEvents(stationOneToken, [invalid]);
    expect((response['results'] as List).first['status'], 'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM beneficiaries').single['n'], 0);
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').single['n'], 0);
    expect(database.select('SELECT COUNT(*) AS n FROM sync_entity_versions').single['n'], 0);
  });

  test('event from another station cannot create a row in the first station', () async {
    final response = await postEvents(stationTwoToken, [event()]);
    expect((response['results'] as List).first['status'], 'accepted');
    expect(database.select('SELECT COUNT(*) AS n FROM beneficiaries WHERE station_id=1').single['n'], 0);
    expect(database.select('SELECT COUNT(*) AS n FROM beneficiaries WHERE station_id=2').single['n'], 1);
  });


  test('beneficiary API reads expose the stable global identity for client mapping', () async {
    const globalId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    final created = await postEvents(stationOneToken, [
      event(globalId: globalId, payload: {'name': 'Mapped Beneficiary'}),
    ]);
    expect((created['results'] as List).first['status'], 'accepted');

    final response = await server.router().call(Request(
      'GET',
      Uri.parse('http://localhost/api/v1/beneficiaries'),
      headers: {'authorization': 'Bearer $stationOneToken'},
    ));
    expect(response.statusCode, 200);
    final rows = jsonDecode(await response.readAsString()) as List;
    expect(rows, hasLength(1));
    expect(rows.single['_global_id'], globalId);
    expect(rows.single['name'], 'Mapped Beneficiary');
  });



    test('beneficiary detail and irrigation history resolve global UUID within JWT station', () async {
    const globalId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    database.execute('ALTER TABLE beneficiaries ADD COLUMN opening_balance INTEGER NOT NULL DEFAULT 0');
    database.execute('ALTER TABLE beneficiaries ADD COLUMN carried_balance INTEGER NOT NULL DEFAULT 0');
    database.execute('''CREATE TABLE station_settings(
      station_id INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
      PRIMARY KEY(station_id,key)
    )''');
    await postEvents(stationOneToken, [
      event(globalId: globalId, payload: {'name': 'Global Detail'}),
    ]);
    database.execute('''CREATE TABLE irrigations(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL,
      beneficiary_id INTEGER NOT NULL, date TEXT NOT NULL DEFAULT '2026-11-08',
      start_datetime TEXT NOT NULL, end_datetime TEXT,
      system_type TEXT, minutes INTEGER NOT NULL DEFAULT 0,
      cloud_minutes INTEGER NOT NULL DEFAULT 0,
      chargeable_minutes INTEGER NOT NULL DEFAULT 0,
      total_amount INTEGER NOT NULL DEFAULT 0,
      paid_amount INTEGER NOT NULL DEFAULT 0, notes TEXT,
      status TEXT NOT NULL
    )''');
    database.execute('''CREATE TABLE payments(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL,
      beneficiary_id INTEGER, date TEXT NOT NULL,
      amount INTEGER NOT NULL, status TEXT NOT NULL, notes TEXT
    )''');
    database.execute('''CREATE TABLE diesel_movements(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL,
      beneficiary_id INTEGER, irrigation_id INTEGER,
      kind TEXT NOT NULL, amount INTEGER NOT NULL,
      date TEXT NOT NULL, notes TEXT
    )''');
    database.execute('''CREATE TABLE beneficiary_manual_debts(
      id INTEGER PRIMARY KEY, beneficiary_id INTEGER NOT NULL,
      date TEXT NOT NULL, amount INTEGER NOT NULL, notes TEXT,
      status TEXT NOT NULL, cancelled_at TEXT, cancel_reason TEXT
    )''');
    database.execute("INSERT INTO irrigations(id,station_id,beneficiary_id,start_datetime,status) VALUES(1,1,1,'2026-11-08T08:00:00','posted')");
    Future<Response> get(String token, String suffix) => server.router().call(Request(
      'GET',
      Uri.parse('http://localhost/api/v1/beneficiaries/$globalId$suffix'),
      headers: {'authorization': 'Bearer $token'},
    ));
    final detail = await get(stationOneToken, '');
    expect(detail.statusCode, 200);
    final body = jsonDecode(await detail.readAsString()) as Map<String, dynamic>;
    expect(body['_global_id'], globalId);
    expect(body['name'], 'Global Detail');
    final history = await get(stationOneToken, '/statement');
    expect(history.statusCode, 200);
    final rows = jsonDecode(await history.readAsString()) as List;
    expect(rows, hasLength(1));
    expect(rows.single['id'], 1);
    final crossStation = await get(stationTwoToken, '');
    expect(crossStation.statusCode, 404);
  });

  test('complete beneficiary statement is station-isolated and does not duplicate ledger movements', () async {
    const globalId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    database.execute('ALTER TABLE beneficiaries ADD COLUMN opening_balance INTEGER NOT NULL DEFAULT 0');
    database.execute('ALTER TABLE beneficiaries ADD COLUMN carried_balance INTEGER NOT NULL DEFAULT 0');
    await postEvents(stationOneToken, [
      event(globalId: globalId, payload: {'name': 'Statement Beneficiary'}),
    ]);
    database.execute("UPDATE beneficiaries SET opening_balance=40,carried_balance=5 WHERE station_id=1");
    database.execute('''CREATE TABLE irrigations(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL,
      beneficiary_id INTEGER NOT NULL, date TEXT NOT NULL,
      start_datetime TEXT, end_datetime TEXT, system_type TEXT,
      minutes INTEGER, cloud_minutes INTEGER, chargeable_minutes INTEGER,
      total_amount INTEGER NOT NULL, paid_amount INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL, notes TEXT
    )''');
    database.execute('''CREATE TABLE payments(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL,
      beneficiary_id INTEGER, date TEXT NOT NULL, amount INTEGER NOT NULL,
      status TEXT NOT NULL, notes TEXT
    )''');
    database.execute('''CREATE TABLE diesel_movements(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL,
      beneficiary_id INTEGER, irrigation_id INTEGER, kind TEXT NOT NULL,
      amount INTEGER NOT NULL, date TEXT NOT NULL, notes TEXT
    )''');
    database.execute('''CREATE TABLE beneficiary_manual_debts(
      id INTEGER PRIMARY KEY, beneficiary_id INTEGER NOT NULL,
      date TEXT NOT NULL, amount INTEGER NOT NULL, notes TEXT,
      status TEXT NOT NULL, cancelled_at TEXT, cancel_reason TEXT
    )''');
    database.execute('''CREATE TABLE station_settings(
      station_id INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
      PRIMARY KEY(station_id,key)
    )''');
    database.execute("INSERT INTO station_settings(station_id,key,value) VALUES(1,'diesel_delivery_financial_credit','true')");
    database.execute("INSERT INTO irrigations(id,station_id,beneficiary_id,date,start_datetime,end_datetime,system_type,minutes,cloud_minutes,chargeable_minutes,total_amount,paid_amount,status,notes) VALUES(1,1,1,'2026-11-01','2026-11-01T08:00:00','2026-11-01T09:00:00','diesel',60,0,60,100,0,'posted','first irrigation')");
    database.execute("INSERT INTO payments(id,station_id,beneficiary_id,date,amount,status,notes) VALUES(1,1,1,'2026-11-02',30,'posted','cash receipt')");
    database.execute("INSERT INTO diesel_movements(id,station_id,beneficiary_id,irrigation_id,kind,amount,date,notes) VALUES(1,1,1,NULL,'advance',10,'2026-11-03','diesel advance'),(2,1,1,NULL,'delivery',5,'2026-11-04','diesel delivery')");
    database.execute("INSERT INTO beneficiary_manual_debts(id,beneficiary_id,date,amount,notes,status) VALUES(1,1,'2026-11-02',20,'manual balance','posted')");
    database.execute("INSERT INTO beneficiary_manual_debts(id,beneficiary_id,date,amount,notes,status,cancelled_at,cancel_reason) VALUES(2,1,'2026-11-01',7,'cancelled debt','cancelled','2026-11-05','duplicate entry')");

    Future<List<dynamic>> read(String token, String suffix) async {
      final response = await server.router().call(Request(
        'GET',
        Uri.parse('http://localhost/api/v1/beneficiaries/$globalId/statement$suffix'),
        headers: {'authorization': 'Bearer $token'},
      ));
      expect(response.statusCode, 200);
      return jsonDecode(await response.readAsString()) as List<dynamic>;
    }

    final first = await read(stationOneToken, '');
    final replay = await read(stationOneToken, '');
    expect(first, hasLength(9)); // 2 opening rows + 7 distinct source movements.
    expect(replay, first);
    expect(first.map((row) => '${row['type']}:${row['id']}').toSet(), hasLength(9));
    expect(first.last['balance'], 140); // 45 + 100 - 30 + 10 + 20 - 5.
    expect(first.map((row) => row['type']), containsAll([
      's','p','a','manual_debt','manual_debt_reversal','d',
    ]));
    final period = await read(
      stationOneToken,
      '?from=2026-11-02&to=2026-11-03',
    );
    expect(period.first['type'], 'opening_balance');
    expect(period.first['balance'], 152); // Includes the cancelled debt until its 5 November reversal.
    expect(period.last['balance'], 152); // 152 - 30 + 20 + 10.
    final foreign = await server.router().call(Request(
      'GET',
      Uri.parse('http://localhost/api/v1/beneficiaries/$globalId/statement'),
      headers: {'authorization': 'Bearer $stationTwoToken'},
    ));
    expect(foreign.statusCode, 404);
  });

test('legacy beneficiary rows receive a stable global identity on first API read', () async {
    database.execute(
      "INSERT INTO beneficiaries(station_id,name,status) VALUES(1,'Legacy Beneficiary','active')",
    );
    Future<Map<String, dynamic>> read() async {
      final response = await server.router().call(Request(
        'GET',
        Uri.parse('http://localhost/api/v1/beneficiaries'),
        headers: {'authorization': 'Bearer $stationOneToken'},
      ));
      expect(response.statusCode, 200);
      final rows = jsonDecode(await response.readAsString()) as List;
      return Map<String, dynamic>.from(
        rows.singleWhere((row) => row['name'] == 'Legacy Beneficiary') as Map,
      );
    }
    final first = await read();
    final second = await read();
    expect(first['_global_id'], isA<String>());
    expect(first['_global_id'], isNotEmpty);
    expect(second['_global_id'], first['_global_id']);
    expect(first['balance'], 0);
  });



  test('beneficiary API computes balance using only the authenticated station data', () async {
    database.execute('ALTER TABLE beneficiaries ADD COLUMN opening_balance INTEGER NOT NULL DEFAULT 0');
    database.execute('ALTER TABLE beneficiaries ADD COLUMN carried_balance INTEGER NOT NULL DEFAULT 0');
    database.execute('''CREATE TABLE station_settings(
      station_id INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
      PRIMARY KEY(station_id,key)
    )''');
    database.execute('''CREATE TABLE irrigations(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, beneficiary_id INTEGER NOT NULL,
      total_amount INTEGER NOT NULL, status TEXT NOT NULL
    )''');
    database.execute('''CREATE TABLE payments(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, beneficiary_id INTEGER NOT NULL,
      amount INTEGER NOT NULL, status TEXT NOT NULL
    )''');
    database.execute('''CREATE TABLE diesel_movements(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, beneficiary_id INTEGER NOT NULL,
      amount INTEGER NOT NULL, kind TEXT NOT NULL, irrigation_id INTEGER
    )''');
    database.execute('''CREATE TABLE beneficiary_manual_debts(
      id INTEGER PRIMARY KEY, beneficiary_id INTEGER NOT NULL,
      amount INTEGER NOT NULL, status TEXT NOT NULL
    )''');
    database.execute("INSERT INTO beneficiaries(id,station_id,name,status,opening_balance,carried_balance) VALUES(1,1,'Balance A','active',100,20),(2,2,'Balance B','active',500,0)");
    database.execute("INSERT INTO irrigations(station_id,beneficiary_id,total_amount,status) VALUES(1,1,300,'posted'),(2,2,9000,'posted')");
    database.execute("INSERT INTO payments(station_id,beneficiary_id,amount,status) VALUES(1,1,50,'posted'),(2,2,1000,'posted')");
    database.execute("INSERT INTO beneficiary_manual_debts(beneficiary_id,amount,status) VALUES(1,30,'posted')");
    database.execute("INSERT INTO diesel_movements(station_id,beneficiary_id,amount,kind,irrigation_id) VALUES(1,1,10,'advance',NULL)");
    database.execute("INSERT INTO station_settings(station_id,key,value) VALUES(1,'diesel_delivery_financial_credit','false')");

    final response = await server.router().call(Request(
      'GET',
      Uri.parse('http://localhost/api/v1/beneficiaries'),
      headers: {'authorization': 'Bearer $stationOneToken'},
    ));
    expect(response.statusCode, 200);
    final rows = jsonDecode(await response.readAsString()) as List;
    final beneficiary = rows.singleWhere((row) => row['name'] == 'Balance A');
    // Opening 120 + irrigation 300 + manual debt 30 + diesel advance 10 - payment 50.
    expect(beneficiary['balance'], 410);
    expect(rows.where((row) => row['name'] == 'Balance B'), isEmpty);
  });


}
