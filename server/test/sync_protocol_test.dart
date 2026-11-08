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
        '{"name":"Test Beneficiary"}');
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

  test('stale base version is recorded as conflict without advancing version', () async {
    await postEvents(stationOneToken,[event()]);
    final stale = event(
      id:'22222222-2222-4222-8222-222222222222',
      baseVersion:0,
    );
    final result = await postEvents(stationOneToken,[stale],device:'device-c');
    expect((result['results'] as List).first['status'],'conflict');
    expect(database.select(
      "SELECT version FROM sync_entity_versions WHERE station_id=1 AND entity_key='beneficiary-42'",
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

}
