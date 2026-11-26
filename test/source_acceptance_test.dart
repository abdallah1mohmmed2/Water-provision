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
    // Notifications are attached to the root overlay above modal quick/full forms.
    expect(app, contains('OverlayEntry? _alertOverlay'));
    expect(app, contains('Overlay.of(context, rootOverlay: true)'));
    expect(app, contains('_alertSub = AppAlerts.stream.listen(_showAlertOverlay)'));
    // Dashboard income cards include type-3 irrigations according to their hybrid source.
    expect(repo, contains("system_type='equivalent_hybrid' AND hybrid_source='solar'"));
    expect(repo, contains("system_type='equivalent_hybrid' AND hybrid_source='diesel'"));
    expect(app, contains('beneficiary_detailed'));
    expect(app, contains('system_comparison'));
    expect(server, contains('/api/v1/beneficiary/request-code'));
    expect(server, contains('/api/v1/restore'));
    final setup = app.substring(app.indexOf('class InitialSetupPage'), app.indexOf('class AdminShell'));
    expect(setup, contains("if(type=='solar'||type=='equivalent_hybrid')_field(solarRate"));
    expect(setup, contains("if(type=='diesel'||type=='equivalent_hybrid')_field(dieselRate"));
    expect(setup, contains("if(type=='diesel'||type=='equivalent_hybrid')Padding"));
    expect(setup, contains("if(needsOil)Container"));
    expect(setup, contains("DieselOilService(repo.db).configure"));
    expect(setup, contains("hybrid_diesel_hourly_rate"));
    expect(setup, contains("diesel_hourly_water_rate"));
  });
}
