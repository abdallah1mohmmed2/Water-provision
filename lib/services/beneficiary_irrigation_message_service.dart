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
  }) => prepareForParty(
        userId: userId,
        partyType: 'beneficiary',
        partyId: beneficiaryId,
        irrigationId: irrigationId,
      );

  Future<PreparedIrrigationMessage> prepareForParty({
    required int userId,
    required String partyType,
    required int partyId,
    required int irrigationId,
  }) async {
    const tables = {
      'beneficiary': 'beneficiaries',
      'worker': 'workers',
      'partner': 'partners',
    };
    final table = tables[partyType];
    if (table == null) throw ArgumentError('نوع صاحب السقاية غير صالح');
    final actions = PartyIrrigationActions(repo.db,
      userId: userId, partyType: partyType, partyId: partyId, irrigationId: irrigationId);
    final row = await actions.record();
    final owners = await repo.db.query(
      'SELECT name,phone FROM $table WHERE id=? AND station_id=?',
      args: [partyId, row['station_id']],
    );
    if (owners.length != 1) throw StateError('صاحب السقاية غير متاح');
    final owner = owners.single;
    final start = DateTime.parse('${row['start_datetime']}');
    final end = DateTime.parse('${row['end_datetime']}');
    final total = (row['total_amount'] as num).round();
    final paid = (row['paid_amount'] as num).round();
    // Messages to workers/partners must not expose unpaid wages or profit
    // allocations. Their message balance is an operational-only projection.
    final balance = partyType == 'beneficiary'
        ? ((await repo.accounting.beneficiaryBalance(partyId))['balance'] ?? 0)
        : await repo.accounting.partyOperationalMessageBalance(
            partyType: partyType, partyId: partyId);
    // Reconstruct the balance immediately before this saved irrigation.
    // Only its unpaid amount changes the party balance: total - paid.
    // Beneficiary convention: positive means due (subtract irrigation debit).
    // Worker/partner message convention: irrigation debit is negative (add it back).
    final irrigationOutstanding = total - paid;
    final previousBalance = partyType == 'beneficiary'
        ? balance - irrigationOutstanding
        : balance + irrigationOutstanding;
    final fuel = await IrrigationMessageFuelService(repo).forIrrigation(irrigationId);
    final settings = await repo.settings();
    String money(int amount) => '$amount ريال';
    String partyBalanceText(int amount) => amount == 0
        ? 'متوازن (0 ريال)'
        : (amount > 0 ? 'له ' : 'عليه ') + amount.abs().toString() + ' ريال';
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
        // Balance is reconstructed from the current balance and this irrigation's net effect.
        'الرصيد السابق': previousBalance == null ? 'غير محفوظ لهذه السقاية' : partyBalanceText(previousBalance),
        'الرصيد الحالي': balance == 0 ? 'متوازن (0 ريال)'
          : '${balance > 0 ? (partyType == 'beneficiary' ? 'عليه' : 'له') : (partyType == 'beneficiary' ? 'له' : 'عليه')} ${balance.abs()} ريال',
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
