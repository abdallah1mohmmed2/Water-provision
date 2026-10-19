/// حساب بداية الأسبوع والسنة المالية من الإعدادين `week_start` و`financial_year_start`.
class PeriodRanges {
  PeriodRanges._();

  static const Map<String, int> _weekdays = {
    'monday': DateTime.monday,
    'tuesday': DateTime.tuesday,
    'wednesday': DateTime.wednesday,
    'thursday': DateTime.thursday,
    'friday': DateTime.friday,
    'saturday': DateTime.saturday,
    'sunday': DateTime.sunday,
  };

  static bool validWeekStart(String v) => _weekdays.containsKey(v);

  /// صيغة MM-DD صالحة (يُقبل 02-29 لأن السنة المالية قد تبدأ في سنة كبيسة).
  static bool validFinancialYearStart(String v) {
    final m = RegExp(r'^(\d{2})-(\d{2})$').firstMatch(v.trim());
    if (m == null) return false;
    final mm = int.parse(m.group(1)!), dd = int.parse(m.group(2)!);
    if (mm < 1 || mm > 12 || dd < 1) return false;
    const days = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    return dd <= days[mm - 1];
  }

  /// بداية الأسبوع (منتصف الليل) الذي يقع فيه [date].
  static DateTime weekStart(DateTime date, String weekStartName) {
    final target = _weekdays[weekStartName] ?? DateTime.saturday;
    final day = DateTime(date.year, date.month, date.day);
    final back = (day.weekday - target + 7) % 7;
    return day.subtract(Duration(days: back));
  }

  /// بداية السنة المالية التي يقع فيها [date] حسب `MM-DD`.
  static DateTime financialYearStart(DateTime date, String mmdd) {
    final v = validFinancialYearStart(mmdd) ? mmdd.trim() : '01-01';
    final mm = int.parse(v.substring(0, 2)), dd = int.parse(v.substring(3, 5));
    DateTime build(int year) {
      // 29 فبراير في سنة غير كبيسة يُعامل 28 فبراير.
      final lastDay = DateTime(year, mm + 1, 0).day;
      return DateTime(year, mm, dd > lastDay ? lastDay : dd);
    }

    final day = DateTime(date.year, date.month, date.day);
    final thisYear = build(date.year);
    return day.isBefore(thisYear) ? build(date.year - 1) : thisYear;
  }
}
