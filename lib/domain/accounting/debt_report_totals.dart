/// Aggregates party balances in debt reports.
///
/// The unified repository report normalizes all party balances:
/// positive = the person owes the station (عليه), negative = the station
/// owes the person (له). Net totals are for reporting only and never settle
/// or offset balances on the parties' individual accounts.
class DebtReportTotals {
  final num totalAlayh;
  final num totalLah;

  const DebtReportTotals({
    required this.totalAlayh,
    required this.totalLah,
  });

  factory DebtReportTotals.fromRows(Iterable<Map<String, Object?>> rows) {
    num alayh = 0;
    num lah = 0;
    for (final row in rows) {
      final raw = row['balance'];
      final value = raw is num ? raw : num.tryParse('${raw ?? ''}') ?? 0;
      if (value > 0) {
        alayh += value;
      } else if (value < 0) {
        lah += value.abs();
      }
    }
    return DebtReportTotals(totalAlayh: alayh, totalLah: lah);
  }

  /// Positive means net 'عليه'; negative means net 'له'.
  num get net => totalAlayh - totalLah;

  String netLabel(String Function(num) formatAmount) {
    if (net > 0) return 'عليه ${formatAmount(net)}';
    if (net < 0) return 'له ${formatAmount(net.abs())}';
    return 'متوازن (${formatAmount(0)})';
  }
}
