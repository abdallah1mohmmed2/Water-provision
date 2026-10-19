"""Static audit for the general ledger and journal screens."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'lib/features/app.dart').read_text(encoding='utf-8')
REPO = (ROOT / 'lib/data/repositories/repositories.dart').read_text(encoding='utf-8')
checks = []
def check(n, c): checks.append((n, bool(c)))

check('accounts loaded from DB (no hard-coded map)', "Future<List<Map<String, Object?>>> accounts()" in REPO and "'1100': 'التحويلات'" not in APP and "final accounts = const {" not in APP)
check('journal query exposes journal_id (tap no longer crashes)', "je.id journal_id" in REPO)
check('journal query joins party names', "COALESCE(b.name,w.name,p.name) party_name" in REPO)
check('journal query reads posted entries only', "WHERE $w AND je.status=\\'posted\\'" in REPO)
check('ledgerStatement computes opening + running balance', "'opening': opening" in REPO and "running += d - c;" in REPO)
check('ledger opening excludes unposted entries', "je.status='posted' AND je.date<?" in REPO and "a.code=?" in REPO)
check('ledger date filter bar', "class _DateRangeBar" in APP and "ledgerStatement(code, from: from, to: to)" in APP)
check('ledger shows totals', all(k in APP for k in ["Metric('رصيد أول المدة'", "Metric('إجمالي عليه'", "Metric('إجمالي له'", "Metric('الرصيد الختامي'"]))
check('ledger dropdown updates synchronously', "setState(() => code = v);\n              load();" in APP)
check('stale responses ignored (sequence token)', APP.count('seq != _seq') >= 4)
check('dates formatted, not raw ISO', "_fmtLedgerDate(x['date'])" in APP and "_fmtLedgerDate(head['date'])" in APP)
check('party chip opens party page', "_openLedgerParty(c, widget.r, x)" in APP)
check('reference shown in Arabic', "String _refLabel(Object? type, Object? id)" in APP)
check('journal groups lines per entry', "putIfAbsent(l['journal_id']" in APP)
check('journal date filter + search', APP.count('_DateRangeBar(') >= 3)
check('journal details lists account names without account codes', "a.name description" in APP and "a.code||' • '||a.name description" not in APP)
fails = [n for n, c in checks if not c]
for n, c in checks: print('PASS' if c else 'FAIL', '-', n)
print(f'Ledger/journal audit: {len(checks)-len(fails)}/{len(checks)} PASS')
raise SystemExit(1 if fails else 0)
