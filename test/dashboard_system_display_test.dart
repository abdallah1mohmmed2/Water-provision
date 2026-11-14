import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/core/system_config.dart';

void main() {
  test('dashboard welcome uses the configured system name', () {
    expect(SystemConfig.displayNameFor('diesel'), 'منظومة الديزل');
    expect(SystemConfig.displayNameFor('solar'), 'المنظومة الشمسية');
    expect(SystemConfig.displayNameFor('equivalent_hybrid'), 'النوع الثالث');
    expect(SystemConfig.displayNameFor('unconfigured'), 'المنظومة غير محددة');
  });
}
