import 'package:flutter_test/flutter_test.dart';
import '../lib/features/global_financial_report.dart';

void main() {
  group('Global financial report arithmetic', () {
    test('net is collections minus period expenses, not irrigation revenue', () {
      expect(GlobalFinancialReportService.netDistributable(500000, 50000), 450000);
      expect(GlobalFinancialReportService.netDistributable(10000, 12000), -2000);
    });

    test('receivable total counts only positive beneficiary balances', () {
      expect(GlobalFinancialReportService.totalReceivable([70000, -15000, 0, 23000]), 93000);
    });

    test('previous-debt collection estimate caps collections by prior debt per party', () {
      expect(GlobalFinancialReportService.estimatePreviousDebtCollected([
        {'prior_debt': 100000, 'period_collections': 40000},
        {'prior_debt': 0, 'period_collections': 50000},
        {'prior_debt': 20000, 'period_collections': 50000},
      ]), 60000);
    });
  });
}