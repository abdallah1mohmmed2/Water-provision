import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Read-only schema inspection utility used before central database migration.
///
/// Usage:
///   dart run bin/inspect_schema.dart /path/to/saqia_station_v2.db
///
/// It emits schema metadata only; it never exports business rows or modifies
/// the inspected database.
void main(List<String> arguments) {
  if (arguments.length != 1 || arguments.single.trim().isEmpty) {
    stderr.writeln(
      'Usage: dart run bin/inspect_schema.dart <sqlite-database-path>',
    );
    exitCode = 64;
    return;
  }

  final file = File(arguments.single);
  if (!file.existsSync()) {
    stderr.writeln('Database file does not exist: ${file.path}');
    exitCode = 66;
    return;
  }

  Database? database;
  try {
    database = sqlite3.open(file.path, mode: OpenMode.readOnly);
    final result = _inspect(database);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
  } on Object catch (error) {
    stderr.writeln('Schema inspection failed: $error');
    exitCode = 1;
  } finally {
    database?.dispose();
  }
}

Map<String, Object?> _inspect(Database database) {
  final tables = database.select(
    """SELECT name, sql FROM sqlite_master
       WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
       ORDER BY name""",
  );

  final tableMetadata = <Map<String, Object?>>[];
  for (final table in tables) {
    final name = table['name'] as String;
    final identifier = _quoteIdentifier(name);
    final columns = database.select('PRAGMA table_info($identifier)');
    final foreignKeys = database.select('PRAGMA foreign_key_list($identifier)');
    final indexes = database.select(
      """SELECT name, sql FROM sqlite_master
         WHERE type = 'index' AND tbl_name = ? AND name NOT LIKE 'sqlite_%'
         ORDER BY name""",
      [name],
    );
    final triggers = database.select(
      """SELECT name, sql FROM sqlite_master
         WHERE type = 'trigger' AND tbl_name = ?
         ORDER BY name""",
      [name],
    );

    tableMetadata.add({
      'name': name,
      'create_sql': table['sql'],
      'columns': _rows(columns),
      'foreign_keys': _rows(foreignKeys),
      'indexes': _rows(indexes),
      'triggers': _rows(triggers),
    });
  }

  final userVersion = database.select('PRAGMA user_version').first['user_version'];
  final foreignKeysEnabled =
      database.select('PRAGMA foreign_keys').first['foreign_keys'];

  return {
    'format_version': 1,
    'generated_at_utc': DateTime.now().toUtc().toIso8601String(),
    'sqlite_user_version': userVersion,
    'foreign_keys_enabled_for_inspection_connection': foreignKeysEnabled,
    'table_count': tableMetadata.length,
    'tables': tableMetadata,
  };
}

List<Map<String, Object?>> _rows(ResultSet result) => result
    .map(
      (row) => {
        for (final column in result.columnNames) column: row[column],
      },
    )
    .toList();

String _quoteIdentifier(String value) => '"${value.replaceAll('"', '""')}"';
