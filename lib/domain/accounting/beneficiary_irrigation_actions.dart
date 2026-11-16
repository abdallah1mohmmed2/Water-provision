import 'package:sqflite/sqflite.dart';

import '../../data/local/database.dart';
import 'accounting_service.dart';

/// Scope is rechecked inside the existing posting/reversal transaction.
class BeneficiaryIrrigationActions {
  final AppDatabase db;
  final int userId, beneficiaryId, irrigationId;
  BeneficiaryIrrigationActions(
    this.db, {
    required this.userId,
    required this.beneficiaryId,
    required this.irrigationId,
  });
  Future<Map<String, Object?>> _require(DatabaseExecutor tx) async {
    final rows = await tx.rawQuery(
      "SELECT i.* FROM irrigations i JOIN beneficiaries b ON b.id=i.beneficiary_id AND b.station_id=i.station_id JOIN app_users u ON u.station_id=i.station_id WHERE i.id=? AND i.beneficiary_id=? AND i.party_type='beneficiary' AND i.status='posted' AND u.id=? AND u.active=1 AND u.role IN ('manager','accountant')",
      [irrigationId, beneficiaryId, userId],
    );
    if (rows.length != 1) {
      throw StateError(
        'السقاية غير متاحة للتعديل: تحقق من صلاحية المستخدم والمستفيد وحالة السقاية',
      );
    }
    return rows.single;
  }

  Future<Map<String, Object?>> record() async => _require(await db.db);
  Future<int> edit(DateTime start, DateTime end) =>
      AccountingService(db).updateIrrigationBasic(
        id: irrigationId,
        start: start,
        end: end,
        userId: userId,
        beforeChange: (tx) async {
          await _require(tx);
        },
      );
  Future<void> cancel(String reason) => AccountingService(db).cancelIrrigation(
    irrigationId,
    userId,
    reason,
    beforeChange: (tx) async {
      await _require(tx);
    },
  );
}
