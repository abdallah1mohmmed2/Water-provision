import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/domain/accounting/calculations.dart';

void main() {
  group('حسابات السقي', () {
    final start = DateTime(2026, 1, 1, 8);

    test('ديزل: دقيقة واحدة = دقيقة محاسبية عند تفعيل المحاسبة الجزئية', () {
      final x = AccountingCalculations.diesel(
        start: start,
        end: start.add(const Duration(minutes: 90)),
        hourlyWaterRate: 6000,
        litersPerHour: 4,
        dieselPrice: 1000,
        cloudMinutes: 0,
      );
      expect(x.minutes, 90);
      expect(x.chargeableMinutes, 90);
      expect(x.waterAmount, 9000);
      expect(x.dieselLiters, 6);
      expect(x.dieselAmount, 6000);
      expect(x.totalAmount, 15000);
    });

    test('شمسي: خصم الغيم لا يتجاوز مدة السقي', () {
      final x = AccountingCalculations.solar(
        start: start,
        end: start.add(const Duration(minutes: 60)),
        hourlyRate: 6000,
        cloudMinutes: 90,
      );
      expect(x.minutes, 60);
      expect(x.cloudMinutes, 60);
      expect(x.chargeableMinutes, 0);
      expect(x.totalAmount, 0);
    });

    test('النوع الثالث لا يولد حركة ديزل', () {
      final x = AccountingCalculations.equivalent(
        start: start,
        end: start.add(const Duration(minutes: 30)),
        hourlyRate: 8000,
      );
      expect(x.dieselLiters, 0);
      expect(x.dieselAmount, 0);
      expect(x.totalAmount, 4000);
    });

    test('المحاسبة بالساعة الكاملة عند تعطيل الجزء من الساعة', () {
      final x = AccountingCalculations.solar(
        start: start,
        end: start.add(const Duration(minutes: 61)),
        hourlyRate: 6000,
        cloudMinutes: 0,
        partialHour: false,
      );
      expect(x.totalAmount, 12000);
    });

    test('منتصف الليل مرفوض افتراضيًا ومسموح بإعداد صريح', () {
      final late = DateTime(2026, 1, 1, 23, 50);
      final early = DateTime(2026, 1, 1, 0, 10);
      expect(() => AccountingCalculations.minutesBetween(late, early), throwsArgumentError);
      expect(AccountingCalculations.minutesBetween(late, early, allowMidnightCrossing: true), 20);
    });

    test('له/عليه وفق صيغة الرصيد', () {
      expect(
        AccountingCalculations.beneficiaryBalance(
          opening: 1000,
          carried: 500,
          irrigationDue: 5000,
          advances: 500,
          paid: 3000,
          financialDieselCredit: 0,
        ),
        4000,
      );
      expect(AccountingCalculations.balanceLabel(4000), 'عليه 4000 ريال');
      expect(AccountingCalculations.balanceLabel(-2500), 'له 2500 ريال');
      expect(AccountingCalculations.balanceLabel(0), 'متوازن');
      // العامل/الشريك: الموجب = له (المحطة مدينة)، السالب = عليه.
      expect(AccountingCalculations.partyDueLabel(2800), 'له 2800 ريال');
      expect(AccountingCalculations.partyDueLabel(-300), 'عليه 300 ريال');
      expect(AccountingCalculations.partyDueLabel(0), 'متوازن');
    });

    test('حصة الشريك بالنسبة والأسهم', () {
      expect(AccountingCalculations.partnerShare(distributable: 100000, percentage: 25), 25000);
      expect(AccountingCalculations.partnerShareByMode(mode: 'shares', distributable: 100000, partnerShares: 2, totalShares: 8, percentage: 0), 25000);
    });
    test('توزيع النسب والأسهم لا يتجاوز الربح المتاح ويرفض نسبًا فوق 100%', () {
      final amounts = AccountingCalculations.partnerDistributionAmounts(
        distributable: 100000,
        partners: [
          {'id': 1, 'ownership_mode': 'percentage', 'ownership_percentage': 20, 'shares_count': 0},
          {'id': 2, 'ownership_mode': 'percentage', 'ownership_percentage': 30, 'shares_count': 0},
          {'id': 3, 'ownership_mode': 'shares', 'ownership_percentage': 0, 'shares_count': 1},
          {'id': 4, 'ownership_mode': 'shares', 'ownership_percentage': 0, 'shares_count': 3},
        ],
      );
      expect(amounts[1], 20000);
      expect(amounts[2], 30000);
      expect(amounts[3], 12500);
      expect(amounts[4], 37500);
      expect(amounts.values.fold<int>(0, (sum, value) => sum + value), 100000);
      expect(
        () => AccountingCalculations.partnerDistributionAmounts(
          distributable: 100000,
          partners: [
            {'id': 1, 'ownership_mode': 'percentage', 'ownership_percentage': 70, 'shares_count': 0},
            {'id': 2, 'ownership_mode': 'percentage', 'ownership_percentage': 40, 'shares_count': 0},
          ],
        ),
        throwsArgumentError,
      );
    });
    test('التقريب بالأعداد الصحيحة: 23 دقيقة × 300 لأعلى = 115 وليس 116', () {
      final x = AccountingCalculations.equivalent(
        start: start,
        end: start.add(const Duration(minutes: 23)),
        hourlyRate: 300,
        rounding: 'up',
      );
      expect(x.totalAmount, 115);
    });

    test('divRound يطابق التقريب الكسري الدقيق', () {
      for (var m = 1; m < 600; m++) {
        for (final r in [100, 250, 300, 350, 450, 1200]) {
          final n = m * r;
          expect(AccountingCalculations.divRound(n, 60, 'up'), (n + 59) ~/ 60);
          expect(AccountingCalculations.divRound(n, 60, 'down'), n ~/ 60);
          expect(AccountingCalculations.divRound(n, 60, 'nearest'), (2 * n + 60) ~/ 120);
        }
      }
    });

    test('ديزل: ثمن الوقود بدقة 3 خانات للتر/ساعة', () {
      final x = AccountingCalculations.diesel(
        start: start,
        end: start.add(const Duration(minutes: 45)),
        hourlyWaterRate: 0,
        litersPerHour: 2.5,
        dieselPrice: 1000,
        cloudMinutes: 0,
      );
      expect(x.dieselLiters, closeTo(1.875, 1e-9));
      expect(x.dieselAmount, 1875);
    });
  });
}
