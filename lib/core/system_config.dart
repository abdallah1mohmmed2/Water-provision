import '../data/repositories/repositories.dart';

class SystemConfig {
  final String type;
  final int pumpId;
  final String pumpName;

  const SystemConfig({required this.type, required this.pumpId, required this.pumpName});

  bool get isDiesel => type == 'diesel';
  bool get isSolar => type == 'solar';
  bool get isThird => type == 'equivalent_hybrid';

  /// Human-readable name of the selected system for the welcome banner.
  /// It has no effect on accounting or the active irrigation configuration.
  static String displayNameFor(String systemType) => switch (systemType) {
    'diesel' => 'منظومة الديزل',
    'solar' => 'المنظومة الشمسية',
    'equivalent_hybrid' => 'النوع الثالث',
    _ => 'المنظومة غير محددة',
  };


  static Future<SystemConfig> load(StationRepository repo) async {
    final x = await repo.systemConfiguration();
    return SystemConfig(
      type: '${x['system_type']}',
      pumpId: x['pump_id'] as int,
      pumpName: '${x['pump_name']}',
    );
  }
}
