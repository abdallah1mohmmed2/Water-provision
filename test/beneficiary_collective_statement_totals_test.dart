import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/domain/accounting/beneficiary_statement_totals.dart';

void main() {
  Map<String, Object?> entry(int id, num balance, {String name = 'مستفيد'}) =>
      {'beneficiary_id': id, 'beneficiary_name': name, 'balance': balance};

  group('collective beneficiary statement closing balance', () {
    test('sums each beneficiary final balance once, not the last person', () {
      final rows = [
        entry(1, 100),
        entry(1, 80),
        entry(2, -30),
        entry(2, -10),
        entry(3, 70),
      ];
      expect(BeneficiaryStatementTotals.closingBalance(
        rows, collective: true,
      ), 140);
    });

    test('does not merge different beneficiaries with identical names', () {
      final rows = [
        entry(11, 12, name: 'محمد'),
        entry(12, 34, name: 'محمد'),
      ];
      expect(BeneficiaryStatementTotals.closingBalance(
        rows, collective: true,
      ), 46);
    });

    test('last row per ID wins even when beneficiary rows are interleaved', () {
      final rows = [
        entry(1, 25),
        entry(2, -5),
        entry(1, 40),
        entry(2, -15),
      ];
      expect(BeneficiaryStatementTotals.closingBalance(
        rows, collective: true,
      ), 25);
    });

    test('filtered collective rows only count beneficiaries in the filter', () {
      final rows = [
        entry(1, 10, name: 'علي'),
        entry(2, 100, name: 'سالم'),
        entry(1, 60, name: 'علي'),
        entry(2, 120, name: 'سالم'),
      ];
      final visible = rows.where((row) =>
          '${row['beneficiary_name']}'.contains('علي'));
      expect(BeneficiaryStatementTotals.closingBalance(
        visible, collective: true,
      ), 60);
    });

    test('individual statement keeps its last running balance', () {
      final rows = <Map<String, Object?>>[
        {'balance': 100},
        {'balance': 60},
        {'balance': -15},
      ];
      expect(BeneficiaryStatementTotals.closingBalance(
        rows, collective: false,
      ), -15);
    });

    test('empty report has zero closing balance', () {
      expect(BeneficiaryStatementTotals.closingBalance(
        <Map<String, Object?>>[], collective: true,
      ), 0);
      expect(BeneficiaryStatementTotals.closingBalance(
        <Map<String, Object?>>[], collective: false,
      ), 0);
    });

    test('rejects unidentified collective rows instead of false totals', () {
      expect(
        () => BeneficiaryStatementTotals.closingBalance(
          <Map<String, Object?>>[{'balance': 10}], collective: true,
        ),
        throwsStateError,
      );
    });
  });
}
