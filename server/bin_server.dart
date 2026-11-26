import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:sqlite3/sqlite3.dart';

import 'lib/server.dart';
import 'lib/server_config.dart';

Future<void> main() async {
  late final ServerConfig config;
  try {
    config = ServerConfig.fromEnvironment(Platform.environment);
  } on Object catch (error) {
    stderr.writeln('Shelf API startup refused: $error');
    exitCode = 78;
    return;
  }

  final db = sqlite3.open(config.databasePath);
  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(SaqiaServer(db, jwtSecret: config.jwtSecret).router());

  final server = await io.serve(handler, config.bindAddress, config.port);
  stdout.writeln(
    'Saqia API listening on '
    '${server.address.address}:${server.port}',
  );
}
