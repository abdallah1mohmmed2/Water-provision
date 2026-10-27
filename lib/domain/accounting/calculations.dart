class IrrigationResult {
  final int minutes,
      cloudMinutes,
      chargeableMinutes,
      waterAmount,
      dieselAmount,
      totalAmount;
  final double dieselLiters;
  const IrrigationResult({
    required this.minutes,
    required this.cloudMinutes,
    required this.chargeableMinutes,
    required this.waterAmount,
    required this.dieselAmount,
    required this.totalAmount,
    required this.dieselLiters,
  });
}

class AccountingCalculations {
  static int minutesBetween(
    DateTime start,
    DateTime end, {
    bool allowMidnightCrossing = false,
  }) {
    var effectiveEnd = end;
    if (!effectiveEnd.isAfter(start)) {
      if (!allowMidnightCrossing) {
        throw ArgumentError('وقت النهاية يجب أن يكون بعد وقت البداية');
      }
      effectiveEnd = end.add(const Duration(days: 1));
    }
    final m = effectiveEnd.difference(start).inMinutes;
    if (m <= 0) throw ArgumentError('مدة السقي يجب أن تكون أكبر من صفر');
    return m;
  }

  /// تقريب مبلغ حسب وضع الإعدادات (up/down/nearest).
  static int roundAmount(double value, String mode) => _round(value, mode);

  static int _round(double value, String mode) => switch (mode) {
    'up' => value.ceil(),
    'down' => value.floor(),
    _ => value.round(),
  };

  /// قسمة صحيحة مقرّبة حسب الوضع (دون أي أعداد عشرية) لتفادي أخطاء مثل
  /// 23 دقيقة × 300 = 115.00000000000001 → 116 عند التقريب لأعلى.
  static int divRound(int numerator, int denominator, String mode) {
    if (denominator <= 0) throw ArgumentError('المقام يجب أن يكون موجبًا');
    if (numerator <= 0) return 0;
    return switch (mode) {
      'up' => (numerator + denominator - 1) ~/ denominator,
      'down' => numerator ~/ denominator,
      _ => (2 * numerator + denominator) ~/ (2 * denominator),
    };
  }

  /// مبلغ = دقائق × سعر الساعة / 60 (أو ساعات كاملة مقرّبة لأعلى إن عُطّلت الساعة الجزئية).
  static int amountForMinutes(
    int minutes,
    int hourlyRate,
    String mode,
    bool partialHour,
  ) {
    if (!partialHour) {
      final hours = (minutes + 59) ~/ 60;
      return hours * hourlyRate;
    }
    return divRound(minutes * hourlyRate, 60, mode);
  }

  static IrrigationResult diesel({
    required DateTime start,
    required DateTime end,
    required int hourlyWaterRate,
    required double litersPerHour,
    required int dieselPrice,
    required int cloudMinutes,
    bool allowMidnightCrossing = false,
    String rounding = 'nearest',
    bool partialHour = true,
  }) {
    final minutes = minutesBetween(
      start,
      end,
      allowMidnightCrossing: allowMidnightCrossing,
    );
    final cloud = cloudMinutes.clamp(0, minutes);
    final charge = minutes - cloud;
    final water = amountForMinutes(
      charge,
      hourlyWaterRate,
      rounding,
      partialHour,
    );
    // لترات/ساعة بدقة 3 خانات عشرية، والحساب بأعداد صحيحة.
    final lphMilli = (litersPerHour * 1000).round();
    final liters = charge * lphMilli / 60000;
    final fuel = divRound(charge * lphMilli * dieselPrice, 60000, rounding);
    return IrrigationResult(
      minutes: minutes,
      cloudMinutes: cloud,
      chargeableMinutes: charge,
      waterAmount: water,
      dieselAmount: fuel,
      totalAmount: water + fuel,
      dieselLiters: liters,
    );
  }

  static IrrigationResult solar({
    required DateTime start,
    required DateTime end,
    required int hourlyRate,
    required int cloudMinutes,
    bool allowMidnightCrossing = false,
    String rounding = 'nearest',
    bool partialHour = true,
  }) {
    final minutes = minutesBetween(
      start,
      end,
      allowMidnightCrossing: allowMidnightCrossing,
    );
    final cloud = cloudMinutes.clamp(0, minutes);
    final charge = minutes - cloud;
    final total = amountForMinutes(charge, hourlyRate, rounding, partialHour);
    return IrrigationResult(
      minutes: minutes,
      cloudMinutes: cloud,
      chargeableMinutes: charge,
      waterAmount: total,
      dieselAmount: 0,
      totalAmount: total,
      dieselLiters: 0,
    );
  }

  static IrrigationResult equivalent({
    required DateTime start,
    required DateTime end,
    required int hourlyRate,
    bool allowMidnightCrossing = false,
    String rounding = 'nearest',
    bool partialHour = true,
  }) {
    final minutes = minutesBetween(
      start,
      end,
      allowMidnightCrossing: allowMidnightCrossing,
    );
    final total = amountForMinutes(minutes, hourlyRate, rounding, partialHour);
    return IrrigationResult(
      minutes: minutes,
      cloudMinutes: 0,
      chargeableMinutes: minutes,
      waterAmount: total,
      dieselAmount: 0,
      totalAmount: total,
      dieselLiters: 0,
    );
  }

  static int beneficiaryBalance({
    required int opening,
    required int carried,
    required int irrigationDue,
    required int advances,
    required int paid,
    required int financialDieselCredit,
  }) =>
      opening +
      carried +
      irrigationDue +
      advances -
      paid -
      financialDieselCredit;
  static String balanceLabel(int balance) => balance > 0
      ? 'عليه ${balance.abs()} ريال'
      : balance < 0
      ? 'له ${balance.abs()} ريال'
      : 'متوازن';

  /// اتجاه رصيد العامل/الشريك (عكس المستفيد): الموجب = مستحق له على المحطة (له)،
  /// والسالب = عليه للمحطة (سقاية/سلفة تجاوزت مستحقاته).
  static String partyDueLabel(int balance) => balance > 0
      ? 'له ${balance.abs()} ريال'
      : balance < 0
      ? 'عليه ${balance.abs()} ريال'
      : 'متوازن';

  /// أسماء عربية لأنواع حركات العامل والشريك بدل عرض الرمز الخام.
  static String partyTransactionTypeName(String type) => switch (type) {
    'accrual' => 'استحقاق',
    'salary' => 'راتب',
    'share_accrual' => 'حصة أرباح',
    'share_adjustment' => 'تسوية حصة أرباح',
    'share_adjustment_reversal' => 'عكس تسوية حصة أرباح',
    'contribution' => 'مساهمة',
    'irrigation' => 'سقاية (خصم من المستحق)',
    'payment' => 'دفعة',
    'irrigation_reversal' => 'عكس سقاية',
    'payment_reversal' => 'عكس دفعة',
    _ => type,
  };
  static int workerDue({
    required int fixed,
    required double hours,
    required int hourly,
    required double percentage,
    required int baseAmount,
  }) =>
      fixed +
      (hours * hourly).round() +
      (baseAmount * percentage / 100).round();
  static int workerIrrigationEntitlement({
    required String payType, required int irrigationAmount,
    required double hours, required int hourlyRate, required double percentageRate,
  }) => workerEntitlement(
    payType: payType == 'fixed' ? 'hourly' : payType, fixedSalary: 0,
    hours: hours, hourlyRate: hourlyRate, percentageRate: percentageRate,
    percentageBase: irrigationAmount,
  );

  static int distributableProfit({
    required int totalRevenue, required int generalExpenses, required int workerEntitlements,
  }) => (totalRevenue - generalExpenses - workerEntitlements).clamp(0, 1 << 62);

  static int partnerShare({
    required int distributable,
    required double percentage,
  }) => (distributable * percentage / 100).round();

  static int workerEntitlement({
    required String payType,
    required int fixedSalary,
    required double hours,
    required int hourlyRate,
    required double percentageRate,
    required int percentageBase,
  }) {
    switch (payType) {
      case 'fixed':
        return fixedSalary;
      case 'hourly':
        return (hours * hourlyRate).round();
      case 'percentage':
        return (percentageBase * percentageRate / 100).round();
      default:
        throw ArgumentError('نوع أجر العامل غير معروف');
    }
  }

  static int partnerShareByMode({
    required String mode,
    required int distributable,
    required double partnerShares,
    required double totalShares,
    required double percentage,
  }) {
    if (distributable < 0) {
      throw ArgumentError('المبلغ القابل للتوزيع لا يمكن أن يكون سالبًا');
    }
    if (mode == 'percentage') {
      return partnerShare(distributable: distributable, percentage: percentage);
    }
    if (totalShares <= 0 || partnerShares < 0) {
      throw ArgumentError('بيانات الأسهم غير صالحة');
    }
    return (distributable * partnerShares / totalShares).round();
  }

  /// يوزع المتبقي دون تجاوز المبلغ المتاح حتى عند خلط النسب والأسهم.
  /// النسب تُحتسب أولاً من المتبقي؛ وحملة الأسهم يقتسمون الرصيد بعد النسب.
  /// إذا تجاوز مجموع نسب الملكية 100% تُرفض البيانات بدل ترحيل توزيع غير صحيح.
  static Map<int, int> partnerDistributionAmounts({
    required int distributable,
    required List<Map<String, Object?>> partners,
  }) {
    if (distributable < 0) {
      throw ArgumentError('المبلغ القابل للتوزيع لا يمكن أن يكون سالبًا');
    }
    final percentagePartners = partners
        .where((p) => '${p['ownership_mode']}' == 'percentage')
        .toList();
    final sharePartners = partners
        .where((p) => '${p['ownership_mode']}' != 'percentage')
        .toList();
    final percentageTotal = percentagePartners.fold<double>(0, (sum, p) {
      final value = (p['ownership_percentage'] as num?)?.toDouble() ?? 0;
      if (value < 0) throw ArgumentError('نسبة ملكية الشريك لا يمكن أن تكون سالبة');
      return sum + value;
    });
    if (percentageTotal > 100.0000001) {
      throw ArgumentError('مجموع نسب ملكية الشركاء يتجاوز 100%');
    }

    final result = <int, int>{};
    final percentagePool = (distributable * percentageTotal / 100)
        .round()
        .clamp(0, distributable)
        .toInt();
    var percentageAllocated = 0;
    for (var i = 0; i < percentagePartners.length; i++) {
      final p = percentagePartners[i];
      final id = (p['id'] as num).toInt();
      final percentage = (p['ownership_percentage'] as num?)?.toDouble() ?? 0;
      final remaining = percentagePool - percentageAllocated;
      final amount = i == percentagePartners.length - 1
          ? remaining
          : percentageTotal <= 0
              ? 0
              : (percentagePool * percentage / percentageTotal)
                  .round()
                  .clamp(0, remaining)
                  .toInt();
      result[id] = amount;
      percentageAllocated += amount;
    }

    final sharePool = distributable - percentageAllocated;
    if (sharePartners.isNotEmpty) {
      final totalShares = sharePartners.fold<double>(0, (sum, p) {
        final value = (p['shares_count'] as num?)?.toDouble() ?? 0;
        if (value < 0) throw ArgumentError('عدد حصص الشريك لا يمكن أن يكون سالبًا');
        return sum + value;
      });
      if (totalShares <= 0) {
        throw ArgumentError('إجمالي حصص الشركاء يجب أن يكون أكبر من صفر');
      }
      var sharesAllocated = 0;
      for (var i = 0; i < sharePartners.length; i++) {
        final p = sharePartners[i];
        final id = (p['id'] as num).toInt();
        final shares = (p['shares_count'] as num?)?.toDouble() ?? 0;
        final remaining = sharePool - sharesAllocated;
        final amount = i == sharePartners.length - 1
            ? remaining
            : (sharePool * shares / totalShares)
                .round()
                .clamp(0, remaining)
                .toInt();
        result[id] = amount;
        sharesAllocated += amount;
      }
    }
    return result;
  }
}
