import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/domain/accounting/debt_report_totals.dart';

void main() {
  Map<String, Object?> row(Object? balance, {String party = 'beneficiary'}) =>
      {'balance': balance, 'party_type': party};

  group('debt report net remaining balance', () {
    test('net عليه is the sum owed by parties minus sum owed to parties', () {
      final totals = DebtReportTotals.fromRows([
        row(8000), row(-3000, party: 'worker'),
        row(2000), row(-4000, party: 'partner'),
      ]);
      expect(totals.totalAlayh, 10000);
      expect(totals.totalLah, 7000);
      expect(totals.net, 3000);
      expect(totals.netLabel((n) => '$n ريال'), 'عليه 3000 ريال');
    });

    test('net له when total owed to parties is larger', () {
      final totals = DebtReportTotals.fromRows([
        row(100, party: 'beneficiary'),
        row(-500, party: 'worker'),
      ]);
      expect(totals.totalAlayh, 100);
      expect(totals.totalLah, 500);
      expect(totals.net, -400);
      expect(totals.netLabel((n) => '$n ريال'), 'له 400 ريال');
    });

    test('equal nonzero totals show balanced NET without hiding gross debts', () {
      final totals = DebtReportTotals.fromRows([row(1200), row(-1200)]);
      expect(totals.totalAlayh, 1200);
      expect(totals.totalLah, 1200);
      expect(totals.net, 0);
      expect(totals.netLabel((n) => '$n ريال'), 'متوازن (0 ريال)');
    });

    test('empty report and zero balance show a zero net', () {
      final empty = DebtReportTotals.fromRows(<Map<String, Object?>>[]);
      final zero = DebtReportTotals.fromRows([row(0)]);
      expect(empty.net, 0);
      expect(zero.totalAlayh, 0);
      expect(zero.totalLah, 0);
      expect(zero.net, 0);
    });

    test('search and debt-direction filters update net from visible rows', () {
      final all = [row(500), row(-200), row(-50)];
      final filtered = all.where((x) => (x['balance'] as int) < 0);
      expect(DebtReportTotals.fromRows(all).net, 250);
      expect(DebtReportTotals.fromRows(filtered).net, -250);
    });

    test('accepts numeric balance strings without losing fraction', () {
      final totals = DebtReportTotals.fromRows([row('750.50'), row('-100.25')]);
      expect(totals.net, 650.25);
    });

    test('does not modify source party balance rows', () {
      final rows = [row(10), row(-7, party: 'partner')];
      final snapshot = rows.map((x) => Map<String, Object?>.from(x)).toList();
      DebtReportTotals.fromRows(rows);
      expect(rows, snapshot);
    });
  });
}
