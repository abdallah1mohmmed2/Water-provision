import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/services/automatic_irrigation_period.dart';

void main() {
  final date = DateTime(2026, 11, 14);

  test('selects today if there is an irrigation today', () async {
    final queries = <String>[];
    final result = await AutomaticIrrigationPeriod.select(
      now: date,
      weekStart: 'saturday',
      hasIrrigation: (a, b) async {
        queries.add('${a.day}-${b.day}');
        return true;
      },
    );
    expect(result.key, 'today');
    expect(result.from, date);
    expect(result.to, date);
    expect(queries, ['14-14']);
  });

  test('selects configured week if today has no irrigations', () async {
    final queried = <DateTime>[];
    final result = await AutomaticIrrigationPeriod.select(
      now: DateTime(2026, 11, 18, 15, 30),
      weekStart: 'saturday',
      hasIrrigation: (a, b) async {
        queried.add(a);
        return a.day == 14;
      },
    );
    expect(result.key, 'week');
    expect(result.from, DateTime(2026, 11, 14));
    expect(result.to, DateTime(2026, 11, 18));
    expect(queried.length, 2);
  });

  test('selects month when today and week have no irrigations', () async {
    final result = await AutomaticIrrigationPeriod.select(
      now: DateTime(2026, 11, 18),
      weekStart: 'saturday',
      hasIrrigation: (a, b) async => a.day == 1,
    );
    expect(result.key, 'month');
    expect(result.from, DateTime(2026, 11, 1));
    expect(result.to, DateTime(2026, 11, 18));
  });

  test('selects month even when current month is empty', () async {
    var probes = 0;
    final result = await AutomaticIrrigationPeriod.select(
      now: date,
      weekStart: 'saturday',
      hasIrrigation: (a, b) async { probes++; return false; },
    );
    expect(result.key, 'month');
    expect(probes, 3);
  });

  test('week start follows station settings over the year boundary', () async {
    final result = await AutomaticIrrigationPeriod.select(
      now: DateTime(2027, 1, 1),
      weekStart: 'monday',
      hasIrrigation: (a, b) async => a.day == 28,
    );
    expect(result.key, 'week');
    expect(result.from, DateTime(2026, 12, 28));
    expect(result.to, DateTime(2027, 1, 1));
  });
}
