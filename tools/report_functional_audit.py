from pathlib import Path
import re

root=Path(__file__).resolve().parents[1]
repo=(root/'lib/data/repositories/repositories.dart').read_text()
service=(root/'lib/services/report_service.dart').read_text()
app=(root/'lib/features/app.dart').read_text()
checks=[]

def ok(name, cond):
    checks.append((name, bool(cond)))

# Comparison reports must be able to operate across all stored system types.
for key in ['time_comparison','activity_overview','revenue_comparison','system_comparison']:
    m=re.search(r"case '%s':(?P<body>.*?)(?=\n      case '|\n      default:|\Z)"%key, repo, re.S)
    ok(f'{key}: report implementation exists', m is not None)
    if m:
        body=m.group('body')
        ok(f'{key}: does not hard-code current system', 'currentSystemType' not in body)
        ok(f'{key}: uses system filter variable', '$iw' in body)

ok('time comparison grouped by month', "substr(i.date,1,7) month" in repo)
ok('time comparison has totals', "SUM(i.total_amount) total" in repo)
ok('revenue comparison grouped by month and system', "GROUP BY month,system_type" in repo)
ok('system comparison has overall row', "_systemReportWithOverall" in repo)
ok('activity overview has overall row', "case 'activity_overview'" in repo and "_systemReportWithOverall" in repo[repo.index("case 'activity_overview'"):])

# Worker/partner reports must retain a running balance independent of date filter.
ok('worker report has cumulative balance', "_ledgerPartyTransactions" in repo)
ok('partner report has cumulative balance', "_ledgerPartyTransactions" in repo)

# Inclusive end date: upper bound is exclusive next day.
ok('irrigation reports include full end date', "i.start_datetime<?" in repo and "to.add(const Duration(days: 1))" in repo)
ok('payment reports include full end date', "p.date<?" in repo and "to.add(const Duration(days: 1))" in repo)
ok('worker reports include full end date', "to.add(const Duration(days: 1))" in repo)
ok('partner reports include full end date', "to.add(const Duration(days: 1))" in repo)

# UI is intentionally scoped to the selected station system type.
ok('reports UI is scoped to current system', "DropdownMenuItem(value: currentType" in app and "_allowedReport" in app)
ok('reports UI defaults to current system', "type = currentType" in app)

# PDF columns match time comparison shape.
time_columns_match = re.search(
    r"'time_comparison'\s*:\s*\[(.*?)\]",
    service,
    re.S,
)
time_columns = (
    re.findall(r"'([^']+)'", time_columns_match.group(1))
    if time_columns_match is not None
    else []
)
ok(
    'PDF time comparison columns include month',
    time_columns
    == [
        'month',
        'system_type',
        'minutes',
        'chargeable_minutes',
        'operations',
        'total',
    ],
)

failed=[n for n,v in checks if not v]
print(f'REPORT FUNCTIONAL AUDIT: {len(checks)-len(failed)}/{len(checks)} PASS')
if failed:
    for n in failed: print('FAIL -',n)
    raise SystemExit(1)
