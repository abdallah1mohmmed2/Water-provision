#!/usr/bin/env python3
from pathlib import Path
import re, sqlite3, tempfile

ROOT=Path(__file__).resolve().parents[1]
app=(ROOT/'lib/features/app.dart').read_text()
repo=(ROOT/'lib/data/repositories/repositories.dart').read_text()
accounting=(ROOT/'lib/domain/accounting/accounting_service.dart').read_text()
services=(ROOT/'lib/services/backup_service.dart').read_text()
reports=(ROOT/'lib/services/report_service.dart').read_text()
schema=(ROOT/'assets/db/001_initial.sql').read_text()
server=(ROOT/'server/lib/server.dart').read_text()

screens={
 'DashboardPage':['dashboard','dieselStock'],
 'BeneficiariesPage':['beneficiaries','createBeneficiary','beneficiaryDetails'],
 'IrrigationsPage':['irrigations'],
 'NewIrrigationPage':['recordIrrigation','beneficiaries','settings'],
 'SessionsPage':['sessions','startSession','stopSession','postponeSession'],
 'QueueBookingPage':['queue','bookings','enqueue','createBooking','postponeQueue','serveSpecific','reviewBooking'],
 'DieselPage':['diesel','dieselStock','dieselWarning','addDieselMovement'],
 'PaymentsPage':['payments','receivePayment','payWorker','payPartner'],
 'CashboxesPage':['cashboxes','transfers','createCashbox','transferCash'],
 'ExpensesPage':['expenses','addExpense'],
 'WorkersPage':['workers','createWorker','workerTransaction'],
 'PartnersPage':['partners','createPartner','createPartnerShare','payPartner'],
 'JournalPage':['journal'],
 'LedgerPage':['ledger'],
 'ReportsPage':['ReportService','printPdf'],
 'NotificationsPage':['notifications','markNotificationRead'],
 'SettingsPage':['settings','setSetting'],
 'BackupPage':['history','createAndShare','pickAndRestoreDatabase'],
 'PerformancePage':['report_runs','performance_metrics'],
}
errors=[]
for screen, methods in screens.items():
    m=re.search(r'class '+re.escape(screen)+r'\b.*?(?=\nclass [A-Z]|\Z)',app,re.S)
    if not m: errors.append(f'missing screen: {screen}'); continue
    body=m.group(0)
    for method in methods:
        if method not in body: errors.append(f'{screen}: missing DB/service call {method}')
for method in sorted({m for ms in screens.values() for m in ms}):
    if method not in repo and method not in accounting and method not in services and method not in reports and method not in ['report','report_runs','performance_metrics']:
        errors.append(f'project method not found: {method}')

# Validate the authoritative 25-table schema by executing it in SQLite.
with tempfile.NamedTemporaryFile(suffix='.db') as f:
    con=sqlite3.connect(f.name)
    con.executescript(schema)
    tables={r[0] for r in con.execute("select name from sqlite_master where type='table'")}
    required=['stations','pumps','beneficiaries','partners','workers','irrigations','irrigation_sessions','queue_entries','booking_requests','diesel_movements','payments','payment_methods','cashboxes','cashbox_transfers','expenses','worker_transactions','partner_transactions','general_accounts','general_account_transactions','accounts','journal_entries','journal_lines','audit_logs','settings','notifications','backup_records','sync_queue']
    missing=[x for x in required if x not in tables]
    if missing: errors.append('schema missing: '+','.join(missing))
    for table in ['beneficiaries','partners','workers','cashboxes','payment_methods']:
        cols={r[1] for r in con.execute(f'pragma table_info({table})')}
        if 'station_id' not in cols: errors.append(f'{table}: missing station_id')
    con.close()

# API safety/coverage checks.
for needle in ['_atomic','_stationId','_requireOwn','_audit','_workerCreate','_partnerCreate']:
    if needle not in server: errors.append('server missing '+needle)
if len(re.findall(r"r\.post\('/api/v1/workers'",server)) != 1: errors.append('worker create route missing')
if len(re.findall(r"r\.post\('/api/v1/partners'",server)) != 1: errors.append('partner create route missing')

if errors:
    print('SCREEN/DB AUDIT FAILED')
    for e in errors: print('-',e)
    raise SystemExit(1)
print(f'SCREEN/DB AUDIT PASSED: {len(screens)}/{len(screens)} screens mapped to persistence/service operations')
print('SQLite schema execution: PASS')
print('API atomicity/ownership/audit markers: PASS')
