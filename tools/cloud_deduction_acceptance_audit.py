from pathlib import Path
import sqlite3, tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT/'lib/features/app.dart').read_text()
ACCT = (ROOT/'lib/domain/accounting/accounting_service.dart').read_text()
DB = (ROOT/'lib/data/local/database.dart').read_text()
SQL = (ROOT/'assets/db/001_initial.sql').read_text()
errors=[]
def check(ok,msg):
    if ok: print('PASS:',msg)
    else: errors.append(msg); print('FAIL:',msg)

check('final List<Map<String, DateTime>> cloudPeriods' in APP, 'واجهة السقاية تدعم قائمة فترات غيم متعددة')
check("'إضافة فترة غيم'" in APP and "'بداية الغيم'" in APP and "'نهاية الغيم'" in APP, 'فترة الغيم تُدخل من وإلى')
check("cloudPeriods.map" in APP and "cloudPeriods: cloudPeriods" in APP, 'الفترات تنتقل من الواجهة إلى طبقة التسجيل')
check('cloud_periods' in ACCT and "tx.insert('cloud_periods'" in ACCT, 'الفترات تُحفظ مرتبطة برقم السقاية')
check("FOREIGN KEY" in SQL.upper() or 'REFERENCES irrigations(id) ON DELETE CASCADE' in SQL, 'فترة الغيم مرتبطة بالسقاية بمفتاح أجنبي مع الحذف التلقائي')
check('start_datetime TEXT NOT NULL' in SQL and 'end_datetime TEXT NOT NULL' in SQL, 'كل فترة تحفظ من وإلى')
check('لا يجوز أن تتداخل' in ACCT and 'إجمالي خصم الغيم لا يمكن أن يتجاوز مدة السقاية' in ACCT, 'الطبقة المحاسبية تمنع التداخل والتجاوز')
check("if (effectiveType == 'solar' && cloudPeriods.isNotEmpty)" in ACCT, 'خصم الغيم يطبق على الشمسي فقط')
check('cloud_minutes' in SQL and 'chargeable_minutes' in SQL, 'المحصلة المحاسبية للسقاية محفوظة')
check('version: 12' in DB and 'oldV < 11' in DB, 'ترقية قاعدة البيانات إلى مخطط فترات الغيم موجودة')

# Execute the initial schema in an isolated SQLite database.
conn=sqlite3.connect(':memory:')
try:
    conn.execute('PRAGMA foreign_keys=ON')
    for st in SQL.split(';'):
        st=st.strip()
        if st: conn.execute(st)
    tables={r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    check('cloud_periods' in tables, 'مخطط SQLite الأولي يحتوي جدول cloud_periods')
    conn.execute("INSERT INTO stations VALUES (1,'محطة اختبار','','',1,'2026-10-02','2026-10-02')")
    conn.execute("INSERT INTO pumps VALUES (1,1,'مضخة شمسية','solar',1,'')")
    conn.execute("INSERT INTO beneficiaries VALUES (1,1,'مستفيد اختبار','','','','','','active',0,0,0,0,0,'','2026-10-02','2026-10-02')")
    conn.execute("INSERT INTO irrigations (id,station_id,pump_id,beneficiary_id,party_type,date,start_datetime,end_datetime,minutes,system_type,chargeable_minutes,status,created_at,updated_at) VALUES (1,1,1,1,'beneficiary','2026-10-02','2026-10-02T08:00:00','2026-10-02T10:00:00',120,'solar',90,'posted','2026-10-02','2026-10-02')")
    conn.execute("INSERT INTO cloud_periods (irrigation_id,start_datetime,end_datetime,minutes,created_at) VALUES (1,'2026-10-02T08:20:00','2026-10-02T08:50:00',30,'2026-10-02')")
    conn.execute("INSERT INTO cloud_periods (irrigation_id,start_datetime,end_datetime,minutes,created_at) VALUES (1,'2026-10-02T09:10:00','2026-10-02T09:40:00',30,'2026-10-02')")
    row=conn.execute("SELECT COUNT(*),SUM(minutes),MIN(start_datetime),MAX(end_datetime) FROM cloud_periods WHERE irrigation_id=1").fetchone()
    check(row==(2,60,'2026-10-02T08:20:00','2026-10-02T09:40:00'), 'SQLite يحفظ فترتين منفصلتين لنفس السقاية')
    conn.execute('DELETE FROM irrigations WHERE id=1')
    check(conn.execute('SELECT COUNT(*) FROM cloud_periods').fetchone()[0]==0, 'حذف السقاية يحذف فترات الغيم المرتبطة بها')
finally:
    conn.close()

print(f'\nCloud deduction acceptance: {0 if not errors else len(errors)} failure(s)')
raise SystemExit(1 if errors else 0)
