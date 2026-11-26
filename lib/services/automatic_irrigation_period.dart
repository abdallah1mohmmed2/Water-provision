import '../core/app_clock.dart';
import '../core/period_ranges.dart';
import '../data/repositories/repositories.dart';

/// A read-only default filter. It never alters irrigation records or replaces
/// a date range explicitly chosen by the user.
class IrrigationPeriodSelection {
  const IrrigationPeriodSelection(this.from, this.to, this.key);

  final DateTime from;
  final DateTime to;
  final String key;

  String get label => switch (key) {
    'today' => 'اليوم',
    'week' => 'هذا الأسبوع',
    _ => 'هذا الشهر',
  };
}

class AutomaticIrrigationPeriod {
  AutomaticIrrigationPeriod._();

  /// Today -> current configured week -> current calendar month.
  /// If none has irrigation, keep the month so the range remains predictable.
  static Future<IrrigationPeriodSelection> select({
    required DateTime now,
    required String weekStart,
    required Future<bool> Function(DateTime from, DateTime to) hasIrrigation,
  }) async {
    final today = DateTime(now.year, now.month, now.day);
    if (await hasIrrigation(today, today)) {
      return IrrigationPeriodSelection(today, today, 'today');
    }

    final week = PeriodRanges.weekStart(today, weekStart);
    if (await hasIrrigation(week, today)) {
      return IrrigationPeriodSelection(week, today, 'week');
    }

    final month = DateTime(today.year, today.month, 1);
    // Check for older irrigations for a consistent, testable fallback
    // even though the resulting month is chosen when it is also empty.
    await hasIrrigation(month, today);
    return IrrigationPeriodSelection(month, today, 'month');
  }

  /// Uses the same local, non-cancelled irrigation/date rules as the
  /// repository's list. Only one matching row is queried per candidate range.
  static Future<IrrigationPeriodSelection> forRepository(
    StationRepository repository, {
    String? systemType,
    int? beneficiaryId,
    int? workerId,
    int? partnerId,
    DateTime? now,
  }) async {
    final config = await repository.settings();
    final current = config['system_type'] ?? 'diesel';
    final selectedSystem = systemType == null || systemType == 'current'
        ? current
        : systemType;
    return select(
      now: now ?? AppClock.now(),
      weekStart: config['week_start'] ?? 'saturday',
      hasIrrigation: (from, to) async {
        final filters = <String>[
          "i.status!='cancelled'",
          "COALESCE(date(i.date),date(i.start_datetime))>=date(?)",
          "COALESCE(date(i.date),date(i.start_datetime))<=date(?)",
        ];
        final parameters = <Object?>[
          from.toIso8601String(),
          to.toIso8601String(),
        ];
        if (selectedSystem != 'all') {
          filters.add('i.system_type=?');
          parameters.add(selectedSystem);
        }
        if (beneficiaryId != null) {
          filters.add('i.beneficiary_id=?');
          parameters.add(beneficiaryId);
        }
        if (workerId != null) {
          filters.add('i.worker_id=?');
          parameters.add(workerId);
        }
        if (partnerId != null) {
          filters.add('i.partner_id=?');
          parameters.add(partnerId);
        }
        final rows = await repository.db.rawQuery(
          'SELECT 1 FROM irrigations i WHERE ${filters.join(' AND ')} LIMIT 1',
          parameters,
        );
        return rows.isNotEmpty;
      },
    );
  }
}
