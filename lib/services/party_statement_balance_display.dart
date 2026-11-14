/// Formats running balances in worker and partner statement printouts.
///
/// Irrigation information rows do not represent financial movements and have
/// no running balance. Do not confuse a missing balance with a genuine zero.
class PartyStatementBalanceDisplay {
  static bool hasBalance(Map<String, Object?> row) {
    if (const {
      'worker_irrigation_info',
      'partner_irrigation_info',
    }.contains(row['type'])) {
      return false;
    }
    final raw = row['balance'];
    return raw is num || (raw != null && num.tryParse('$raw') != null);
  }

  static String format(
    Map<String, Object?> row, {
    required String Function(num) money,
    String zeroLabel = 'صفر',
    String suffix = '',
  }) {
    if (!hasBalance(row)) return '—';
    final raw = row['balance'];
    final balance = raw is num ? raw : num.parse('$raw');
    if (balance > 0) return 'له ${money(balance)}$suffix';
    if (balance < 0) return 'عليه ${money(balance.abs())}$suffix';
    return zeroLabel;
  }
}
