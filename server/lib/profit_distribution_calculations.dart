/// Server-side copy of the proven pure profit allocation algorithm from
/// lib/domain/accounting/calculations.dart.
/// Keep parity tests against the client implementation: the server package
/// must remain deployable independently without importing Flutter's parent dir.
class ProfitDistributionCalculations {
  static int distributableProfit({
    required int totalRevenue,
    required int generalExpenses,
    required int workerEntitlements,
  }) => (totalRevenue - generalExpenses - workerEntitlements).clamp(0, 1 << 62);

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
    // لا نرفع حصص الشركاء بالتقريب ولا نمنح الشريك الأخير باقي الكسور.
    // كل حصة تُقرّب لأسفل، وما يتبقى يظل غير موزع ولا يتجاوز صافي الربح.
    final percentagePool = (distributable * percentageTotal / 100)
        .floor()
        .clamp(0, distributable)
        .toInt();
    var percentageAllocated = 0;
    for (final p in percentagePartners) {
      final id = (p['id'] as num).toInt();
      final percentage = (p['ownership_percentage'] as num?)?.toDouble() ?? 0;
      final amount = percentageTotal <= 0
          ? 0
          : (percentagePool * percentage / percentageTotal)
              .floor()
              .clamp(0, percentagePool - percentageAllocated)
              .toInt();
      result[id] = amount;
      percentageAllocated += amount;
    }

    final sharePool = distributable - percentagePool;
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
      for (final p in sharePartners) {
        final id = (p['id'] as num).toInt();
        final shares = (p['shares_count'] as num?)?.toDouble() ?? 0;
        final amount = (sharePool * shares / totalShares)
            .floor()
            .clamp(0, sharePool - sharesAllocated)
            .toInt();
        result[id] = amount;
        sharesAllocated += amount;
      }
    }
    return result;
  }
}
