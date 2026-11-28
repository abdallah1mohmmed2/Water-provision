import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/features/global_financial_report.dart';
import 'package:saqia_station/domain/accounting/calculations.dart';

void main() {
  group('Global financial report arithmetic', () {
    test('net is collections minus period expenses, not irrigation revenue', () {
      expect(GlobalFinancialReportService.netDistributable(500000, 50000), 450000);
      expect(GlobalFinancialReportService.netDistributable(10000, 12000), -2000);
    });

    test('receivable total counts only positive beneficiary balances', () {
      expect(GlobalFinancialReportService.totalReceivable([70000, -15000, 0, 23000]), 93000);
    });

    test('partner percentages distribute net collections after expenses', () {\n      final partners = [\n        {'id': 1, 'ownership_mode': 'percentage', 'ownership_percentage': 50, 'shares_count': 0},\n        {'id': 2, 'ownership_mode': 'percentage', 'ownership_percentage': 30, 'shares_count': 0},\n        {'id': 3, 'ownership_mode': 'percentage', 'ownership_percentage': 20, 'shares_count': 0},\n      ];\n      final shares = AccountingCalculations.partnerDistributionAmounts(distributable: 450000, partners: partners);\n      expect(shares, {1: 225000, 2: 135000, 3: 90000});\n      expect(AccountingCalculations.partnerDistributionAmounts(distributable: 0, partners: partners), {1: 0, 2: 0, 3: 0});\n    });\n\n    test('previous-debt collection estimate caps collections by prior debt per party', () {
      expect(GlobalFinancialReportService.estimatePreviousDebtCollected([
        {'prior_debt': 100000, 'period_collections': 40000},
        {'prior_debt': 0, 'period_collections': 50000},
        {'prior_debt': 20000, 'period_collections': 50000},
      ]), 60000);
    });
  });
}