import 'package:sqflite/sqflite.dart';

import '../../core/app_clock.dart';
import '../../data/local/database.dart';

/// A person's incoming fuel is quantity-only. Irrigation advances are loan
/// annotations; counting them again would erase the person's outstanding debt.
class DieselDeliveryService {
  final AppDatabase db;
  DieselDeliveryService(this.db);
  static const tables = {
    'beneficiary': 'beneficiaries',
    'worker': 'workers',
    'partner': 'partners',
  };
  Future<void> authorize(DatabaseExecutor tx, int station, int user) async {
    final rows = await tx.rawQuery(
      "SELECT 1 FROM app_users WHERE id=? AND station_id=? AND active=1 AND role IN ('manager','accountant')",
      [user, station],
    );
    final settings = await tx.rawQuery(
      "SELECT value FROM settings WHERE key='system_type'",
    );
    if (rows.isEmpty ||
        settings.isEmpty ||
        settings.first['value'] != 'diesel') {
      throw StateError(
        'تسجيل تسليم الديزل متاح للمدير والمحاسب في منظومة الديزل فقط',
      );
    }
  }

  Future<double> balance(int station, String type, int id) async =>
      balanceOn(await db.db, station, type, id);
  static Future<double> balanceOn(
    DatabaseExecutor tx,
    int station,
    String type,
    int id,
  ) async {
    final table = tables[type];
    if (table == null) {
      throw ArgumentError('نوع الطرف غير صالح');
    }
    final people = await tx.rawQuery(
      'SELECT * FROM $table WHERE id=? AND station_id=?',
      [id, station],
    );
    if (people.isEmpty) {
      throw StateError('الطرف لا يتبع المحطة');
    }
    final p = people.first;
    final opening = type == 'beneficiary'
        ? ((p['opening_diesel_liters'] as num?)?.toDouble() ?? 0) +
              ((p['carried_diesel_liters'] as num?)?.toDouble() ?? 0)
        : 0.0;
    final column = '${type}_id';
    final rows = await tx.rawQuery(
      '''SELECT COALESCE(SUM(CASE
      WHEN (dm.kind='delivery' OR (dm.kind='receipt' AND dm.party_receipt=1)) THEN dm.liters
      WHEN dm.kind='advance' AND dm.irrigation_id IS NULL THEN dm.liters
      WHEN dm.kind='consumption' THEN -dm.liters ELSE 0 END),0) balance
      FROM diesel_movements dm LEFT JOIN irrigations i ON i.id=dm.irrigation_id
      WHERE dm.station_id=? AND (dm.$column=? OR (dm.$column IS NULL AND i.$column=?))''',
      [station, id, id],
    );
    return opening + (rows.first['balance'] as num).toDouble();
  }

  Future<int> receive({
    required int station,
    required int user,
    required String type,
    required int person,
    required double liters,
    required DateTime date,
    required String requestId,
    String? notes,
  }) async {
    if (!liters.isFinite ||
        liters <= 0 ||
        requestId.trim().isEmpty ||
        !tables.containsKey(type)) {
      throw ArgumentError('حدد الطرف وكمية لترات موجبة وصالحة');
    }
    return db.transaction((tx) async {
      await authorize(tx, station, user);
      final party = await tx.rawQuery(
        'SELECT id FROM ${tables[type]} WHERE id=? AND station_id=?',
        [person, station],
      );
      if (party.isEmpty) {
        throw StateError('الطرف لا يتبع المحطة');
      }
      final closed = await tx.rawQuery(
        "SELECT 1 FROM period_closures WHERE station_id=? AND status='locked' AND period_start<=? AND COALESCE(period_end_exclusive,period_end)>?",
        [station, date.toIso8601String(), date.toIso8601String()],
      );
      if (closed.isNotEmpty) {
        throw StateError('الفترة مقفلة');
      }
      final id = await tx.insert('diesel_movements', {
        'station_id': station,
        '${type}_id': person,
        'kind': 'receipt',
        'party_receipt': 1,
        'liters': liters,
        'unit_price': 0,
        'amount': 0,
        'date': date.toIso8601String(),
        'notes': notes,
        'created_by': user,
        'request_id': requestId,
      });
      await db.auditTx(
        tx,
        userId: user,
        operation: 'receive_party_diesel',
        table: 'diesel_movements',
        recordId: id,
        newValues: {'liters': liters, 'type': type, 'person': person},
      );
      return id;
    }, captureSyncTables: const {'diesel_movements'});
  }

  Future<void> cancelOn(
    Transaction tx,
    Map<String, Object?> row,
    int user,
    String reason,
  ) async {
    final station = row['station_id'] as int;
    await authorize(tx, station, user);
    if (row['reversal_of'] != null || (row['liters'] as num) <= 0) {
      throw StateError('لا يمكن إلغاء حركة عكسية');
    }
    final previous = await tx.rawQuery(
      'SELECT id FROM diesel_movements WHERE reversal_of=?',
      [row['id']],
    );
    if (previous.isNotEmpty) {
      throw StateError('تم إلغاء التسليم من قبل');
    }
    await tx.insert('diesel_movements', {
      'station_id': station,
      'beneficiary_id': row['beneficiary_id'],
      'worker_id': row['worker_id'],
      'partner_id': row['partner_id'],
      'kind': 'receipt',
      'party_receipt': 1,
      'liters': -(row['liters'] as num).toDouble(),
      'unit_price': 0,
      'amount': 0,
      'date': AppClock.now().toIso8601String(),
      'notes': reason,
      'created_by': user,
      'reversal_of': row['id'],
    });
    await db.auditTx(
      tx,
      userId: user,
      operation: 'cancel',
      table: 'diesel_movements',
      recordId: row['id'] as int,
      oldValues: row,
      reason: reason,
    );
  }
}
