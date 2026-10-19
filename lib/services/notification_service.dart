import '../data/repositories/repositories.dart';

class NotificationService {
  final StationRepository repo;
  NotificationService([StationRepository? r]) : repo = r ?? StationRepository();

  Future<Map<String, String>> _templates() async {
    final s = await repo.settings();
    return {
      'appointmentTitle': s['notification_appointment_title'] ?? 'موعد السقي',
      'appointmentBody':
          s['notification_appointment_body'] ?? 'تم تحديد موعد السقي: {date}',
      'paymentTitle': s['notification_payment_title'] ?? 'تسجيل دفعة',
      'paymentBody':
          s['notification_payment_body'] ?? 'تم تسجيل دفعة بمبلغ {amount} ريال',
      'balanceTitle': s['notification_balance_title'] ?? 'تحديث الرصيد',
      'balanceBody':
          s['notification_balance_body'] ?? 'الرصيد الحالي: {balance}',
    };
  }

  String _render(String template, Map<String, String> vars) {
    var out = template;
    for (final e in vars.entries) out = out.replaceAll('{${e.key}}', e.value);
    return out;
  }

  Future<void> appointment(int beneficiaryId, String date) async {
    final t = await _templates();
    await repo.notify(
      beneficiaryId: beneficiaryId,
      type: 'appointment',
      title: t['appointmentTitle']!,
      body: _render(t['appointmentBody']!, {'date': date}),
    );
  }

  Future<void> payment(int beneficiaryId, int amount) async {
    final t = await _templates();
    await repo.notify(
      beneficiaryId: beneficiaryId,
      type: 'payment',
      title: t['paymentTitle']!,
      body: _render(t['paymentBody']!, {'amount': '$amount'}),
    );
  }

  Future<void> balance(int beneficiaryId, String label) async {
    final t = await _templates();
    await repo.notify(
      beneficiaryId: beneficiaryId,
      type: 'balance',
      title: t['balanceTitle']!,
      body: _render(t['balanceBody']!, {'balance': label}),
    );
  }
}
