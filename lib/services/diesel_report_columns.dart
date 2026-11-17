class DieselReportColumns {
  static bool invoiceHasCloud(List<Map<String, Object?>> rows, String fallback) {
    const cloudTypes = ['solar', 'equivalent_hybrid', 'third'];
    final types = rows.map((row) => row['system_type']).whereType<String>()
        .where((type) => type == 'diesel' || cloudTypes.contains(type)).toSet();
    return types.isEmpty ? cloudTypes.contains(fallback) : types.any(cloudTypes.contains);
  }

  static bool dieselOnly(List<Map<String, Object?>> rows, String fallback) {
    final types = rows.map((row) => row['system_type']).whereType<String>()
        .where((type) => const ['diesel', 'solar', 'equivalent_hybrid'].contains(type)).toSet();
    return types.isEmpty ? fallback == 'diesel' : types.length == 1 && types.contains('diesel');
  }

  static List<String> select(List<String> columns, {required bool dieselOnly, required bool hasDiesel}) {
    final result = <String>[];
    for (final column in columns) {
      if (column == 'cloud_minutes' && (dieselOnly || hasDiesel)) {
        result.add('diesel_consumption_liters');
      }
      if (dieselOnly && (column == 'cloud_minutes' || column == 'cloud_status')) {
        continue;
      }
      result.add(column);
    }
    return result;
  }
}
