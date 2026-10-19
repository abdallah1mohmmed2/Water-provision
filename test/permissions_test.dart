import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/core/permissions.dart';
void main(){
  test('المدير وحده يملك الإعدادات والتجاوز',(){expect(Permissions.can(AppRole.manager,'settings'),true);expect(Permissions.can(AppRole.accountant,'settings'),false);expect(Permissions.can(AppRole.manager,'override_queue'),true);expect(Permissions.can(AppRole.operations,'override_queue'),false);});
  test('موظف التشغيل يبدأ الجلسة ولا يغير الحسابات',(){expect(Permissions.can(AppRole.operations,'start_session'),true);expect(Permissions.can(AppRole.operations,'payments'),false);expect(Permissions.can(AppRole.operations,'expenses'),false);});
  test('المستفيد محدود ببياناته وطلب الحجز',(){expect(Permissions.can(AppRole.beneficiary,'view_own'),true);expect(Permissions.can(AppRole.beneficiary,'request_booking'),true);expect(Permissions.can(AppRole.beneficiary,'reports'),false);});
  test('حذف السجلات للمدير وحده',(){expect(Permissions.can(AppRole.manager,'delete_records'),true);expect(Permissions.can(AppRole.accountant,'delete_records'),false);expect(Permissions.can(AppRole.operations,'delete_records'),false);});
}
