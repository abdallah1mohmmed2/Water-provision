/// Optional per-owner fuel rate. Null inherits the station setting.
class PartyDieselRate {
  static double? validate(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is! num || !value.isFinite || value <= 0 ||
        (value * 100 - (value * 100).round()).abs() > 0.0000001) {
      throw ArgumentError('معدل الديزل يجب أن يكون موجبًا بمنزلتين عشريتين كحد أقصى، مثل 4.65');
    }
    return value.toDouble();
  }

  static double? parseOptional(String text) {
    if (text.trim().isEmpty) {
      return null;
    }
    final value = double.tryParse(text.trim());
    if (value == null) {
      throw ArgumentError('معدل استهلاك الديزل غير صالح');
    }
    return validate(value);
  }

  static double resolve(Object? personal, double stationRate) =>
      validate(personal) ?? stationRate;
}
