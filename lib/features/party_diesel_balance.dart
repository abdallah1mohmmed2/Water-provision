import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/diesel_quantity.dart';
import '../data/repositories/repositories.dart';
import '../domain/maintenance/diesel_delivery_service.dart';

/// Read the established signed liters ledger; never post a balance or a journal.
class PartyDieselBalance extends StatelessWidget {
  final num balance;
  const PartyDieselBalance(this.balance, {super.key});

  static Future<List<Map<String, Object?>>> loadRows(
    StationRepository repo, String type, List<Map<String, Object?>> rows,
  ) async {
    if ((await repo.settings())['system_type'] != 'diesel') {
      return rows;
    }
    final station = await repo.accounting.currentStationId();
    final service = DieselDeliveryService(repo.db);
    final result = <Map<String, Object?>>[];
    for (final row in rows) {
      result.add({...row, 'party_diesel_balance':
        await service.balance(station, type, row['id'] as int)});
    }
    return result;
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(DieselQuantity.balanceLabel(balance),
      style: TextStyle(fontWeight: FontWeight.w900,
        color: balance < 0 ? SaqiaTheme.reportNegative : SaqiaTheme.reportPositive)),
  );
}
