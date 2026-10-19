"""يفحص: (1) تطابق القسمة الصحيحة مع الحساب الكسري الدقيق، (2) استعلامات الانتظار/الأرصدة/الصناديق على SQLite."""
import sqlite3, math, sys, os
from fractions import Fraction
ok = True
def check(name, cond):
    global ok; print(('PASS' if cond else 'FAIL'), name); ok &= bool(cond)

def div_round(n, d, mode):  # نسخة طبق الأصل من AccountingCalculations.divRound
    if n <= 0: return 0
    if mode == 'up': return (n + d - 1) // d
    if mode == 'down': return n // d
    return (2 * n + d) // (2 * d)

bad = 0
for m in range(1, 1500):
    for r in (100, 150, 200, 250, 300, 350, 400, 450, 500, 600, 700, 1000, 1200, 6000):
        exact = Fraction(m * r, 60)
        if div_round(m * r, 60, 'up') != math.ceil(exact): bad += 1
        if div_round(m * r, 60, 'down') != math.floor(exact): bad += 1
        if div_round(m * r, 60, 'nearest') != math.floor(exact + Fraction(1, 2)): bad += 1
check('divRound == exact rational rounding (no float errors)', bad == 0)
old_bad = sum(1 for m in range(1, 600) for r in (100,200,250,300,350,450,600) if math.ceil(m/60*r) != math.ceil(Fraction(m*r,60)))
print('   (old float method wrong in', old_bad, 'cases in this range)')
check('23 min x 300 up = 115', div_round(23*300, 60, 'up') == 115)
check('90 min, 4 L/h, 1000/L fuel = 6000', div_round(90*4000*1000, 60000, 'nearest') == 6000)

db = sqlite3.connect(':memory:')
for st in open('assets/db/001_initial.sql', encoding='utf8').read().split(';'):
    if st.strip(): db.execute(st)
db.commit(); db.execute('PRAGMA foreign_keys=OFF')
db.execute("insert into beneficiaries(name,created_at,updated_at) values('a','x','x')")
def irr(start, status='posted'):
    db.execute("insert into irrigations(station_id,pump_id,beneficiary_id,party_type,date,start_datetime,end_datetime,minutes,system_type,chargeable_minutes,water_amount,diesel_amount,total_amount,paid_amount,status,created_at,updated_at) values(1,1,1,'beneficiary','d',?,?,60,'diesel',60,0,0,0,0,?,'x','x')", (start, start, status))
irr('2026-10-01T08:00:00'); irr('2026-10-10T08:00:00')
PREV = "SELECT MAX(start_datetime) FROM irrigations WHERE beneficiary_id=? AND status!='cancelled' AND start_datetime<=?"
NEXT = "SELECT MIN(start_datetime) FROM irrigations WHERE beneficiary_id=? AND status!='cancelled' AND start_datetime>?"
def gap_ok(start, min_days=3):
    from datetime import datetime
    s = datetime.fromisoformat(start)
    p = db.execute(PREV, (1, start)).fetchone()[0]; n = db.execute(NEXT, (1, start)).fetchone()[0]
    e = 10**9
    if p: e = (s - datetime.fromisoformat(p)).days
    if n: e = min(e, (datetime.fromisoformat(n) - s).days)
    return e >= min_days
check('backdated entry between two irrigations (Oct 5) is allowed', gap_ok('2026-10-05T08:00:00'))
check('entry 1 day before a later irrigation is blocked', not gap_ok('2026-10-09T08:00:00'))
check('entry 1 day after an earlier irrigation is blocked', not gap_ok('2026-10-02T08:00:00'))
from datetime import datetime as _dt
_old_max = db.execute("SELECT MAX(start_datetime) FROM irrigations WHERE beneficiary_id=1 AND status!='cancelled'").fetchone()[0]
check('old MAX-only logic wrongly blocked Oct 5 (negative elapsed)', (_dt.fromisoformat('2026-10-05T08:00:00') - _dt.fromisoformat(_old_max)).days < 3)

# أرصدة العمال/الشركاء: دفتر الأستاذ المركزي هو المصدر الوحيد.
db.execute("insert into accounts(id,code,name,type) values(21,'2100','مستحقات العمال','liability'),(22,'2200','مستحقات الشركاء','liability')")
db.execute("insert into workers(id,name,pay_type,opening_balance,carried_balance) values(1,'w','fixed',0,0)")
db.execute("insert into partners(id,name,ownership_mode,opening_balance,carried_balance) values(1,'p','shares',0,0)")
def post(eid, code, party_col, party_id, debit, credit):
    db.execute("insert into journal_entries(id,date,description,status,created_at) values(?,?,?,?,?)",(eid,'d','test','posted','d'))
    db.execute("insert into journal_lines(journal_entry_id,account_id,"+party_col+",debit,credit) values(?,?,?,?,?)",(eid,21 if code=='2100' else 22,party_id,debit,credit))
post(1,'2100','worker_id',1,0,1500); post(2,'2100','worker_id',1,300,0)
q = "SELECT COALESCE(SUM(jl.credit-jl.debit),0) FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE a.code='2100' AND jl.worker_id=? AND je.status='posted'"
check('worker ledger balance = 1500-300 = 1200', db.execute(q,(1,)).fetchone()[0] == 1200)
post(3,'2200','partner_id',1,0,700)
q2 = "SELECT COALESCE(SUM(jl.credit-jl.debit),0) FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE a.code='2200' AND jl.partner_id=? AND je.status='posted'"
check('partner ledger balance = 700', db.execute(q2,(1,)).fetchone()[0] == 700)
# حساب الصندوق
db.execute("insert into cashboxes(name) values('نقد'),('بنك')")
db.execute("insert into payment_methods(name,type,cashbox_id,ledger_account_code,active) values('نقد','cash',1,NULL,1),('بنك','bank_transfer',2,NULL,1)")
CB = "SELECT ledger_account_code,type FROM payment_methods WHERE cashbox_id=? AND active=1 ORDER BY id LIMIT 1"
def code(cb):
    r = db.execute(CB, (cb,)).fetchone()
    if not r: return '1000'
    if r[0]: return r[0]
    return {'bank_transfer': '1100', 'wallet': '1120'}.get(r[1], '1000')
check('cash box -> 1000, bank box -> 1100, unknown -> 1000', (code(1), code(2), code(9)) == ('1000', '1100', '1000'))
print('ALL OK' if ok else 'SOME FAILED'); sys.exit(0 if ok else 1)
