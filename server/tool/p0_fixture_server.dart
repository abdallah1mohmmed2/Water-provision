// Test-only process: starts the real Shelf router against a disposable copy of
// an AppDatabase fixture. No test endpoints or production credentials are used.
import 'dart:convert';
import 'dart:io';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:sqlite3/sqlite3.dart';
import '../lib/server.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1 || !args.single.endsWith('/p0-server-fixture.db')) {
    throw ArgumentError('Expected disposable p0-server-fixture.db');
  }
  final db = sqlite3.open(args.single);
  // Local and server version tables have intentionally different schemas.
  for (final row in db.select(
    "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'sync_%'",
  )) {
    db.execute('DROP TRIGGER "${row['name']}"');
  }
  db.execute('DROP TABLE sync_entity_versions');
  const secret = 'p0-test-only-fixture-secret-32-bytes-minimum';
  final server = SaqiaServer(db, jwtSecret: secret);
  db.execute(
    """INSERT OR IGNORE INTO sync_entity_links
    (station_id,entity_type,global_id,local_id,created_at)
    SELECT 1,table_name,global_id,local_id,created_at FROM sync_global_identities
    WHERE table_name IN ('accounts','pumps','cashboxes','payment_methods','workers','partners')""",
  );
  db.execute('PRAGMA foreign_keys=ON');
  final listener = await io.serve(
    server.router(),
    InternetAddress.loopbackIPv4,
    0,
  );
  final token = JWT({
    'kind': 'admin',
    'userId': 1,
    'stationId': 1,
    'role': 'manager',
  }).sign(SecretKey(secret));
  stdout.writeln(jsonEncode({'port': listener.port, 'token': token}));
  await stdin.drain<void>();
  await listener.close(force: true);
  db.dispose();
}
