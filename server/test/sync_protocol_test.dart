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
    String key = 'beneficiary-42',
    int baseVersion = 0,
  }) => {
    'event_id':id,
    'entity_type':'beneficiaries',
    'entity_key':key,
    'operation':'update',
    'base_version':baseVersion,
    'payload':{'name':'Test Beneficiary'},
  };

  test('replayed event is acknowledged as duplicate and stored once', () async {
    final first = await postEvents(stationOneToken,[event()]);
    final replay = await postEvents(stationOneToken,[event()]);
    expect((first['results'] as List).first['status'],'accepted');
    expect((replay['results'] as List).first['status'],'duplicate');
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').first['n'],1);
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
  test('global key adoption preserves the existing local-key server version', () async {
    final legacy = {
      'event_id':'33333333-3333-4333-8333-333333333333',
      'entity_type':'beneficiaries',
      'entity_key':'beneficiaries:42',
      'operation':'update',
      'base_version':0,
      'payload':{'id':42,'name':'Existing Beneficiary'},
    };
    final first = await postEvents(stationOneToken,[legacy]);
    expect((first['results'] as List).first['status'],'accepted');

    const globalId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final adopted = {
      'event_id':'44444444-4444-4444-8444-444444444444',
      'entity_type':'beneficiaries',
      'entity_key':'beneficiaries:$globalId',
      'operation':'update',
      'base_version':1,
      'payload':{
        'id':42,
        '_global_id':globalId,
        '_global_refs':{},
        'name':'Existing Beneficiary updated',
      },
    };
    final second = await postEvents(stationOneToken,[adopted]);
    expect((second['results'] as List).first['status'],'accepted');
    expect((second['results'] as List).first['server_version'],2);
    expect(database.select(
      "SELECT version FROM sync_entity_versions WHERE station_id=1 AND entity_type='beneficiaries' AND entity_key='beneficiaries:$globalId'",
    ).single['version'],2);
    expect(database.select(
      "SELECT COUNT(*) AS n FROM sync_entity_versions WHERE station_id=1 AND entity_key='beneficiaries:42'",
    ).single['n'],0);
    expect(database.select(
      "SELECT entity_key FROM sync_event_log WHERE event_id='33333333-3333-4333-8333-333333333333'",
    ).single['entity_key'],'beneficiaries:$globalId');
  });

}
