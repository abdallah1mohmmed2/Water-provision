import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../lib/server.dart';
import '../lib/server_config.dart';

void main() {
  group('JWT server configuration', () {
    test('rejects a missing secret', () {
      expect(() => requireJwtSecret({}), throwsStateError);
    });

    test('rejects a short secret', () {
      expect(
        () => requireJwtSecret({'SAQIA_JWT_SECRET': 'too-short'}),
        throwsStateError,
      );
    });

    test('accepts and trims a sufficiently long secret', () {
      final secret = '  ${'x' * 32}  ';
      expect(
        requireJwtSecret({'SAQIA_JWT_SECRET': secret}),
        'x' * 32,
      );
    });
  });

  group('SaqiaServer router', () {
    const secret = 'unit-test-only-secret-with-at-least-32-chars';
    late Database database;
    late Handler handler;

    setUp(() {
      database = sqlite3.openInMemory();
      handler = SaqiaServer(database, jwtSecret: secret).router();
    });

    tearDown(() => database.dispose());

    test('serves the public server time as UTC', () async {
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/v1/time')),
      );

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map;
      final timestamp = DateTime.parse(body['now'] as String);
      expect(timestamp.isUtc, isTrue);
    });

    test('rejects protected admin routes without a token', () async {
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/v1/dashboard')),
      );

      expect(response.statusCode, 401);
    });

    test('rejects a valid token with an unauthorized role', () async {
      final token = JWT({'role': 'beneficiary'}).sign(SecretKey(secret));
      final response = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/v1/dashboard'),
          headers: {'authorization': 'Bearer $token'},
        ),
      );

      expect(response.statusCode, 403);
    });
  });
}
