import 'package:test/test.dart';
import '../lib/profit_distribution_calculations.dart';
import '../../lib/domain/accounting/calculations.dart';

void main() {
  test('P3d server and client profit formulas agree for gains, losses and zero', () {
    for (final revenue in [-100,0,1,10000]) {
      for (final expense in [-20,0,5,3000]) {
        for (final wage in [0,7,5000]) {
          expect(
            ProfitDistributionCalculations.distributableProfit(
              totalRevenue:revenue,generalExpenses:expense,workerEntitlements:wage,
            ),
            AccountingCalculations.distributableProfit(
              totalRevenue:revenue,generalExpenses:expense,workerEntitlements:wage,
            ),
          );
        }
      }
    }
  });

  test('P3d server matches client partner percentage and share allocation', () {
    final cases=<List<Map<String,Object?>>>[
      [
        {'id':1,'ownership_mode':'shares','shares_count':1},
        {'id':2,'ownership_mode':'shares','shares_count':2},
      ],
      [
        {'id':1,'ownership_mode':'percentage','ownership_percentage':25.0},
        {'id':2,'ownership_mode':'percentage','ownership_percentage':15.0},
        {'id':3,'ownership_mode':'shares','shares_count':2},
        {'id':4,'ownership_mode':'shares','shares_count':1},
      ],
      [
        {'id':1,'ownership_mode':'percentage','ownership_percentage':50.0},
        {'id':2,'ownership_mode':'percentage','ownership_percentage':50.0},
      ],
    ];
    for (final members in cases) {
      for (final amount in [0,1,2,3,10,100,101,100000]) {
        expect(
          ProfitDistributionCalculations.partnerDistributionAmounts(
            distributable:amount,partners:members,
          ),
          AccountingCalculations.partnerDistributionAmounts(
            distributable:amount,partners:members,
          ),
        );
      }
    }
  });

  test('P3d invalid allocations fail on both client and server', () {
    final invalid=<Map<String,Object?>>[
      {'id':1,'ownership_mode':'percentage','ownership_percentage':65.0},
      {'id':2,'ownership_mode':'percentage','ownership_percentage':55.0},
    ];
    expect(()=>ProfitDistributionCalculations.partnerDistributionAmounts(
      distributable:100,partners:invalid,
    ),throwsArgumentError);
    expect(()=>AccountingCalculations.partnerDistributionAmounts(
      distributable:100,partners:invalid,
    ),throwsArgumentError);
  });
}
