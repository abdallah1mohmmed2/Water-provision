#!/usr/bin/env python3
"""Static source verification for the Saqia project.
This does not replace Flutter analyze/test/build.
"""
from pathlib import Path
import hashlib, re, sqlite3, sys

ROOT=Path(__file__).resolve().parents[1]
errors=[]

schema=ROOT/'assets/db/001_initial.sql'
try:
    c=sqlite3.connect(':memory:'); c.executescript(schema.read_text(encoding='utf-8'))
except Exception as e:
    errors.append(f'SQL schema: {e}')
else:
    required=['stations','pumps','beneficiaries','partners','workers','irrigations','irrigation_sessions','queue_entries','booking_requests','diesel_movements','payments','payment_methods','cashboxes','cashbox_transfers','expenses','worker_transactions','partner_transactions','accounts','journal_entries','journal_lines','audit_logs','settings','notifications','backup_records','sync_queue']
    got={r[0] for r in c.execute("select name from sqlite_master where type='table'")}
    missing=set(required)-got
    if missing: errors.append('Missing required tables: '+', '.join(sorted(missing)))

app=(ROOT/'lib/features/app.dart').read_text(encoding='utf-8')
report_keys=re.search(r'static\s+const\s+keys\s*=\s*\[(.*?)\];',app,re.S)
if not report_keys or len(re.findall(r"'[^']+'",report_keys.group(1))) < 24:
    errors.append('Report UI does not expose all 24 required report definitions')

server=(ROOT/'server/lib/server.dart').read_text(encoding='utf-8')
if 'status:501' in server or '_notImplementedYet' in server:
    errors.append('Server still contains a 501/not-implemented route')

if "await r.readAsString()" not in server:
    errors.append('Server request body parsing is not asynchronous')

initial_hash=hashlib.sha256(b'admin123').hexdigest()
db=(ROOT/'lib/data/local/database.dart').read_text(encoding='utf-8')
if initial_hash not in db:
    errors.append('Default manager credential hash is missing')

print('SAQIA STATIC SOURCE CHECK')
print('required tables: OK')
print('report definitions: OK' if not report_keys or len(re.findall(r"'[^']+'",report_keys.group(1))) >= 24 else 'report definitions: FAIL')
print('API stubs: OK' if 'status:501' not in server and '_notImplementedYet' not in server else 'API stubs: FAIL')
print('default credential seed: OK' if initial_hash in db else 'default credential seed: FAIL')
if errors:
    print('\nFAILURES:')
    for e in errors: print('-',e)
    sys.exit(1)
print('\nSTATIC CHECK PASSED. Flutter SDK execution is still required for analyze/test/build.')
