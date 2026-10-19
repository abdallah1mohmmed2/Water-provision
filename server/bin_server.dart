import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:sqlite3/sqlite3.dart';
import 'lib/server.dart';

Future<void> main() async {
  final path=Platform.environment['SAQIA_DB'] ?? '../saqia_station_v2.db';
  final secret=Platform.environment['SAQIA_JWT_SECRET'] ?? 'CHANGE_THIS_IN_PRODUCTION';
  final db=sqlite3.open(path);
  final app=Pipeline().addMiddleware(logRequests()).addHandler(SaqiaServer(db,jwtSecret:secret).router());
  final server=await io.serve(app,InternetAddress.anyIPv4,int.tryParse(Platform.environment['PORT']??'8080')??8080);
  print('Saqia API listening on ${server.address.host}:${server.port}');
}
