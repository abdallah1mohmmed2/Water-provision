"""Static audit: queue/booking/session links must belong to the irrigated beneficiary,
and dropdowns must never receive a value that is absent from their items."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'lib/features/app.dart').read_text(encoding='utf-8')
SVC = (ROOT / 'lib/domain/accounting/accounting_service.dart').read_text(encoding='utf-8')
checks = []
def check(n, c): checks.append((n, bool(c)))

check('service rejects links for worker/partner', "partyType != 'beneficiary' &&\n        (queueId != null || bookingId != null || sessionId != null)" in SVC)
check('service: queue belongs to beneficiary', "if (q.first['beneficiary_id'] != beneficiaryId)" in SVC)
check('service: queue must be open', "['waiting', 'postponed'].contains('${q.first['status']}')" in SVC)
check('service: booking belongs to beneficiary', "if (bk.first['beneficiary_id'] != beneficiaryId)" in SVC)
check('service: booking must be open', "'new', 'under_review', 'scheduled', 'accepted', 'notified'" in SVC)
check('service: session belongs to beneficiary', "if (sess.first['beneficiary_id'] != beneficiaryId)" in SVC)
check('UI: no unscoped queue list (bid == null shows all)', "bid == null || x['beneficiary_id'] == bid" not in APP)
check('UI: links scoped to selected beneficiary', all(k in APP for k in ['List<Map<String, Object?>> get linkQueue', 'get linkBookings', 'get linkSessions']))
check('UI: only running sessions offered', "x['status'] == 'running'" in APP)
check('UI: stale links dropped on party/beneficiary change', APP.count('_dropStaleLinks();') >= 4)
check('UI: links not sent for non-beneficiary', "queueId: canLink ? queueId : null" in APP)
check('UI: lists refreshed after save', "await _refreshAfterSave();" in APP)
check('fieldSelect guards value not in items', "items.where((i) => i.value == value).length == 1 ? value : null" in APP)
check('selected party kept in filtered dropdown items', APP.count("keepSelected(x,") >= 3)
fails = [n for n, c in checks if not c]
for n, c in checks: print('PASS' if c else 'FAIL', '-', n)
print(f'Link ownership audit: {len(checks)-len(fails)}/{len(checks)} PASS')
raise SystemExit(1 if fails else 0)
