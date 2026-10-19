from pathlib import Path

repo = Path(__file__).resolve().parents[1] / 'lib/data/repositories/repositories.dart'
app = Path(__file__).resolve().parents[1] / 'lib/features/app.dart'
r = repo.read_text()
a = app.read_text()
checks = []

def check(name, condition):
    checks.append((name, bool(condition)))

start = r.index('Future<Map<String, Object?>> partyFinancialSummary')
end = r.index('Future<List<Map<String, Object?>>> partyIrrigations', start)
summary = r[start:end]

check('summary method exists', 'partyFinancialSummary(String kind, int id)' in summary)
check('beneficiary uses BalanceSql', "BalanceSql.beneficiary('b')" in summary)
check('beneficiary reads irrigation totals', 'i.beneficiary_id=?' in summary and 'irrigation_total' in summary)
check('beneficiary reads posted payments', "p.beneficiary_id=? AND p.status='posted'" in summary)
check('worker uses personal account under 2100', "a.code='2100.W'||x.id" in summary and "a.code='2100'" in summary)
check('partner uses account 2200', "a.code='2200' AND jl.partner_id=x.id" in summary)
check('worker/partner scope journal lines by personal account or party', 'jl.worker_id=x.id' in summary and 'jl.partner_id=x.id' in summary)
check('earnings are read from posted ledger entries', "je.status='posted'" in summary and 'earnings' in summary)
check('payments are read from posted ledger entries', "je.reference_type='payment'" in summary and 'paid' in summary)
check('balance is read from credit minus debit', 'jl.credit' in summary and 'jl.debit' in summary and 'balance' in summary)
check('detail page loads summary', a.count('partyFinancialSummary(') >= 4)

failed = [name for name, ok in checks if not ok]
print(f'SUMMARY QUERY AUDIT: {len(checks) - len(failed)}/{len(checks)} PASS')
for name in failed:
    print('FAIL -', name)
if failed:
    raise SystemExit(1)
