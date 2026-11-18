import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/domain/accounting/party_diesel_statement.dart';

void main() {
  Map<String, Object?> movement(int id, String date, String kind,
      double liters, {int? partyReceipt, int? irrigationId, int? reversalOf}) =>
      <String, Object?>{
        'id': id,
        'date': date,
        'kind': kind,
        'liters': liters,
        'party_receipt': partyReceipt,
        'irrigation_id': irrigationId,
        'reversal_of': reversalOf,
      };

  test('delivery, receipt, consumption and signed reversals balance exactly', () {
    final report = PartyDieselStatement.fromMovements(
      opening: 3,
      movements: [
        movement(2, '2026-01-01T11:00:00', 'consumption', 6, irrigationId: 12),
        movement(1, '2026-01-01T08:00:00', 'delivery', 5),
        movement(3, '2026-01-01T12:00:00', 'consumption', -2, reversalOf: 2),
        movement(4, '2026-01-01T13:00:00', 'receipt', 3, partyReceipt: 1),
        movement(5, '2026-01-01T14:00:00', 'receipt', 9, partyReceipt: 0),
        movement(6, '2026-01-01T15:00:00', 'advance', 4, irrigationId: 12),
      ],
    );
    expect(report.opening, 3);
    expect(report.delivered, 8);
    expect(report.consumed, 4);
    expect(report.closing, 7);
    expect(report.entries.length, 4);
    expect(report.entries.last.balance, 7);
    expect(report.entries[2].reversal, isTrue);
    expect(report.entries[2].consumed, -2);
  });

  test('date filters carry earlier movement without double counting it', () {
    final report = PartyDieselStatement.fromMovements(
      opening: 1,
      movements: [
        movement(1, '2026-01-01T12:00:00', 'delivery', 5),
        movement(2, '2026-01-02T12:00:00', 'consumption', 3),
        movement(3, '2026-01-03T12:00:00', 'receipt', 2, partyReceipt: 1),
      ],
      from: DateTime(2026, 1, 2),
      to: DateTime(2026, 1, 2),
    );
    expect(report.opening, 6);
    expect(report.delivered, 0);
    expect(report.consumed, 3);
    expect(report.closing, 3);
    expect(report.entries.length, 1);
  });

  test('standalone advance and negative delivery reversal do not duplicate fuel', () {
    final report = PartyDieselStatement.fromMovements(
      opening: 0,
      movements: [
        movement(1, '2026-01-01T08:00:00', 'advance', 4),
        movement(2, '2026-01-01T09:00:00', 'delivery', 5),
        movement(3, '2026-01-01T10:00:00', 'delivery', -5, reversalOf: 2),
        movement(4, '2026-01-01T11:00:00', 'consumption', 6),
        movement(5, '2026-01-01T12:00:00', 'consumption', -6, reversalOf: 4),
      ],
    );
    expect(report.delivered, 4);
    expect(report.consumed, 0);
    expect(report.closing, 4);
  });
}
