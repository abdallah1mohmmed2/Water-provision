/// Quantity-only party diesel statement. This follows the same signed movement
/// contract as DieselDeliveryService.balanceOn; advances attached to an
/// irrigation are annotations and must never be counted twice.
class PartyDieselStatementEntry {
  final DateTime date;
  final String kind;
  final String notes;
  final bool reversal;
  final double delivered, consumed, balance;
  const PartyDieselStatementEntry({
    required this.date,
    required this.kind,
    required this.notes,
    required this.reversal,
    required this.delivered,
    required this.consumed,
    required this.balance,
  });
}

class PartyDieselStatement {
  final double opening, delivered, consumed, closing;
  final List<PartyDieselStatementEntry> entries;
  const PartyDieselStatement({
    required this.opening,
    required this.delivered,
    required this.consumed,
    required this.closing,
    required this.entries,
  });

  factory PartyDieselStatement.fromMovements({
    required double opening,
    required Iterable<Map<String, Object?>> movements,
    DateTime? from,
    DateTime? to,
  }) {
    final ordered = movements.toList()..sort((a, b) {
      final first = DateTime.tryParse('${a['date'] ?? ''}');
      final second = DateTime.tryParse('${b['date'] ?? ''}');
      final byDate = (first ?? DateTime(1900)).compareTo(second ?? DateTime(1900));
      if (byDate != 0) return byDate;
      return ((a['id'] as num?)?.toInt() ?? 0)
          .compareTo((b['id'] as num?)?.toInt() ?? 0);
    });
    final start = from == null ? null : DateTime(from.year, from.month, from.day);
    final endExclusive = to == null ? null : DateTime(to.year, to.month, to.day + 1);
    var carried = opening;
    var given = 0.0, used = 0.0;
    final entries = <PartyDieselStatementEntry>[];
    for (final row in ordered) {
      final date = DateTime.tryParse('${row['date'] ?? ''}');
      if (date == null) throw FormatException('Invalid diesel movement date');
      final kind = '${row['kind']}';
      final liters = (row['liters'] as num?)?.toDouble() ?? 0.0;
      final delivery = kind == 'delivery' ||
          (kind == 'receipt' && (row['party_receipt'] as num?)?.toInt() == 1) ||
          (kind == 'advance' && row['irrigation_id'] == null)
          ? liters : 0.0;
      final consumption = kind == 'consumption' ? liters : 0.0;
      if (delivery == 0 && consumption == 0) continue;
      if (start != null && date.isBefore(start)) {
        carried += delivery - consumption;
        continue;
      }
      if (endExclusive != null && !date.isBefore(endExclusive)) continue;
      given += delivery;
      used += consumption;
      entries.add(PartyDieselStatementEntry(
        date: date,
        kind: kind,
        notes: '${row['notes'] ?? ''}',
        reversal: row['reversal_of'] != null,
        delivered: delivery,
        consumed: consumption,
        balance: carried + given - used,
      ));
    }
    return PartyDieselStatement(
      opening: carried,
      delivered: given,
      consumed: used,
      closing: carried + given - used,
      entries: entries,
    );
  }
}
