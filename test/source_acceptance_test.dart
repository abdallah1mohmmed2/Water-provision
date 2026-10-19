import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('المصدر يحتوي على عناصر القبول الأساسية في الوثيقة', () {
    final root = Directory.current;
    final schema = File('${root.path}/assets/db/001_initial.sql').readAsStringSync();
    final app = File('${root.path}/lib/features/app.dart').readAsStringSync();
    final accounting = File('${root.path}/lib/domain/accounting/accounting_service.dart').readAsStringSync();
    final repo = File('${root.path}/lib/data/repositories/repositories.dart').readAsStringSync();
    final server = File('${root.path}/server/lib/server.dart').readAsStringSync();

    const tables = [
      'stations','pumps','beneficiaries','partners','workers','irrigations',
      'irrigation_sessions','queue_entries','booking_requests','diesel_movements',
      'payments','payment_methods','cashboxes','cashbox_transfers','expenses',
      'worker_transactions','partner_transactions','accounts','journal_entries',
      'journal_lines','audit_logs','settings','notifications','backup_records','sync_queue',
    ];
    for (final table in tables) {
      expect(schema, contains('CREATE TABLE $table'));
    }

    expect(accounting, contains('_assertPeriodOpen'));
    expect(accounting, contains('journal_entries'));
    expect(accounting, contains('journal_lines'));
    expect(repo, contains('postponed'));
    expect(repo, contains('booking_requests'));
    expect(app, contains('beneficiary_detailed'));
    expect(app, contains('system_comparison'));
    expect(server, contains('/api/v1/beneficiary/request-code'));
    expect(server, contains('/api/v1/restore'));
  });
}
