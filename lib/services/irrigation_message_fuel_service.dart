import '../core/diesel_quantity.dart';
import '../data/repositories/repositories.dart';
import '../domain/maintenance/diesel_delivery_service.dart';

/// A read-only view of the saved irrigation and its owner's current fuel ledger.
class IrrigationMessageFuelService {
  final StationRepository repo;
  IrrigationMessageFuelService(this.repo);

  Future<Map<String, Object?>> forIrrigation(int id) async {
    final station = await repo.accounting.currentStationId();
    return repo.db.transaction((tx) async {
      final rows = await tx.query('irrigations', where: 'id=? AND station_id=?', whereArgs: [id, station]);
      if (rows.isEmpty) {
        throw StateError('السقاية لا تتبع المحطة الحالية');
      }
      final row = rows.single;
      if (row['system_type'] != 'diesel' || row['status'] != 'posted') {
        return <String, Object?>{};
      }
      final type = '${row['party_type']}';
      if (!DieselDeliveryService.tables.containsKey(type)) {
        throw StateError('صاحب السقاية غير صالح');
      }
      final person = (row['${type}_id'] as num?)?.toInt();
      if (person == null) {
        throw StateError('صاحب السقاية غير محدد');
      }
      final movements = await tx.rawQuery(
        "SELECT COALESCE(SUM(liters),0) liters FROM diesel_movements WHERE station_id=? AND irrigation_id=? AND kind='consumption'",
        [station, id],
      );
      final consumed = (movements.single['liters'] as num).toDouble();
      final balance = await DieselDeliveryService.balanceOn(tx, station, type, person);
      final quantity = DieselQuantity.format(balance.abs());
      final label = quantity == '0' ? 'متوازن (0 لتر)'
          : '${balance < 0 ? 'عليه' : 'له'} $quantity لتر';
      return <String, Object?>{
        'الديزل المستهلك': '${DieselQuantity.format(consumed)} لتر',
        'رصيد الديزل المتبقي': label,
        'ديزل له': '${DieselQuantity.format(balance > 0 ? balance : 0)} لتر',
        'ديزل عليه': '${DieselQuantity.format(balance < 0 ? -balance : 0)} لتر',
      };
    }, captureSync: false);
  }
}
