import 'dart:convert';
import 'dart:io';

/// Validated runtime configuration for the Shelf API.
///
/// The server binds to loopback by default. Exposing it to a LAN or cloud
/// runtime must be an explicit deployment decision.
class ServerConfig {
  const ServerConfig({
    required this.databasePath,
    required this.jwtSecret,
    required this.bindAddress,
    required this.port,
  });

  final String databasePath;
  final String jwtSecret;
  final InternetAddress bindAddress;
  final int port;

  factory ServerConfig.fromEnvironment(Map<String, String> environment) {
    final secret = environment['SAQIA_JWT_SECRET']?.trim();
    if (secret == null ||
        secret.toLowerCase().contains('change_this') ||
        utf8.encode(secret).length < 32) {
      throw StateError(
        'Startup refused: set SAQIA_JWT_SECRET to a random secret of at '
        'least 32 UTF-8 bytes. The built-in development secret is disabled.',
      );
    }

    final rawAddress = environment['SAQIA_BIND_ADDRESS']?.trim();
    final addressText =
        rawAddress == null || rawAddress.isEmpty ? '127.0.0.1' : rawAddress;
    final address = InternetAddress.tryParse(addressText);
    if (address == null) {
      throw FormatException(
        'SAQIA_BIND_ADDRESS must be an IP address, got: $addressText',
      );
    }

    final rawPort = environment['PORT']?.trim();
    final port = rawPort == null || rawPort.isEmpty
        ? 8080
        : int.tryParse(rawPort);
    if (port == null || port < 1 || port > 65535) {
      throw FormatException('PORT must be an integer between 1 and 65535.');
    }

    final rawDatabasePath = environment['SAQIA_DB']?.trim();
    final databasePath = rawDatabasePath == null || rawDatabasePath.isEmpty
        ? '../saqia_station_v2.db'
        : rawDatabasePath;

    return ServerConfig(
      databasePath: databasePath,
      jwtSecret: secret,
      bindAddress: address,
      port: port,
    );
  }
}
