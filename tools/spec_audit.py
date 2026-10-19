#!/usr/bin/env python3
"""Static audit that compares the implementation surface with the supplied specification.
It deliberately reports static evidence separately from runtime Flutter evidence.
"""
from pathlib import Path
import re, sys
from docx import Document

ROOT = Path(__file__).resolve().parents[1]
SPEC = Path('/mnt/data/المواصفات_التنفيذية_الشاملة_لبناء_نظام_إدارة_محطة_.docx')
errors=[]

source='\n'.join(p.read_text(encoding='utf-8', errors='ignore') for p in ROOT.rglob('*') if p.is_file() and p.suffix in {'.dart','.sql','.md','.yaml'})
spec=''
if SPEC.exists():
    d=Document(SPEC)
    spec='\n'.join(p.text for p in d.paragraphs)
    for table in d.tables:
        for row in table.rows:
            spec += '\n' + ' | '.join(cell.text for cell in row.cells)

required_tables=['stations','pumps','beneficiaries','partners','workers','irrigations','irrigation_sessions','queue_entries','booking_requests','diesel_movements','payments','payment_methods','cashboxes','cashbox_transfers','expenses','worker_transactions','partner_transactions','accounts','journal_entries','journal_lines','audit_logs','settings','notifications','backup_records','sync_queue']
missing_tables=[t for t in required_tables if f'CREATE TABLE {t}' not in source]
if missing_tables: errors.append('Missing tables: '+', '.join(missing_tables))

required_surface={
 'خصم الغيم':['cloud_minutes','chargeable_minutes'],
 'الأسعار التاريخية':['water_hourly_rate_snapshot','diesel_price_snapshot','solar_hourly_rate_snapshot','third_type_hourly_rate_snapshot'],
 'له / عليه':['عليه','له'],
 'مدة الانتظار':['min_wait_days','_checkWaiting'],
 'تجاوز المدير':['override_waiting_period','waiting_period_override'],
 'الطابور':['queue_entries','postponeQueue'],
 'الحجوزات':['booking_requests','reviewBooking'],
 'الديزل':['diesel_movements','dieselStock'],
 'اليومية':['journal_entries','journal_lines'],
 'النسخ الاحتياطي':['BackupService','validateDatabaseFile'],
 'المستفيد':['BeneficiaryApi','beneficiary_sessions'],
 'API':['/api/v1/'],
}
for label, needles in required_surface.items():
    if not all(n in source for n in needles): errors.append(f'{label}: missing static evidence: {needles}')

app=(ROOT/'lib/features/app.dart').read_text(encoding='utf-8')
m=re.search(r"static\s+const\s+keys\s*=\s*\[(.*?)\];",app,re.S)
if not m or len(re.findall(r"'[^']+'",m.group(1))) < 24: errors.append('Less than 24 report keys exposed in UI')

# Detect duplicate switch case labels in the largest Dart files, a common silent source defect.
for f in ROOT.rglob('*.dart'):
    text=f.read_text(encoding='utf-8',errors='ignore')
    cases=re.findall(r"case\s+'([^']+)'\s*:",text)
    dup=sorted({x for x in cases if cases.count(x)>1})
    if dup: errors.append(f'Duplicate switch cases in {f.relative_to(ROOT)}: {dup}')

print('SAQIA SPEC STATIC AUDIT')
print('Specification paragraphs/tables loaded:', bool(spec))
print('Required tables:', len(required_tables)-len(missing_tables), '/', len(required_tables))
print('Report definitions:', len(re.findall(r"'[^']+'",m.group(1))) if m else 0, '/ 24')
print('Runtime status: Flutter SDK is required for analyze/test/build and is not claimed here.')
if errors:
    print('\nFAILURES:')
    for e in errors: print('-',e)
    sys.exit(1)
print('STATIC AUDIT PASSED')
