/// Calculates the final statement balance without adding intermediate
/// running balances more than once.
class BeneficiaryStatementTotals {
  /// Individual statements end at their final row. Collective statements
  /// combine the final row of *each* beneficiary identified by a stable ID.
  ///
  /// Row order is the statement's display order: each beneficiary's last row
  /// contains that beneficiary's closing balance for the selected period.
  static num closingBalance(
    Iterable<Map<String, Object?>> rows, {
    required bool collective,
  }) {
    if (!collective) {
      num lastBalance = 0;
      for (final row in rows) {
        lastBalance = _amount(row['balance']);
      }
      return lastBalance;
    }

    final closingByBeneficiary = <int, num>{};
    for (final row in rows) {
      final value = row['beneficiary_id'];
      final id = value is num ? value.toInt() : int.tryParse('${value ?? ''}');
      if (id == null) {
        throw StateError(
          'تعذر تجميع كشف المستفيدين: صف دون معرّف مستفيد.',
        );
      }
      closingByBeneficiary[id] = _amount(row['balance']);
    }
    return closingByBeneficiary.values.fold<num>(
      0,
      (total, closing) => total + closing,
    );
  }

  static num _amount(Object? value) =>
      value is num ? value : num.tryParse('${value ?? ''}') ?? 0;
}
