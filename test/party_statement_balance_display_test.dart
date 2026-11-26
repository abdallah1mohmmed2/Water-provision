import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/services/party_statement_balance_display.dart';

void main() {
  String format(Map<String, Object?> row) =>
      PartyStatementBalanceDisplay.format(row, money: (n) => n.toStringAsFixed(0));

  group('worker and partner PDF running balance', () {
    test('informational worker irrigation must never print a zero balance', () {
      expect(format({'type': 'worker_irrigation_info'}), '—');
      expect(format({'type': 'worker_irrigation_info', 'balance': 0}), '—');
    });

    test('informational partner irrigation must never print a zero balance', () {
      expect(format({'type': 'partner_irrigation_info'}), '—');
      expect(format({'type': 'partner_irrigation_info', 'balance': 0}), '—');
    });

    test('financial zero is a genuine zero, not a missing balance', () {
      expect(format({'type': 'payment', 'balance': 0}), 'صفر');
      expect(format({'type': 'worker_income_total', 'balance': 0}), 'صفر');
      expect(format({'type': 'partner_profit_total', 'balance': 0}), 'صفر');
      expect(
        PartyStatementBalanceDisplay.format(
          {'type': 'payment', 'balance': 0},
          money: (n) => n.toString(),
          zeroLabel: 'متوازن',
        ),
        'متوازن',
      );
    });

    test('positive and negative financial balances keep their directions', () {
      expect(format({'type': 'payment', 'balance': 125}), 'له 125');
      expect(format({'type': 'payment', 'balance': -70}), 'عليه 70');
      expect(format({'type': 'payment', 'balance': '-35'}), 'عليه 35');
    });

    test('missing or invalid balances render a dash, not a false zero', () {
      expect(format({'type': 'payment'}), '—');
      expect(format({'type': 'payment', 'balance': null}), '—');
      expect(format({'type': 'payment', 'balance': 'invalid'}), '—');
    });

    test('generic PDF path can distinguish missing from real zero', () {
      expect(
        PartyStatementBalanceDisplay.hasBalance({'type': 'partner_irrigation_info'}),
        isFalse,
      );
      expect(
        PartyStatementBalanceDisplay.hasBalance({'type': 'payment', 'balance': 0}),
        isTrue,
      );
    });
  });
}
