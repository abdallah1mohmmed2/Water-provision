import 'package:intl/intl.dart';

import '../core/message_time.dart';
import '../data/repositories/repositories.dart';
import '../domain/accounting/beneficiary_irrigation_actions.dart';
import 'irrigation_message_fuel_service.dart';
import 'message_template_service.dart';

class PreparedIrrigationMessage {
  final String name, phone, text;
  const PreparedIrrigationMessage(this.name, this.phone, this.text);
}

/// Re-prepares a saved irrigation. It never posts, edits or cancels any record.
class BeneficiaryIrrigationMessageService {
  final StationRepository repo;
  BeneficiaryIrrigationMessageService(this.repo);

  Future<PreparedIrrigationMessage> prepare({
    required int userId,
    required int beneficiaryId,
    required int irrigationId,
  }) async {
    final actions = BeneficiaryIrrigationActions(repo.db,
      userId: userId, beneficiaryId: beneficiaryId, irrigationId: irrigationId);
    final row = await actions.record();
    final owners = await repo.db.query(
      'SELECT name,phone FROM beneficiaries WHERE id=? AND station_id=?',
      args: [beneficiaryId, row['station_id']],
    );
    if (owners.length != 1) throw StateError('المستفيد غير متاح');
    final owner = owners.single;
    final start = DateTime.parse('${row['start_datetime']}');
    final end = DateTime.parse('${row['end_datetime']}');
    final total = (row['total_amount'] as num).round();
    final paid = (row['paid_amount'] as num).round();
    final balance = (await repo.accounting.beneficiaryBalance(beneficiaryId))['balance'] ?? 0;
    final fuel = await IrrigationMessageFuelService(repo).forIrrigation(irrigationId);
    final settings = await repo.settings();
    String money(int amount) => '$amount ريال';
    final text = MessageTemplateService.render(
      settings[MessageTemplateService.irrigationKey],
      MessageTemplateService.irrigationKey,
      {
        'اسم العميل': '${owner['name']}',
        'تاريخ السقاية': DateFormat('yyyy/MM/dd').format(start),
        'وقت البداية': MessageTime.time(start),
        'وقت النهاية': MessageTime.time(end),
        'إجمالي الدقائق': '${row['minutes']}',
        'قيمة السقاية': money(total),
        'المبلغ المدفوع': money(paid),
        'المتبقي من السقاية': money(total - paid),
        // No historical balance snapshot was stored by the old save path.
        'الرصيد السابق': 'غير محفوظ لهذه السقاية',
        'الرصيد الحالي': balance == 0 ? 'متوازن (0 ريال)'
          : '${balance > 0 ? 'عليه' : 'له'} ${balance.abs()} ريال',
        'رقم العملية': '$irrigationId',
        ...fuel,
      },
      systemType: '${row['system_type']}',
    );
    // Recheck status/ownership/actor after asynchronous reads, before presenting.
    await actions.record();
    return PreparedIrrigationMessage('${owner['name']}', '${owner['phone'] ?? ''}', text);
  }
}
