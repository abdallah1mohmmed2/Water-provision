import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:saqia_server/server.dart';
import 'package:saqia_server/password_hasher.dart';
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
    database.execute(
      'INSERT INTO app_users(id,station_id,name,role,username,password_hash,active) VALUES(1,7,?,?,?,?,1)',
      [
        'مدير الاختبار',
        'manager',
        'manager-test',
        sha256.convert(utf8.encode('correct-password')).toString(),
      ],
    );
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

  Future<Response> readSettings(String token) async => await handler(
    Request(
      'GET',
      Uri.parse('http://localhost/api/v1/settings'),
      headers: {'authorization': 'Bearer $token'},
    ),
  );

  test('accepts a JWT while the issuing account remains active and unchanged',
      () async {
    final token = await login();

    final response = await readSettings(token);

    expect(response.statusCode, 200);
  });

  test('revokes an existing JWT immediately after account deactivation',
      () async {
    final token = await login();
    database.execute('UPDATE app_users SET active=0 WHERE id=1');

    final response = await readSettings(token);

    expect(response.statusCode, 401);
  });

  test('revokes an existing JWT immediately after role change', () async {
    final token = await login();
    database.execute(
      "UPDATE app_users SET role='operations' WHERE id=1",
    );

    final response = await readSettings(token);

    expect(response.statusCode, 401);
  });

  test('revokes an existing JWT immediately after station reassignment',
      () async {
    final token = await login();
    database.execute('UPDATE app_users SET station_id=8 WHERE id=1');

    final response = await readSettings(token);

    expect(response.statusCode, 401);
  });
  test('legacy SHA-256 admin password upgrades to Argon2id after valid login', () async {
    final legacyHash = database.select('SELECT password_hash FROM app_users WHERE id=1').first['password_hash'];
    await login();
    final upgradedHash = database.select('SELECT password_hash FROM app_users WHERE id=1').first['password_hash'] as String;
    expect(upgradedHash, startsWith(r'$argon2id$'));
    expect(upgradedHash, isNot(legacyHash));
    expect(await PasswordHasher.verify('correct-password', upgradedHash), isTrue);
    expect(await PasswordHasher.verify('incorrect-password', upgradedHash), isFalse);
  });

  test('incorrect legacy password never changes the stored hash', () async {
    final legacyHash = database.select('SELECT password_hash FROM app_users WHERE id=1').first['password_hash'];
    final response = await handler(Request(
      'POST',
      Uri.parse('http://localhost/api/v1/auth/login'),
      body: jsonEncode({'username': 'manager-test', 'password': 'incorrect-password'}),
    ));
    expect(response.statusCode, 401);
    expect(database.select('SELECT password_hash FROM app_users WHERE id=1').first['password_hash'], legacyHash);
  });

  test('existing Argon2id password authenticates without being rewritten', () async {
    final argonHash = await PasswordHasher.hash('correct-password');
    database.execute('UPDATE app_users SET password_hash=? WHERE id=1', [argonHash]);
    await login();
    expect(database.select('SELECT password_hash FROM app_users WHERE id=1').first['password_hash'], argonHash);
  });
}
