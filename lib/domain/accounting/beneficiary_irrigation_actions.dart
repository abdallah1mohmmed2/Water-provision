import 'package:sqflite/sqflite.dart';

import '../../data/local/database.dart';
import 'accounting_service.dart';

/// Edits/cancellation are limited to irrigations charged to the selected party.
/// A worker operating a beneficiary's pump must not acquire ownership of the
/// beneficiary's irrigation simply because worker_id references that worker.
class PartyIrrigationActions {
  final AppDatabase db;
  final int userId, partyId, irrigationId;
  final String partyType;

  PartyIrrigationActions(
    this.db, {
    required this.userId,
    required this.partyType,
    required this.partyId,
    required this.irrigationId,
  });

  static const _tables = <String, String>{
    'beneficiary': 'beneficiaries',
    'worker': 'workers',
    'partner': 'partners',
  };

  Future<Map<String, Object?>> _require(DatabaseExecutor tx) async {
    final table = _tables[partyType];
    if (table == null) throw ArgumentError('نوع صاحب السقاية غير صالح');
    final column = '${partyType}_id';
    final rows = await tx.rawQuery(
      "SELECT i.* FROM irrigations i "
      "JOIN $table owner ON owner.id=i.$column AND owner.station_id=i.station_id "
      "JOIN app_users u ON u.station_id=i.station_id "
      "WHERE i.id=? AND i.$column=? AND i.party_type=? "
      "AND i.status='posted' AND u.id=? AND u.active=1 "
      "AND u.role IN ('manager','accountant')",
      [irrigationId, partyId, partyType, userId],
    );
    if (rows.length != 1) {
      throw StateError('السقاية غير متاحة: تحقق من صلاحية المستخدم وصاحب السقاية والمحطة وحالتها');
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
        beforeChange: (tx) async { await _require(tx); },
      );

  Future<void> cancel(String reason) => AccountingService(db).cancelIrrigation(
        irrigationId,
        userId,
        reason,
        beforeChange: (tx) async { await _require(tx); },
      );
}

/// Preserve the existing beneficiary API for all callers and tests.
class BeneficiaryIrrigationActions extends PartyIrrigationActions {
  final int beneficiaryId;
  BeneficiaryIrrigationActions(
    super.db, {
    required super.userId,
    required this.beneficiaryId,
    required super.irrigationId,
  }) : super(partyType: 'beneficiary', partyId: beneficiaryId);
}
