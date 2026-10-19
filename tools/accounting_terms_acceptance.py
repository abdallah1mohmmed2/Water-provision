from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'lib/features/app.dart').read_text()
CALC = (ROOT / 'lib/domain/accounting/calculations.dart').read_text()
REPORT = (ROOT / 'lib/services/report_service.dart').read_text()
REPO = (ROOT / 'lib/data/repositories/repositories.dart').read_text()

checks = []
def check(name, cond):
    checks.append((name, bool(cond)))

check('central balance label exists', "static String balanceLabel(int balance)" in CALC)
check('positive means عليه', "'عليه ${balance.abs()} ريال'" in CALC)
check('negative means له', "'له ${balance.abs()} ريال'" in CALC)
check('zero means متوازن', "'متوازن'" in CALC)
check('dashboard no ambiguous المتبقي label', "_badge('المتبقي'" not in APP and "'المتبقي',\n                money(remaining)" not in APP)
check('new irrigation uses حالة الرصيد', "'حالة الرصيد': after" in APP and 'partyBalance + total - paidValue' in APP)
check('new irrigation displays حالة الرصيد', "'حالة الرصيد بعد العملية'" in APP and "'الرصيد الحالي'" in APP)
check('new irrigation displays المدفوع', "Metric('المدفوع'" in APP)
check('party due label exists (positive = له)', "static String partyDueLabel(int balance)" in CALC and "? 'له ${balance.abs()} ريال'" in CALC)
check('worker/partner lists use له/عليه of the party', len(re.findall(r"partyDueLabel\(\s*\(\(x\['balance'\] as num\?\)\?\.round\(\) \?\? 0\)", APP)) == 2)
check('details page picks label by kind', "AccountingCalculations.partyDueLabel(n)" in APP and "widget.kind == 'beneficiary'" in APP)
check('worker/partner delete message uses party label', REPO.count("رصيده ${AccountingCalculations.partyDueLabel(bal)}") == 2)
check('worker/partner reports use party label', "_partyDueLabel(n)" in REPORT and "partyTransactionTypeName" in REPORT)
check('worker/partner history has running balance + signed amount', "'signed_amount':signed" in REPO and "'balance':running" in REPO)
check('beneficiary timeline newest first + amount from debit/credit', "beneficiaryStatement(widget.id)).reversed" in APP and "'+ ${money(d)}'" in APP)
check('details page surfaces load errors', "loadError" in APP and "إعادة المحاولة" in APP)
check('report balance header semantic', "'balance':'حالة الرصيد'" in REPORT)
check('report remaining header semantic', "'remaining':'حالة الرصيد'" in REPORT)
check('report formats balance as له/عليه', "if (key == 'balance' || key == 'remaining')" in REPORT)
check('beneficiary statement carries running balance', "'balance': running" in REPO)
check('worker report has running balance', "_ledgerPartyTransactions" in REPO)
check('partner report has running balance', "_ledgerPartyTransactions" in REPO)
check('worker list query has balance', "BalanceSql.workerPersonal('w')" in REPO)
check('partner list query has balance', "BalanceSql.partnerPersonal('p')" in REPO)
check('journal retains debit credit', "'journal': ['date','description','account_code','account_name','debit','credit']" in REPORT)
check('ledger retains debit credit', "'ledger': ['date','description','account_code','account_name','debit','credit']" in REPORT)
check('no user-facing ambiguous المتبقي in app', 'المتبقي' not in APP)
check('no report-facing ambiguous المتبقي', "'المتبقي'" not in REPORT)

failed = [n for n, ok in checks if not ok]
for n, ok in checks:
    print(('PASS' if ok else 'FAIL') + ' - ' + n)
print(f'Accounting terms acceptance: {len(checks)-len(failed)}/{len(checks)} PASS')
if failed:
    raise SystemExit(1)
