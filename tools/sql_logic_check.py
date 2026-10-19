import sqlite3,re,sys
db=sqlite3.connect(':memory:'); db.execute('PRAGMA foreign_keys=OFF')
for st in open('./assets/db/001_initial.sql',encoding='utf8').read().split(';'):
    if st.strip(): db.execute(st)
db.commit(); db.execute('PRAGMA foreign_keys=OFF')
src=open('./lib/domain/accounting/accounting_service.dart',encoding='utf8').read()
stock=''.join(re.findall(r'"((?:[^"\\]|\\.)*)"',re.search(r"_beneficiaryDieselStockSql =(.*?);",src,re.S).group(1)))
ok=True
def check(name,cond):
    global ok; print(('PASS' if cond else 'FAIL'),name); ok&=bool(cond)
db.execute("insert into beneficiaries(name,opening_diesel_liters,carried_diesel_liters,created_at,updated_at) values('a',2,1,'x','x')")
def mv(kind,l,irr=None): db.execute("insert into diesel_movements(beneficiary_id,irrigation_id,kind,liters,unit_price,amount,date) values(1,?,?,?,100,?,'d')",(irr,kind,l,round(l*100)))
mv('delivery',4)
check('stock = 2+1+4 = 7',db.execute(stock,(1,1,1)).fetchone()[0]==7)
# scenario: irrigation uses 10 L -> shortage 3 -> advance 3 + consumption 10 -> stock must be 0 (not -3)
mv('advance',3,5); mv('consumption',10,5)
check('after auto-advance stock = 0 (no compounding)',db.execute(stock,(1,1,1)).fetchone()[0]==0)
# second irrigation 10 L: shortage must be 10, not 13
avail=db.execute(stock,(1,1,1)).fetchone()[0]; check('second shortage = 10',max(10-avail,0)==10)
# balance query: auto-advance excluded, manual included
mv('advance',5,None)
q="SELECT COALESCE((SELECT SUM(amount) FROM diesel_movements WHERE beneficiary_id=1 AND kind='advance' AND irrigation_id IS NULL),0)"
check('balance advances count manual only (500)',db.execute(q).fetchone()[0]==500)
# journal reversal
for c,t in (('1200','asset'),('4000','revenue'),('1000','asset')): db.execute("insert into accounts(code,name,type) values(?,?,?)",(c,c,t))
def entry(ref,rid,lines,desc='e'):
    cur=db.execute("insert into journal_entries(date,reference_type,reference_id,description,status,created_at) values('d',?,?,?,'posted','d')",(ref,rid,desc)); eid=cur.lastrowid
    for a,d,c in lines: db.execute("insert into journal_lines(journal_entry_id,account_id,debit,credit) values(?,?,?,?)",(eid,a,d,c))
    return eid
e=entry('irrigation',9,[(1,1000,0),(2,0,1000)]); entry('irrigation',9,[(3,300,0),(1,0,300)],'pay')
sel=("SELECT je.id FROM journal_entries je WHERE je.reference_type=? AND je.reference_id=? AND je.status='posted' "
     "AND NOT EXISTS (SELECT 1 FROM journal_entries r WHERE r.reference_type='reversal' AND r.reference_id=je.id)")
ids=[r[0] for r in db.execute(sel,('irrigation',9))]; check('finds 2 entries to reverse',len(ids)==2)
for i in ids:
    r=entry('reversal',i,[(l[0],l[2],l[1]) for l in db.execute("select account_id,debit,credit from journal_lines where journal_entry_id=?",(i,))])
check('second cancel finds nothing (idempotent)',db.execute(sel,('irrigation',9)).fetchall()==[])
tot=db.execute("select account_id,sum(debit)-sum(credit) from journal_lines group by account_id order by 1").fetchall()
check('all accounts net to zero after reversal',all(t[1]==0 for t in tot))
check('journal balanced',db.execute("select sum(debit)-sum(credit) from journal_lines").fetchone()[0]==0)
# worker payment direction: Dr 2100 / Cr cash, cashbox decreases
print('ALL OK' if ok else 'SOME FAILED'); sys.exit(0 if ok else 1)
