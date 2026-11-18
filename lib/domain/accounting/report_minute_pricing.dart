/// Computes display-only beneficiary minute-rate totals.
/// Do not modify accounting_calculations.dart: the Shelf P1 parity test
/// requires that posted financial mathematics remain byte-for-byte unchanged.
class ReportMinutePricing {
  const ReportMinutePricing._();

  static int amountAtMinuteRate(int minutes, int minuteRate) {
    if (minutes <= 0 || minuteRate <= 0) return 0;
    return minutes * minuteRate;
  }
}
