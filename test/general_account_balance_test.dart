import 'package:flutter_test/flutter_test.dart';
import '../lib/features/general_accounts_page.dart';

void main() {
  group('calculateGeneralAccountBalance', () {
    test('receipt reduces receivable balance and payment increases it', () {
      expect(
        calculateGeneralAccountBalance(10000, [
          {'type': 'receipt', 'amount': 3000},
          {'type': 'payment', 'amount': 2000},
          {'type': 'receipt', 'amount': 4000},
        ]),
        5000,
      );
    });

    test('supports payable opening balance and movement across zero', () {
      expect(
        calculateGeneralAccountBalance(-2000, [
          {'type': 'payment', 'amount': 500},
          {'type': 'receipt', 'amount': 3000},
        ]),
        -4500,
      );
    });

    test('empty transactions preserve opening balance', () {
      expect(calculateGeneralAccountBalance(-1250, const []), -1250);
    });
  });
}
