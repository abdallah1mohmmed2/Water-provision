import 'dart:io';

import 'package:saqia_server/server_config.dart';
import 'package:test/test.dart';

void main() {
  const secret = 'a-strong-random-secret-with-at-least-32-bytes';

  group('ServerConfig.fromEnvironment', () {
    test('requires an explicit strong JWT secret', () {
      expect(
        () => ServerConfig.fromEnvironment(const {}),
        throwsA(isA<StateError>()),
      );
      expect(
        () => ServerConfig.fromEnvironment({
          'SAQIA_JWT_SECRET': 'short',
        }),
        throwsA(isA<StateError>()),
      );
      expect(
        () => ServerConfig.fromEnvironment({
          'SAQIA_JWT_SECRET': 'CHANGE_THIS_IN_PRODUCTION',
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('defaults to loopback and the existing local database path', () {
      final config = ServerConfig.fromEnvironment({
        'SAQIA_JWT_SECRET': secret,
      });

      expect(config.bindAddress, InternetAddress.loopbackIPv4);
      expect(config.port, 8080);
      expect(config.databasePath, '../saqia_station_v2.db');
    });

    test('allows explicit LAN/cloud binding and database path', () {
      final config = ServerConfig.fromEnvironment({
        'SAQIA_JWT_SECRET': secret,
        'SAQIA_BIND_ADDRESS': '0.0.0.0',
        'PORT': '9090',
        'SAQIA_DB': '/var/lib/saqia/station.db',
      });

      expect(config.bindAddress.address, '0.0.0.0');
      expect(config.port, 9090);
      expect(config.databasePath, '/var/lib/saqia/station.db');
    });

    test('rejects invalid bind addresses and ports', () {
      expect(
        () => ServerConfig.fromEnvironment({
          'SAQIA_JWT_SECRET': secret,
          'SAQIA_BIND_ADDRESS': 'not-an-ip',
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ServerConfig.fromEnvironment({
          'SAQIA_JWT_SECRET': secret,
          'PORT': '70000',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
