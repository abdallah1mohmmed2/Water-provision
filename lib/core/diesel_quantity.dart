/// Display quantities without changing the precision of stored fuel movements.
class DieselQuantity {
  static String format(num value) {
    final text = value.toStringAsFixed(2);
    if (text == '-0.00') {
      return '0';
    }
    return text.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  static String balanceLabel(num value) {
    final quantity = format(value.abs());
    if (quantity == '0') {
      return 'رصيد الديزل متعادل';
    }
    return 'ديزل ${value < 0 ? 'عليه' : 'له'} $quantity لتر';
  }

  static double? parseInput(String text) {
    final normalized = text.trim();
    if (!RegExp(r'^\d+(?:\.\d{1,2})?$').hasMatch(normalized)) {
      return null;
    }
    final value = double.tryParse(normalized);
    return value != null && value.isFinite && value > 0 ? value : null;
  }
}
