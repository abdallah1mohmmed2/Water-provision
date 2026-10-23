import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';
import '../domain/accounting/accounting_service.dart';

class BackupService {
  final AccountingService accounting;
  BackupService([AccountingService? a]) : accounting = a ?? AccountingService();

  Future<String> databasePath() async {
    final dir = await getDatabasesPath();
    return p.join(dir, 'saqia_station_v2.db');
  }

  Future<File> createDatabaseBackup() async {
    final source = File(await databasePath());
    if (!await source.exists()) throw StateError('ملف قاعدة البيانات غير موجود');

    // اقرأ هوية المنظومة قبل إغلاق الاتصال؛ القراءة بعد close كانت تجعل إنشاء
    // النسخة يفشل قبل الوصول إلى التحقق الفعلي.
    final typeRows = await accounting.database.query("SELECT value FROM settings WHERE key='system_type' LIMIT 1");
    final currentType = typeRows.isEmpty ? 'diesel' : '${typeRows.first['value']}';

    // تثبيت ملف SQLite قبل نسخه، ثم إغلاق الاتصال حتى لا ننسخ حالة WAL ناقصة.
    await accounting.database.query('PRAGMA wal_checkpoint(TRUNCATE)');
    await accounting.database.close();

    final dir = await getTemporaryDirectory();
    final name = 'نسخة_ساقية_${DateTime.now().millisecondsSinceEpoch}.db';
    final target = File(p.join(dir.path, name));
    try {
      await source.copy(target.path);
      final check = await validateDatabaseFile(target.path, expectedSystemType: currentType);
      if (check['valid'] != true) {
        throw StateError('${check['error'] ?? 'النسخة الاحتياطية غير صالحة'}');
      }
      // إعادة فتح الاتصال صراحةً قبل كتابة سجل النسخ.
      await accounting.database.db;
      await accounting.database.insert('backup_records', {
        'path': target.path,
        'created_at': DateTime.now().toIso8601String(),
        'status': 'created',
        'notes': 'نسخة SQLite مكتملة ومتحقق منها',
      });
      return target;
    } catch (_) {
      // لا نترك الخدمة في حالة اتصال مغلق إذا فشل النسخ.
      await accounting.database.db;
      rethrow;
    }
  }

  Future<String?> saveBackupToLocation() async {
    final file = await createDatabaseBackup();
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'حفظ النسخة الاحتياطية',
      fileName: p.basename(file.path),
      type: FileType.custom,
      allowedExtensions: ['db'],
    );
    if (path == null) return null;
    await File(file.path).copy(path);
    return path;
  }

  Future<void> createAndShare() async {
    final file = await createDatabaseBackup();
    await Share.shareXFiles([
      XFile(
        file.path,
        name: p.basename(file.path),
        mimeType: 'application/octet-stream',
      ),
    ], text: 'نسخة احتياطية لقاعدة بيانات ساقية');
  }

  Future<Uint8List> buildPortableJsonBackup() async =>
      Uint8List.fromList(utf8.encode(await accounting.exportStateJson()));

  Future<Map<String, dynamic>> validateDatabaseFile(String path, {String? expectedSystemType}) async {
    try {
      final f = File(path);
      if (!await f.exists()) {
        return {'valid': false, 'error': 'الملف غير موجود'};
      }
      final bytes = await f.openRead(0, 16).first;
      final header = utf8.decode(bytes, allowMalformed: true);
      if (!header.startsWith('SQLite format 3')) {
        return {'valid': false, 'error': 'الملف ليس قاعدة SQLite صحيحة'};
      }
      final db = await openReadOnlyDatabase(path);
      final required = [
        'stations',
        'pumps',
        'beneficiaries',
        'irrigations',
        'payments',
        'cashboxes',
        'journal_entries',
        'journal_lines',
        'settings',
      ];
      final missing = <String>[];
      for (final t in required) {
        final r = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [t],
        );
        if (r.isEmpty) missing.add(t);
      }
      if (missing.isNotEmpty) {
        await db.close();
        return {'valid': false, 'error': 'النسخة ناقصة: ${missing.join(', ')}'};
      }
      final settingRows = await db.query('settings', where: 'key=?', whereArgs: ['system_type'], limit: 1);
      final backupType = settingRows.isEmpty ? null : '${settingRows.first['value']}';
      const allowed = {'diesel', 'solar', 'equivalent_hybrid'};
      if (backupType == null || !allowed.contains(backupType)) {
        await db.close();
        return {'valid': false, 'error': 'النسخة لا تحتوي نوع منظومة صالحاً'};
      }
      if (expectedSystemType != null && backupType != expectedSystemType) {
        await db.close();
        return {'valid': false, 'error': 'النسخة تخص منظومة $backupType بينما هذه المحطة تعمل على $expectedSystemType'};
      }
      final integrity = await db.rawQuery('PRAGMA integrity_check');
      if (integrity.isEmpty || integrity.first.values.first != 'ok') {
        await db.close();
        return {'valid': false, 'error': 'قاعدة SQLite داخل النسخة غير سليمة'};
      }
      final foreignKeyIssues = await db.rawQuery('PRAGMA foreign_key_check');
      if (foreignKeyIssues.isNotEmpty) {
        await db.close();
        return {'valid': false, 'error': 'النسخة تحتوي مراجع غير مرتبطة بين الجداول'};
      }
      await db.close();
      return {'valid': true, 'system_type': backupType};
    } catch (e) {
      return {'valid': false, 'error': 'تعذر فحص قاعدة البيانات: $e'};
    }
  }

  Future<Map<String, dynamic>> pickAndRestoreDatabase() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['db', 'sqlite'],
      withData: false,
    );
    if (result == null || result.files.single.path == null) {
      return {'restored': false, 'cancelled': true};
    }
    final source = result.files.single.path!;
    return restoreDatabaseFromFile(source);
  }

  Future<Map<String, dynamic>> restoreDatabaseFromFile(
    String source, {
    Directory? rollbackDirectory,
  }) async {
    final currentSettings = await accounting.database.query(
      "SELECT value FROM settings WHERE key='system_type' LIMIT 1",
    );
    final expectedSystemType = currentSettings.isEmpty
        ? 'diesel'
        : '${currentSettings.first['value']}';
    final check = await validateDatabaseFile(
      source,
      expectedSystemType: expectedSystemType,
    );
    if (check['valid'] != true) return {'restored': false, ...check};
    final restoredSystemType = expectedSystemType;

    final dbPath = await databasePath();
    final current = File(dbPath);
    final wal = File('$dbPath-wal');
    final shm = File('$dbPath-shm');
    final dir = rollbackDirectory ?? await getTemporaryDirectory();
    final rollback = File(
      p.join(
        dir.path,
        'ساقية_قبل_الاستعادة_${DateTime.now().millisecondsSinceEpoch}.db',
      ),
    );
    // أنشئ نقطة الرجوع بعد تثبيت WAL وإغلاق الاتصال، لا قبل ذلك؛ وإلا قد تكون
    // النسخة السابقة ناقصة عند استخدام وضع WAL.
    await accounting.database.query('PRAGMA wal_checkpoint(TRUNCATE)');
    await accounting.database.close();
    if (await current.exists()) await current.copy(rollback.path);

    try {
      // لا يجوز أن تختلط النسخة الجديدة مع WAL/SHM قديمين من القاعدة السابقة.
      // SQLite يعيد إنشاءهما عند الحاجة بعد فتح النسخة الجديدة.
      if (await wal.exists()) await wal.delete();
      if (await shm.exists()) await shm.delete();
      await File(source).copy(dbPath);

      // فتح قاعدة النسخة فعليًا قبل إعلان النجاح.
      await accounting.database.db;
      await accounting.database.query('PRAGMA wal_checkpoint(TRUNCATE)');
      await accounting.database.close();
      // افحص الملف وهو مغلق؛ فتحه للقراءة فقط ثم إغلاقه أثناء بقاء اتصال
      // التطبيق مفتوحًا قد يغلق مقبض SQLite الذي يحتفظ به AppDatabase.
      final installedCheck = await validateDatabaseFile(dbPath, expectedSystemType: restoredSystemType);
      if (installedCheck['valid'] != true) {
        throw StateError('${installedCheck['error'] ?? 'النسخة المستعادة غير صالحة'}');
      }
      await accounting.database.db;
      await accounting.database.insert('backup_records', {
        'path': source,
        'created_at': DateTime.now().toIso8601String(),
        'status': 'restored',
        'notes': 'تم استعادة قاعدة SQLite والتحقق منها؛ نوع المنظومة: $restoredSystemType',
      });
      return {'restored': true, 'path': source, 'system_type': restoredSystemType};
    } catch (e) {
      try {
        await accounting.database.close();
        if (await wal.exists()) await wal.delete();
        if (await shm.exists()) await shm.delete();
        if (await rollback.exists()) await rollback.copy(dbPath);
        final rollbackWal = File('${rollback.path}-wal');
        final rollbackShm = File('${rollback.path}-shm');
        if (await rollbackWal.exists()) await rollbackWal.copy('$dbPath-wal');
        if (await rollbackShm.exists()) await rollbackShm.copy('$dbPath-shm');
        await accounting.database.db;
      } catch (_) {}
      return {
        'restored': false,
        'error': 'فشل الاسترجاع وتمت استعادة قاعدة البيانات السابقة: $e',
      };
    }
  }

  Future<List<Map<String, Object?>>> history() => accounting.database.query(
    'SELECT * FROM backup_records ORDER BY created_at DESC',
  );

  Future<void> restorePortableJson(Uint8List bytes) async {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw StateError('ملف النسخة ليس JSON صالحًا');
    }
    const tables = AccountingService.portableTables;
    const optional = AccountingService.optionalPortableTables;
    // الجداول الأساسية إلزامية. الجداول المضافة لاحقًا اختيارية في الملفات القديمة،
    // لكن إن وُجد مفتاحها يجب أن يكون قائمة.
    for (final table in tables) {
      final v = decoded[table];
      if (v == null && optional.contains(table)) continue;
      if (v is! List) throw StateError('النسخة ناقصة: $table');
    }
    await accounting.database.transaction((tx) async {
      // ملاحظة: PRAGMA foreign_keys لا أثر له داخل معاملة في SQLite، لذا نعتمد
      // على ترتيب الحذف (عكسي) والإدراج (أمامي) المتوافق مع المفاتيح الأجنبية.
      for (final table in tables.reversed) {
        // ملف قديم بلا period_closures: نُبقي الفترات المغلقة الحالية بدل فتحها.
        if (table == 'period_closures' && decoded[table] == null) continue;
        await tx.delete(table);
      }
      for (final table in tables) {
        final rows = decoded[table];
        if (rows == null) continue;
        for (final row in (rows as List)) {
          if (row is! Map) throw StateError('بيانات غير صالحة في $table');
          await tx.insert(table, Map<String, Object?>.from(row));
        }
      }
      // ملفات JSON القديمة لم تكن تحفظ محطة قيد اليومية. في تثبيت أحادي المحطة
      // يكون الإسناد حتميًا؛ أما تعدد المحطات فيبقى غير مصنف ويمنع الإقفال الآمن.
      final stations = await tx.rawQuery('SELECT id FROM stations ORDER BY id');
      if (stations.length == 1) {
        await tx.rawUpdate('UPDATE journal_entries SET station_id=? WHERE station_id IS NULL', [stations.first['id']]);
      }
    });
  }

  Future<Map<String, dynamic>> validatePortableJson(Uint8List bytes) async {
    try {
      final x = jsonDecode(utf8.decode(bytes));
      if (x is! Map) return {'valid': false, 'error': 'ملف النسخة ليس JSON صالحًا'};
      for (final k in AccountingService.portableTables) {
        final v = x[k];
        if (v == null && AccountingService.optionalPortableTables.contains(k)) {
          continue;
        }
        if (v is! List) return {'valid': false, 'error': 'النسخة ناقصة: $k'};
      }
      final missingOptional = [
        for (final k in AccountingService.optionalPortableTables)
          if (x[k] == null) k,
      ];
      return {
        'valid': true,
        'tables': x.keys.where((k) => !'$k'.startsWith('_')).length,
        'missing_optional': missingOptional,
      };
    } catch (e) {
      return {'valid': false, 'error': 'ملف النسخة غير صالح: $e'};
    }
  }
}
