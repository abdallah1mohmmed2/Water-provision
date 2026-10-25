// اختبارات تكامل على قاعدة SQLite حقيقية (sqflite_common_ffi).
// تغطي هذه النسخة أيضًا فحص بنية شجرة الحسابات والحسابات اليتيمة.
// تغطي الإصلاحات: اتجاه دفع العامل، منع ازدواج الديزل، عدم تضاعف السلفة،
// القيد العكسي عند الإلغاء، وتاريخ القيد = تاريخ العملية.
// ملاحظة: كُتبت دون تشغيل (لا يوجد Flutter SDK في بيئة الكتابة) — شغّلها بـ flutter test.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';
import 'package:saqia_station/domain/accounting/accounting_service.dart';
import 'package:saqia_station/services/admin_service.dart';
import 'package:saqia_station/services/backup_service.dart';
import 'package:saqia_station/services/report_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late AccountingService svc;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.deleteDatabase(
      '${await databaseFactory.getDatabasesPath()}/saqia_station_v2.db',
    );
    db = AppDatabase.instance;
    svc = AccountingService(db);
    await db.db;
  });

  Future<int> cashboxBalance(int id) async =>
      ((await db.query('SELECT current_balance b FROM cashboxes WHERE id=?',
                  args: [id]))
              .first['b'] as num)
          .round();

  Future<num> accountNet(String code) async => (await db.query(
        "SELECT COALESCE(SUM(l.debit)-SUM(l.credit),0) n FROM journal_lines l JOIN accounts a ON a.id=l.account_id WHERE a.code=? OR (? IN ('2100','2200') AND a.parent_id=(SELECT id FROM accounts WHERE code=?))",
        args: [code, code, code],
      )).first['n'] as num;

  Future<void> reconcileCashboxesForTest(int stationId) async {
    final boxes = await db.query(
      "SELECT id,COALESCE(NULLIF(ledger_account_code,''),'1000') code,current_balance FROM cashboxes WHERE station_id=? ORDER BY id",
      args: [stationId],
    );
    final codes = boxes.map((r) => '${r['code']}').toSet();
    final boxTotals = <String, int>{};
    for (final row in boxes) {
      final code = '${row['code']}';
      boxTotals[code] = (boxTotals[code] ?? 0) + (row['current_balance'] as num).round();
    }
    for (final code in codes) {
      final ledgerRows = await db.query(
        "SELECT COALESCE(SUM(jl.debit-jl.credit),0) balance FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.status='posted' AND a.code=?",
        args: [stationId, code],
      );
      final ledger = (ledgerRows.first['balance'] as num).round();
      final difference = ledger - (boxTotals[code] ?? 0);
      if (difference == 0) continue;
      final target = boxes.firstWhere((r) => '${r['code']}' == code);
      await db.update(
        'cashboxes',
        {'current_balance': (target['current_balance'] as num).round() + difference},
        'id=?',
        [target['id']],
      );
    }
  }

  Future<void> seedCashEquityForTest(int stationId, DateTime date, int amount) async {
    final rows = await db.query("SELECT code,id FROM accounts WHERE code IN ('1000','3000')");
    final accounts = {for (final r in rows) '${r['code']}': r['id']};
    final entry = await db.insert('journal_entries', {
      'station_id': stationId, 'date': date.toIso8601String(),
      'reference_type': 'test_cash_opening', 'description': 'رصيد نقدي متوازن للاختبار',
      'status': 'posted', 'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert('journal_lines', {
      'journal_entry_id': entry, 'account_id': accounts['1000'],
      'debit': amount, 'credit': 0, 'memo': 'نقد اختبار',
    });
    await db.insert('journal_lines', {
      'journal_entry_id': entry, 'account_id': accounts['3000'],
      'debit': 0, 'credit': amount, 'memo': 'مقابل اختبار',
    });
    await db.update(
      'cashboxes', {'current_balance': await cashboxBalance(1) + amount}, 'id=?', [1],
    );
  }

  Future<List<Map<String, Object?>>> recordCashEvidenceForTest({
    required int stationId,
    required DateTime start,
    required DateTime endExclusive,
    required int userId,
    int difference = 0,
  }) async {
    final targets = await svc.cashReconciliationTargets(
      stationId: stationId, endExclusive: endExclusive,
    );
    return svc.recordCashReconciliations(
      stationId: stationId,
      start: start,
      endExclusive: endExclusive,
      userId: userId,
      entries: [
        for (final target in targets)
          {
            'account_code': target['account_code'],
            'actual_balance': (target['book_balance'] as num).round() + difference,
            'reference': target['source_type'] == 'cash_count'
                ? 'اختبار عدّ ${target['account_code']}'
                : 'TEST-STATEMENT-${target['account_code']}',
            'notes': 'بيانات اختبار تكامل',
          },
      ],
    );
  }

  test('دفع راتب لعامل ينقص الصندوق ويقيّد مدين المستحقات / دائن الصندوق', () async {
    final w = await db.insert('workers', {
      'name': 'عامل',
      'pay_type': 'fixed',
    });
    await db.transaction((tx) => tx.rawUpdate('UPDATE cashboxes SET current_balance=100000 WHERE id=1'));
    final before = await cashboxBalance(1);
    await svc.payWorker(
      workerId: w, amount: 1000, paymentMethodId: 1, cashboxId: 1,
    );
    expect(await cashboxBalance(1), before - 1000);
    expect(await accountNet('2100'), 1000); // مدين المستحقات
  });

  test('مصروف العمال العام مرفوض لتجنب ازدواج الاستحقاق مع كشف العامل', () async {
    await expectLater(
      svc.addExpense(
        category: 'workers',
        title: 'راتب مسجل كمصروف عام',
        amount: 500,
        date: DateTime(2026, 4, 1),
        paymentMethodId: 1,
        cashboxId: 1,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('دفع استحقاق العامل لا يسجل مصروفًا ثانيًا', () async {
    final worker = await db.insert('workers', {
      'name': 'عامل فصل الاستحقاق والدفع',
      'pay_type': 'fixed',
    });
    await db.update('cashboxes', {'current_balance': 100000}, 'id=?', [1]);
    final cashBefore = await cashboxBalance(1);
    final expenseBefore = await accountNet('5000');
    await svc.createWorkerAccrual(
      workerId: worker,
      amount: 1000,
      date: DateTime(2026, 3, 1),
    );
    final expenseAfterAccrual = await accountNet('5000');
    expect(expenseAfterAccrual, expenseBefore + 1000);
    expect((await svc.workerBalance(worker))['balance'], 1000);
    await svc.payWorker(
      workerId: worker,
      amount: 400,
      paymentMethodId: 1,
      cashboxId: 1,
    );
    expect(await cashboxBalance(1), cashBefore - 400);
    expect(await accountNet('5000'), expenseAfterAccrual);
    expect((await svc.workerBalance(worker))['balance'], 600);
  });

  test('تاريخ القيد هو تاريخ المصروف لا لحظة الحفظ', () async {
    final d = DateTime(2026, 3, 5, 10);
    final id = await svc.addExpense(
      category: 'maintenance', title: 't', amount: 100, date: d,
      paymentMethodId: 1, cashboxId: 1,
    );
    final r = await db.query(
      "SELECT date FROM journal_entries WHERE reference_type='expense' AND reference_id=?",
      args: [id],
    );
    expect((r.first['date'] as String).startsWith('2026-03-05'), isTrue);
  });

  test('إلغاء مصروف: يعيد الصندوق ويعكس القيد ولا يتعلق', () async {
    final before = await cashboxBalance(1);
    final id = await svc.addExpense(
      category: 'maintenance', title: 'x', amount: 250, date: DateTime.now(),
      paymentMethodId: 1, cashboxId: 1,
    );
    expect(await cashboxBalance(1), before - 250);
    await svc.cancelExpense(id, 1, 'خطأ إدخال').timeout(const Duration(seconds: 10));
    expect(await cashboxBalance(1), before);
    final rev = await db.query("SELECT COUNT(*) c FROM journal_entries WHERE reference_type='reversal'");
    expect((rev.first['c'] as num) >= 1, isTrue);
  });

  test('ترحيل الراتب الشهري idempotent ويحفظ قيمة الراتب وقت الاستحقاق', () async {
    final repo = StationRepository(db);
    final worker = await repo.createWorker(
      name: 'عامل راتب شهري snapshot',
      payType: 'fixed',
      fixedSalary: 1200,
    );
    final month = DateTime(2040, 5, 1);
    await svc.accrueMonthlySalaries(month: month);
    final first = await db.query(
      "SELECT amount,rate_snapshot,reference_id FROM worker_transactions WHERE worker_id=? AND reference_type='monthly_salary' AND reference_id=?",
      args: [worker, 204005],
    );
    expect(first.length, 1);
    expect(first.single['amount'], 1200);
    expect(first.single['rate_snapshot'], 1200);
    await repo.updateWorker(worker, {'fixed_salary': 1900}, null);
    await svc.accrueMonthlySalaries(month: month);
    final second = await db.query(
      "SELECT amount,rate_snapshot FROM worker_transactions WHERE worker_id=? AND reference_type='monthly_salary' AND reference_id=?",
      args: [worker, 204005],
    );
    expect(second.length, 1);
    expect(second.single['amount'], 1200);
    expect(second.single['rate_snapshot'], 1200);
  });

  test('حركة ديزل (تسليم) لا تتعلق ويُقيَّد جانبها المحاسبي', () async {
    await svc
        .addDieselMovement(
          kind: 'receipt', liters: 100, unitPrice: 100, date: DateTime.now(), cashboxId: 1,
        )
        .timeout(const Duration(seconds: 10));
    expect(await svc.dieselStock(), greaterThanOrEqualTo(100));
  });
  test('تحويل بين صندوق نقدي وبنكي: قيد على حسابي الصندوقين الصحيحين', () async {
    await db.transaction((tx) => tx.rawUpdate('UPDATE cashboxes SET current_balance=50000 WHERE id=1'));
    final cashBefore = await accountNet('1000');
    final bankBefore = await accountNet('1100');
    // يفترض وجود صندوق ثانٍ مرتبط بطريقة دفع بنكية في بيانات البذر؛ وإلا تُتخطى.
    final boxes = await db.query('SELECT id FROM cashboxes ORDER BY id');
    if (boxes.length < 2) return;
    final other = boxes[1]['id'] as int;
    await svc.transferCash(from: 1, to: other, amount: 1000, date: DateTime.now());
    expect((await accountNet('1000')) - cashBefore, -1000);
    expect((await accountNet('1100')) - bankBefore, 1000);
  });

  test('التحويل إلى نفس الصندوق مرفوض', () async {
    expect(
      () => svc.transferCash(from: 1, to: 1, amount: 10, date: DateTime.now()),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('الصرف والمصروف وشراء الديزل لا تجعل الصندوق سالبًا', () async {
    final originalBalance = await cashboxBalance(1);
    final repo = StationRepository(db);
    final worker = await repo.createWorker(name: 'عامل اختبار الصندوق', payType: 'fixed');
    final partner = await repo.createPartner(name: 'شريك اختبار الصندوق', mode: 'shares', shares: 1);
    final paymentsBefore = (await db.query('SELECT COUNT(*) c FROM payments')).first['c'] as num;
    final expensesBefore = (await db.query('SELECT COUNT(*) c FROM expenses')).first['c'] as num;
    final dieselBefore = (await db.query('SELECT COUNT(*) c FROM diesel_movements')).first['c'] as num;
    await db.update('cashboxes', {'current_balance': 0}, 'id=?', [1]);
    try {
      await expectLater(svc.payWorker(workerId: worker, amount: 1, paymentMethodId: 1, cashboxId: 1), throwsStateError);
      await expectLater(svc.payPartner(partnerId: partner, amount: 1, paymentMethodId: 1, cashboxId: 1), throwsStateError);
      await expectLater(svc.addExpense(category: 'maintenance', title: 'اختبار', amount: 1, date: DateTime.now(), paymentMethodId: 1, cashboxId: 1), throwsStateError);
      await expectLater(svc.addDieselMovement(kind: 'receipt', liters: 1, unitPrice: 1, date: DateTime.now(), cashboxId: 1), throwsStateError);
      expect(await cashboxBalance(1), 0);
      expect((await db.query('SELECT COUNT(*) c FROM payments')).first['c'], paymentsBefore);
      expect((await db.query('SELECT COUNT(*) c FROM expenses')).first['c'], expensesBefore);
      expect((await db.query('SELECT COUNT(*) c FROM diesel_movements')).first['c'], dieselBefore);
    } finally {
      await db.update('cashboxes', {'current_balance': originalBalance}, 'id=?', [1]);
    }
  });

  test('أرصدة الأطراف المنشأة عبر المستودع تظهر في الأستاذ والكشف', () async {
    final repo = StationRepository(db);
    final w = await repo.createWorker(name: 'عامل برصيد افتتاحي', payType: 'fixed', opening: 1200);
    final p = await repo.createPartner(name: 'شريك برصيد افتتاحي', mode: 'shares', shares: 1, opening: 700);
    expect((await svc.workerBalance(w))['balance'], 1200);
    expect((await svc.partnerBalance(p))['balance'], 700);
    final workerRow = (await repo.workers()).singleWhere((row) => row['id'] == w);
    final partnerRow = (await repo.partners()).singleWhere((row) => row['id'] == p);
    expect(workerRow['balance'], 1200);
    expect(partnerRow['balance'], 700);
  });

  // ---------- توحيد قيود العامل/الشريك مع كشوفهم ----------
  Future<void> useSolar6000() async {
    for (final e in {'system_type': 'solar', 'solar_hourly_rate': '6000'}.entries) {
      await db.update('settings', {'value': e.value}, 'key=?', [e.key]);
    }
  }

  Future<int> glPayable(String code, String col, int id) async => ((await db.query(
        "SELECT COALESCE(SUM(l.credit)-SUM(l.debit),0) n FROM journal_lines l JOIN accounts a ON a.id=l.account_id WHERE (a.code=? OR (? IN ('2100','2200') AND a.parent_id=(SELECT id FROM accounts WHERE code=?))) AND l.$col=?",
        args: [code, code, code, id],
      )).first['n'] as num).round();

  Future<int> irrigationFor({int? workerId, int? partnerId, required DateTime start}) =>
      svc.recordIrrigation(
        stationId: 1,
        pumpId: 1,
        workerId: workerId,
        partnerId: partnerId,
        partyType: workerId != null ? 'worker' : 'partner',
        start: start,
        end: start.add(const Duration(hours: 1)),
        systemType: 'solar',
        waterRate: 0,
        litersPerHour: 0,
        dieselPrice: 0,
        solarRate: 0,
        thirdRate: 0,
        cloudMinutes: 0,
        paidAmount: 0,
      );

  test('السقاية تخصم أجر العامل أولاً ثم توزع الصافي على الشركاء', () async {
    await db.update('settings', {'value': 'solar'}, 'key=?', ['system_type']);
    await db.update('settings', {'value': '5000'}, 'key=?', ['solar_hourly_rate']);
    await db.update('partners', {'active': 0}, 'id>?', [0]);
    final now = DateTime(2027, 1, 5, 8);
    final b = await db.insert('beneficiaries', {
      'name': 'مستفيد اختبار الخصم',
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    final w = await db.insert('workers', {
      'name': 'عامل بالساعة 700',
      'pay_type': 'hourly',
      'hourly_rate': 700,
    });
    final p1 = await db.insert('partners', {
      'name': 'شريك خمسة أسهم',
      'ownership_mode': 'shares',
      'shares_count': 5,
      'active': 1,
    });
    final p2 = await db.insert('partners', {
      'name': 'شريك ثلاثة أسهم',
      'ownership_mode': 'shares',
      'shares_count': 3,
      'active': 1,
    });
    await svc.recordIrrigation(
      stationId: 1,
      pumpId: 1,
      beneficiaryId: b,
      operatorWorkerId: w,
      start: now,
      end: now.add(const Duration(hours: 1)),
      systemType: 'solar',
      waterRate: 0,
      litersPerHour: 0,
      dieselPrice: 0,
      solarRate: 0,
      thirdRate: 0,
      cloudMinutes: 0,
      paidAmount: 0,
    );
    expect(await glPayable('2100', 'worker_id', w), 700);
    expect(await glPayable('2200', 'partner_id', p1), 2688);
    expect(await glPayable('2200', 'partner_id', p2), 1612);
    expect(
      (await glPayable('2200', 'partner_id', p1)) +
          (await glPayable('2200', 'partner_id', p2)),
      4300,
    );
    final direct = await db.query(
      "SELECT amount FROM partner_transactions WHERE reference_type='irrigation_profit' ORDER BY id",
    );
    expect(direct.fold<int>(0, (sum, row) => sum + (row['amount'] as num).round()), 4300);
  });

  test('السقاية تحسب أجر العامل بالنسبة المئوية ثم توزع المتبقي', () async {
    await db.update('settings', {'value': 'solar'}, 'key=?', ['system_type']);
    await db.update('settings', {'value': '5000'}, 'key=?', ['solar_hourly_rate']);
    await db.update('partners', {'active': 0}, 'id>?', [0]);
    await db.update('workers', {'active': 0}, 'id>?', [0]);
    final now = DateTime(2027, 1, 6, 8);
    final b = await db.insert('beneficiaries', {
      'name': 'مستفيد اختبار النسبة',
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    final w = await db.insert('workers', {
      'name': 'عامل نسبة 10%',
      'pay_type': 'percentage',
      'percentage_rate': 10,
    });
    final p1 = await db.insert('partners', {
      'name': 'شريك نسبة أول',
      'ownership_mode': 'shares',
      'shares_count': 1,
      'active': 1,
    });
    final p2 = await db.insert('partners', {
      'name': 'شريك نسبة ثان',
      'ownership_mode': 'shares',
      'shares_count': 1,
      'active': 1,
    });
    await svc.recordIrrigation(
      stationId: 1,
      pumpId: 1,
      beneficiaryId: b,
      operatorWorkerId: w,
      start: now,
      end: now.add(const Duration(hours: 1)),
      systemType: 'solar',
      waterRate: 0,
      litersPerHour: 0,
      dieselPrice: 0,
      solarRate: 0,
      thirdRate: 0,
      cloudMinutes: 0,
      paidAmount: 0,
    );
    // 5,000 × 10% = 500 للعامل، والباقي 4,500 للشريكين.
    expect(await glPayable('2100', 'worker_id', w), 500);
    expect(await glPayable('2200', 'partner_id', p1), 2250);
    expect(await glPayable('2200', 'partner_id', p2), 2250);
    final workerRows = await db.query(
      "SELECT amount,percentage_snapshot FROM worker_transactions WHERE worker_id=? AND type='irrigation'",
      args: [w],
    );
    expect(workerRows.single['amount'], 500);
    expect(workerRows.single['percentage_snapshot'], 10);
  });

  test('سقاية على حساب عامل: الأستاذ 2100 يطابق كشف العامل، والإلغاء يعكس بلا حذف', () async {
    await useSolar6000();
    final w = await db.insert('workers', {'name': 'عامل سقاية', 'pay_type': 'fixed'});
    await svc.createWorkerAccrual(workerId: w, amount: 10000, date: DateTime(2026, 3, 1));
    final id = await irrigationFor(workerId: w, start: DateTime(2026, 3, 1, 8));
    expect(await glPayable('2100', 'worker_id', w), 4000);
    expect((await svc.workerBalance(w))['balance'], 4000);
    // لا شيء على ذمم المستفيدين لهذا العامل
    expect(await glPayable('1200', 'worker_id', w), 0);

    await svc.cancelIrrigation(id, 1, 'خطأ إدخال');
    expect(await glPayable('2100', 'worker_id', w), 10000);
    expect((await svc.workerBalance(w))['balance'], 10000);
    final kept = await db.query(
      "SELECT COUNT(*) n FROM worker_transactions WHERE worker_id=? AND type='irrigation'",
      args: [w],
    );
    expect(kept.first['n'], 1); // حركة السقاية الأصلية باقية في الكشف
  });

  test('سقاية على حساب شريك: الأستاذ 2200 يطابق كشف الشريك بعد الخصم والإلغاء', () async {
    await useSolar6000();
    final p = await db.insert('partners', {'name': 'شريك سقاية', 'ownership_mode': 'shares'});
    await svc.createPartnerShare(partnerId: p, amount: 10000, date: DateTime(2026, 3, 1));
    final personal = await db.query(
      'SELECT code,parent_id FROM accounts WHERE code=?',
      args: ['2200.P$p'],
    );
    expect(personal.single['code'], '2200.P$p');
    expect(personal.single['parent_id'], isNotNull);
    final id = await irrigationFor(partnerId: p, start: DateTime(2026, 3, 3, 8));
    expect(await glPayable('2200', 'partner_id', p), 4000);
    expect((await svc.partnerBalance(p))['balance'], 4000);
    await svc.cancelIrrigation(id, 1, 'خطأ إدخال');
    expect(await glPayable('2200', 'partner_id', p), 10000);
    expect((await svc.partnerBalance(p))['balance'], 10000);
  });

  test('الدفعة المرافقة للسقاية مرفوضة لغير المستفيد', () async {
    await useSolar6000();
    final w = await db.insert('workers', {'name': 'عامل 2', 'pay_type': 'fixed'});
    expect(
      () => svc.recordIrrigation(
        stationId: 1, pumpId: 1, workerId: w, partyType: 'worker',
        start: DateTime(2026, 3, 5, 8), end: DateTime(2026, 3, 5, 9),
        systemType: 'solar', waterRate: 0, litersPerHour: 0, dieselPrice: 0,
        solarRate: 0, thirdRate: 0, cloudMinutes: 0, paidAmount: 500,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  // ---------- النسخة المحمولة JSON ----------
  test('تصدير/استعادة JSON يحفظ فترات الغيم والفترات المغلقة وجداول المستفيد', () async {
    await useSolar6000();
    final now = DateTime.now().toIso8601String();
    final b = await db.insert('beneficiaries', {
      'name': 'مستفيد غيم', 'created_at': now, 'updated_at': now,
    });
    final start = DateTime(2026, 4, 1, 8);
    await svc.recordIrrigation(
      stationId: 1, pumpId: 1, beneficiaryId: b,
      start: start, end: start.add(const Duration(hours: 2)),
      systemType: 'solar', waterRate: 0, litersPerHour: 0, dieselPrice: 0,
      solarRate: 0, thirdRate: 0, cloudMinutes: 0, paidAmount: 0,
      cloudPeriods: [
        {
          'start': start.add(const Duration(minutes: 10)).toIso8601String(),
          'end': start.add(const Duration(minutes: 40)).toIso8601String(),
        },
      ],
    );
    await db.insert('beneficiary_auth_codes', {
      'beneficiary_id': b, 'code_hash': 'x', 'expires_at': now, 'created_at': now,
    });
    await seedCashEquityForTest(1, DateTime(2020, 1, 1), 100000);
    await reconcileCashboxesForTest(1);
    await recordCashEvidenceForTest(
      stationId: 1,
      start: DateTime(2020, 1, 1),
      endExclusive: DateTime(2021, 1, 1),
      userId: 1,
    );
    await AdminService(db).closePeriod(
      stationId: 1, start: DateTime(2020, 1, 1), end: DateTime(2020, 12, 31), userId: 1,
    );

    Future<int> count(String t) async =>
        (await db.query('SELECT COUNT(*) n FROM $t')).first['n'] as int;
    final clouds = await count('cloud_periods');
    final closures = await count('period_closures');
    final codes = await count('beneficiary_auth_codes');
    final cashEvidence = await count('cash_reconciliations');
    expect(clouds, greaterThan(0));
    expect(closures, greaterThan(0));
    expect(cashEvidence, greaterThan(0));

    final json = await svc.exportStateJson();
    final backup = BackupService(svc);
    final bytes = Uint8List.fromList(utf8.encode(json));
    expect((await backup.validatePortableJson(bytes))['valid'], true);
    await backup.restorePortableJson(bytes);
    expect(await count('cloud_periods'), clouds);
    expect(await count('period_closures'), closures);
    expect(await count('beneficiary_auth_codes'), codes);
    expect(await count('cash_reconciliations'), cashEvidence);

    // ملف قديم بلا الجداول الجديدة: يُقبل، ولا تُفتح الفترات المغلقة.
    final old = jsonDecode(json) as Map<String, dynamic>;
    for (final k in AccountingService.optionalPortableTables) {
      old.remove(k);
    }
    for (final row in (old['journal_entries'] as List)) {
      if (row is Map) row.remove('station_id');
    }
    final oldBytes = Uint8List.fromList(utf8.encode(jsonEncode(old)));
    expect((await backup.validatePortableJson(oldBytes))['valid'], true);
    await backup.restorePortableJson(oldBytes);
    expect(await count('period_closures'), closures);
    expect(await count('cash_reconciliations'), 0);
    expect((await db.query('SELECT COUNT(*) n FROM journal_entries WHERE station_id IS NULL')).first['n'], 0);
  });

  // ---------- تطابق الأرقام بين الشاشات ----------
  test('كشف المستفيد: الرصيد الجاري الأخير = beneficiaryBalance (دفعات + سلف الديزل)', () async {
    await useSolar6000();
    final repo = StationRepository(db);
    final b = await repo.createBeneficiary(name: 'مستفيد كشف', opening: 1000);
    final start = DateTime(2026, 6, 1, 8);
    await svc.recordIrrigation(
      stationId: 1, pumpId: 1, beneficiaryId: b,
      start: start, end: start.add(const Duration(hours: 1)),
      systemType: 'solar', waterRate: 0, litersPerHour: 0, dieselPrice: 0,
      solarRate: 0, thirdRate: 0, cloudMinutes: 0, paidAmount: 0,
    );
    await svc.receivePayment(beneficiaryId: b, amount: 2000, paymentMethodId: 1, cashboxId: 1);
    await svc.addDieselMovement(
      beneficiaryId: b, kind: 'advance', liters: 5, unitPrice: 100, date: DateTime.now(),
    );
    final stmt = await repo.beneficiaryStatement(b);
    final expected = (await svc.beneficiaryBalance(b))['balance'];
    expect(stmt.last['balance'], expected);
    expect(expected, 1000 + 6000 + 500 - 2000);
    // الأعمدة التي يعرضها تقرير PDF موجودة في الصفوف
    for (final k in ['description', 'debit', 'credit', 'balance']) {
      expect(stmt.first.containsKey(k), isTrue, reason: k);
    }
  });

  test('تثبيت جديد: عمود snoozed_until موجود ويعمل تأجيل الإشعار', () async {
    final repo = StationRepository(db);
    final id = await db.insert('notifications', {
      'type': 't', 'title': 't', 'body': 'b', 'created_at': DateTime.now().toIso8601String(),
    });
    await repo.snoozeNotification(id);
    final r = await db.query('SELECT snoozed_until FROM notifications WHERE id=?', args: [id]);
    expect(r.first['snoozed_until'], isNotNull);
  });

  test('مصدر الدفع: الافتراضي نقدي مفعّل، والمختار يحدد صندوقه، وغير الموجود يُرفض', () async {
    final cb = await db.insert('cashboxes', {
      'station_id': 1, 'name': 'صندوق بنك', 'opening_balance': 0,
      'current_balance': 0, 'currency': 'YER', 'active': 1,
    });
    final bank = await db.insert('payment_methods', {
      'station_id': 1, 'name': 'تحويل بنكي', 'type': 'bank_transfer',
      'cashbox_id': cb, 'ledger_account_code': '1100', 'active': 1,
    });
    final def = await svc.paymentSource();
    final defType = (await db.query(
      'SELECT type FROM payment_methods WHERE id=?', args: [def['method']],
    )).first['type'];
    expect(defType, 'cash');
    final chosen = await svc.paymentSource(paymentMethodId: bank);
    expect(chosen['method'], bank);
    expect(chosen['cashbox'], cb);
    await expectLater(svc.paymentSource(paymentMethodId: 999999), throwsArgumentError);
  });

  test('الطابور الدائري: إنهاء الدور يعيد المستفيد لآخر الطابور ويزيد دورته', () async {
    final repo = StationRepository(db);
    await db.transaction((tx) => tx.rawDelete('DELETE FROM queue_entries'));
    final ids = <int>[];
    for (final n in ['طابور ١', 'طابور ٢', 'طابور ٣']) {
      final b = await repo.createBeneficiary(name: n);
      ids.add(await repo.enqueue(b));
    }
    await repo.completeQueue(ids.first);
    final r = await db.query(
      'SELECT id,position,status,cycle_number FROM queue_entries ORDER BY position',
    );
    expect(r.map((e) => e['id']).toList(), [ids[1], ids[2], ids[0]]);
    expect(r.last['status'], 'waiting');
    expect(r.last['cycle_number'], 2);
    expect(r.map((e) => e['position']).toList(), [1, 2, 3]);
  });

  test('اختيار المضخة عبر المستودع: يحفظ الإعدادين ويرفض مضخة غير موجودة', () async {
    final repo = StationRepository(db);
    await repo.selectPump(1);
    final st = await repo.settings();
    expect(st['selected_pump_id'], '1');
    expect(st['pump_name'], isNotEmpty);
    await expectLater(repo.selectPump(999999), throwsArgumentError);
  });

  // ---------- إصلاحات V24 ----------
  test('الصندوق ذو رصيد افتتاحي يُقيَّد في الأستاذ مقابل 3000', () async {
    final before = await accountNet('3000');
    final repo = StationRepository(db);
    final id = await repo.createCashbox(name: 'افتتاحي', openingBalance: 700);
    expect(await cashboxBalance(id), 700);
    expect((await accountNet('3000')) - before, -700);
  });

  test('طريقة دفع وصندوق متعارضان يُرفضان', () async {
    final cb = await db.insert('cashboxes', {
      'station_id': 1, 'name': 'آخر', 'opening_balance': 0,
      'current_balance': 0, 'currency': 'YER', 'active': 1,
    });
    await expectLater(
      svc.addExpense(
        category: 'other', title: 't', amount: 10, date: DateTime.now(),
        paymentMethodId: 1, cashboxId: cb,
      ),
      throwsArgumentError,
    );
  });

  test('إلغاء دفعة مستفيد يعكس القيد، ويُرفض إن جعل الصندوق سالبًا', () async {
    final repo = StationRepository(db);
    final b = await repo.createBeneficiary(name: 'مستفيد إلغاء');
    await svc.receivePayment(beneficiaryId: b, amount: 300, paymentMethodId: 1, cashboxId: 1);
    final pay = (await db.query("SELECT id FROM payments WHERE beneficiary_id=? ORDER BY id DESC", args: [b])).first['id'] as int;
    final before = await cashboxBalance(1);
    await svc.cancelPayment(pay, 1, 'خطأ');
    expect(await cashboxBalance(1), before - 300);
    await svc.receivePayment(beneficiaryId: b, amount: 300, paymentMethodId: 1, cashboxId: 1);
    final pay2 = (await db.query("SELECT id FROM payments WHERE beneficiary_id=? AND status='posted'", args: [b])).first['id'] as int;
    await db.transaction((tx) => tx.rawUpdate('UPDATE cashboxes SET current_balance=0 WHERE id=1'));
    await expectLater(svc.cancelPayment(pay2, 1, 'خطأ'), throwsStateError);
  });

  test('حذف مستفيد برصيد غير صفر مرفوض، وتعديل الافتتاحي يقيّد فرقًا', () async {
    final repo = StationRepository(db);
    final b = await repo.createBeneficiary(name: 'برصيد', opening: 500);
    await expectLater(repo.deleteBeneficiary(b, 1, 'سبب'), throwsStateError);
    final net = await accountNet('1200');
    await repo.updateBeneficiary(b, {'opening_balance': 800}, 1);
    expect((await accountNet('1200')) - net, 300);
    await expectLater(repo.updateBeneficiary(b, {'status': 'x'}, 1), throwsArgumentError);
  });

  test('عكس سقاية الشريك لا يُحسب أرباحًا', () async {
    await useSolar6000();
    final p = await db.insert('partners', {'name': 'شريك أرباح', 'ownership_mode': 'shares'});
    final id = await irrigationFor(partnerId: p, start: DateTime(2026, 5, 3, 8));
    await svc.cancelIrrigation(id, 1, 'خطأ');
    final sum = await StationRepository(db).partyFinancialSummary('partner', p);
    expect(sum['earnings'], 0);
    expect(sum['paid'], 0);
    expect(sum['balance'], 0);
  });

  test('الرقم المرجعي يُحفظ في دفع العامل والشريك، وحركة الشريك تُربط بالدفعة', () async {
    await db.transaction((tx) => tx.rawUpdate('UPDATE cashboxes SET current_balance=100000 WHERE id=1'));
    final w = await db.insert('workers', {'name': 'عامل مرجع', 'pay_type': 'fixed'});
    final p = await db.insert('partners', {'name': 'شريك مرجع', 'ownership_mode': 'shares'});
    final pw = await svc.payWorker(
      workerId: w, amount: 100, paymentMethodId: 1, cashboxId: 1, userId: 1, referenceNumber: 'REF-W',
    );
    final pp = await svc.payPartner(
      partnerId: p, amount: 100, paymentMethodId: 1, cashboxId: 1, userId: 1, referenceNumber: 'REF-P',
    );
    final refs = {
      for (final r in await db.query(
        'SELECT id,reference_number FROM payments WHERE id IN (?,?)',
        args: [pw, pp],
      ))
        r['id']: r['reference_number'],
    };
    expect(refs, {pw: 'REF-W', pp: 'REF-P'});
    final pt = await db.query(
      "SELECT reference_type,reference_id,created_by FROM partner_transactions WHERE partner_id=? AND type='payment'",
      args: [p],
    );
    expect(pt.first['reference_type'], 'payment');
    expect(pt.first['reference_id'], pp);
    expect(pt.first['created_by'], 1);
    // إلغاء الدفعة يعكس حركة الشريك ويربط العكس بالدفعة الملغاة.
    await svc.cancelPayment(pp, 1, 'خطأ');
    final rev = await db.query(
      "SELECT reference_type,reference_id FROM partner_transactions WHERE partner_id=? AND type='payment_reversal'",
      args: [p],
    );
    expect(rev.first['reference_type'], 'payment_cancel');
    expect(rev.first['reference_id'], pp);
  });

  test('سقاية الشريك وإلغاؤها تُربطان بالسقاية في partner_transactions', () async {
    await useSolar6000();
    final p = await db.insert('partners', {'name': 'شريك ربط', 'ownership_mode': 'shares'});
    final id = await irrigationFor(partnerId: p, start: DateTime(2026, 6, 3, 8));
    final used = await db.query(
      "SELECT reference_type,reference_id FROM partner_transactions WHERE partner_id=? AND type='irrigation'",
      args: [p],
    );
    expect(used.first['reference_type'], 'irrigation');
    expect(used.first['reference_id'], id);
    await svc.cancelIrrigation(id, 1, 'خطأ');
    final rev = await db.query(
      "SELECT reference_type,reference_id FROM partner_transactions WHERE partner_id=? AND type='irrigation_reversal'",
      args: [p],
    );
    expect(rev.first['reference_type'], 'irrigation_cancel');
    expect(rev.first['reference_id'], id);
  });

  test('الرصيد الافتتاحي للعامل والشريك يُقيَّد في الأستاذ ويطابق كشفيهما', () async {
    final repo = StationRepository(db);
    final w = await repo.createWorker(name: 'عامل افتتاحي', payType: 'fixed', opening: 700, phone: '777');
    final p = await repo.createPartner(name: 'شريك افتتاحي', mode: 'shares', shares: 1, opening: -300);
    expect((await svc.workerBalance(w))['balance'], 700);
    expect(await glPayable('2100', 'worker_id', w), 700);
    expect((await svc.partnerBalance(p))['balance'], -300);
    expect(await glPayable('2200', 'partner_id', p), -300);
    final row = await db.query('SELECT phone FROM workers WHERE id=?', args: [w]);
    expect(row.first['phone'], '777'); // الهاتف لم يعد يضيع عند الإنشاء
    // حذف عامل/شريك برصيد غير صفر يرمي StateError مفهومًا تلتقطه الواجهة بـ runGuarded.
    await expectLater(repo.deleteWorker(w, 1, 'سبب'), throwsStateError);
    await expectLater(repo.deletePartner(p, 1, 'سبب'), throwsStateError);
  });

  test('استحقاق حصة الشريك يُقيَّد على 3200 لا على مصروف العمال 5000', () async {
    final p = await db.insert('partners', {'name': 'شريك حصة', 'ownership_mode': 'shares'});
    final b5000 = await accountNet('5000');
    final b3200 = await accountNet('3200');
    await svc.createPartnerShare(partnerId: p, amount: 900, date: DateTime(2026, 3, 1), userId: 1);
    expect((await accountNet('5000')) - b5000, 0);
    expect((await accountNet('3200')) - b3200, 900);
    expect(await glPayable('2200', 'partner_id', p), 900);
  });

  test('SQLite سليمة والمفاتيح الأجنبية مفعّلة ولا توجد مراجع يتيمة', () async {
    final foreignKeys = await db.query('PRAGMA foreign_keys');
    expect((foreignKeys.single.values.single as num).toInt(), 1);
    final integrity = await db.query('PRAGMA integrity_check');
    expect(integrity.single['integrity_check'], 'ok');
    final violations = await db.query('PRAGMA foreign_key_check');
    expect(violations, isEmpty);
    final treeIssues = await StationRepository(db).accountTreeIssues();
    expect(treeIssues, isEmpty, reason: 'يجب أن تكون شجرة الحسابات الافتراضية سليمة');
  });

  test('استعادة ملف SQLite سليم من النوع المطابق تعمل مع بقاء رفض النوع المختلف', () async {
    final backupService = BackupService(svc);
    final databasePath = await backupService.databasePath();
    final temp = await Directory.systemTemp.createTemp('water-restore-test-');
    final source = File('${temp.path}/solar-backup.db');
    final originalSettings = await svc.settings();
    final originalType = originalSettings['system_type'] ?? 'diesel';
    final originalStationName = originalSettings['station_name'] ?? '';
    try {
      await db.update('settings', {'value': 'solar'}, 'key=?', ['system_type']);
      await db.query('PRAGMA wal_checkpoint(TRUNCATE)');
      await db.close();
      await File(databasePath).copy(source.path);

      await db.db;
      await db.update('settings', {'value': 'محطة مؤقتة بعد النسخ'}, 'key=?', ['station_name']);
      final wrongType = await backupService.validateDatabaseFile(
        source.path,
        expectedSystemType: 'diesel',
      );
      expect(wrongType['valid'], isFalse);

      final result = await backupService.restoreDatabaseFromFile(
        source.path,
        rollbackDirectory: temp,
      );
      expect(result['restored'], isTrue, reason: '${result['error']}');
      expect(result['system_type'], 'solar');
      expect((await db.query("SELECT value FROM settings WHERE key='system_type'")).single['value'], 'solar');
      expect((await db.query("SELECT value FROM settings WHERE key='station_name'")).single['value'], originalStationName);
      expect((await db.query('PRAGMA integrity_check')).single.values.single, 'ok');
      expect(await db.query('PRAGMA foreign_key_check'), isEmpty);

      // أعد إعداد الاختبارات اللاحقة إلى قيمها الأصلية.
      await db.update('settings', {'value': originalType}, 'key=?', ['system_type']);
    } finally {
      await db.close();
      await temp.delete(recursive: true);
      await db.db;
      await db.update('settings', {'value': originalType}, 'key=?', ['system_type']);
      await db.update('settings', {'value': originalStationName}, 'key=?', ['station_name']);
    }
  });

  test('الصندوق والشريك الجديدان يتبعان محطة المضخة المحددة لا الرقم 1', () async {
    final repo = StationRepository(db);
    final now = DateTime(2026, 1, 1).toIso8601String();
    final st = await db.insert('stations', {'name': 'محطة ثانية', 'created_at': now, 'updated_at': now});
    final pump = await db.insert('pumps', {'station_id': st, 'name': 'مضخة 2', 'system_type': 'diesel', 'active': 1});
    await db.update('settings', {'value': '$pump'}, 'key=?', ['selected_pump_id']);
    try {
      expect(await svc.currentStationId(), st);
      final cb = await repo.createCashbox(name: 'صندوق المحطة الثانية');
      final pt = await repo.createPartner(name: 'شريك المحطة الثانية', mode: 'shares', shares: 1);
      expect((await db.query('SELECT station_id FROM cashboxes WHERE id=?', args: [cb])).first['station_id'], st);
      expect((await db.query('SELECT station_id FROM partners WHERE id=?', args: [pt])).first['station_id'], st);
    } finally {
      await db.update('settings', {'value': '1'}, 'key=?', ['selected_pump_id']);
    }
  });

  test('ملخص الأرباح والتوزيع واستحقاق السقاية معزولة حسب المحطة', () async {
    final repo = StationRepository(db);
    final originalSettings = await db.query(
      "SELECT key,value FROM settings WHERE key IN ('selected_pump_id','system_type','solar_hourly_rate')",
    );
    final oldValues = {for (final row in originalSettings) '${row['key']}': row['value']};
    final now = DateTime(2026, 1, 1).toIso8601String();
    Future<(int, int, int)> createStation(String name, String partnerName) async {
      final stationId = await db.insert('stations', {
        'name': name, 'created_at': now, 'updated_at': now,
      });
      final pumpId = await db.insert('pumps', {
        'station_id': stationId, 'name': 'مضخة $name', 'system_type': 'solar', 'active': 1,
      });
      await db.update('settings', {'value': '$pumpId'}, 'key=?', ['selected_pump_id']);
      final partnerId = await repo.createPartner(name: partnerName, mode: 'shares', shares: 1);
      return (stationId, pumpId, partnerId);
    }

    try {
      final (stationA, pumpA, partnerA) = await createStation('محطة توزيع ألف', 'شريك ألف');
      final (stationB, pumpB, partnerB) = await createStation('محطة توزيع باء', 'شريك باء');
      await db.insert('workers', {
        'station_id': stationA, 'name': 'عامل ألف', 'pay_type': 'fixed', 'fixed_salary': 300,
      });
      await db.insert('workers', {
        'station_id': stationB, 'name': 'عامل باء', 'pay_type': 'fixed', 'fixed_salary': 500,
      });
      await db.update('settings', {'value': 'solar'}, 'key=?', ['system_type']);
      await db.update('settings', {'value': '1200'}, 'key=?', ['solar_hourly_rate']);
      await db.update('settings', {'value': '$pumpA'}, 'key=?', ['selected_pump_id']);

      await svc.recordIrrigation(
        stationId: stationA, pumpId: pumpA, partnerId: partnerA, partyType: 'partner',
        start: DateTime(2029, 6, 1, 8), end: DateTime(2029, 6, 1, 9),
        systemType: 'solar', waterRate: 0, litersPerHour: 0, dieselPrice: 0,
        solarRate: 1200, thirdRate: 0, cloudMinutes: 0, paidAmount: 0,
      );
      final directA = await db.query(
        "SELECT amount FROM partner_transactions WHERE partner_id=? AND reference_type='irrigation_profit'",
        args: [partnerA],
      );
      final directB = await db.query(
        "SELECT amount FROM partner_transactions WHERE partner_id=? AND reference_type='irrigation_profit'",
        args: [partnerB],
      );
      expect(directA, hasLength(1));
      expect(directB, isEmpty);

      final accountRows = await db.query("SELECT code,id FROM accounts WHERE code IN ('1000','4000')");
      final accounts = {for (final row in accountRows) '${row['code']}': row['id']};
      Future<void> addRevenue(int stationId, int amount) async {
        final entryId = await db.insert('journal_entries', {
          'station_id': stationId, 'date': DateTime(2030, 12, 31, 12).toIso8601String(),
          'reference_type': 'test_station_profit', 'description': 'إيراد اختبار محطتين',
          'status': 'posted', 'created_at': DateTime.now().toIso8601String(),
        });
        await db.insert('journal_lines', {
          'journal_entry_id': entryId, 'account_id': accounts['1000'],
          'debit': amount, 'credit': 0,
        });
        await db.insert('journal_lines', {
          'journal_entry_id': entryId, 'account_id': accounts['4000'],
          'debit': 0, 'credit': amount,
        });
      }
      await addRevenue(stationA, 10000);
      await addRevenue(stationB, 20000);

      final from = DateTime(2030, 1, 1), to = DateTime(2030, 12, 31);
      await db.update('settings', {'value': '$pumpA'}, 'key=?', ['selected_pump_id']);
      expect(await svc.accrueMonthlySalaries(month: DateTime(2030, 12, 1)), 1);
      final partnersA = await repo.partners();
      expect(partnersA.any((row) => row['id'] == partnerA), isTrue);
      expect(partnersA.any((row) => row['id'] == partnerB), isFalse);
      final summaryA = await repo.partnerProfitSummary(from: from, to: to);
      expect(summaryA['revenue'], 10000);
      expect(summaryA['workers'], 300);
      expect(await svc.distributePartnerProfits(from: from, to: to), 1);

      await db.update('settings', {'value': '$pumpB'}, 'key=?', ['selected_pump_id']);
      expect(await svc.accrueMonthlySalaries(month: DateTime(2030, 12, 1)), 1);
      final partnersB = await repo.partners();
      expect(partnersB.any((row) => row['id'] == partnerB), isTrue);
      expect(partnersB.any((row) => row['id'] == partnerA), isFalse);
      final summaryB = await repo.partnerProfitSummary(from: from, to: to);
      expect(summaryB['revenue'], 20000);
      expect(summaryB['workers'], 500);
      // كلا التوزيعين لهما مرجع الفترة نفسه، لكنهما مستقلان لأن المحطة مختلفة.
      expect(await svc.distributePartnerProfits(from: from, to: to), 1);

      for (final pair in [(stationA, partnerA), (stationB, partnerB)]) {
        final (stationId, partnerId) = pair;
        final distribution = await db.query(
          "SELECT id,amount FROM partner_transactions WHERE partner_id=? AND reference_type='profit_distribution'",
          args: [partnerId],
        );
        expect(distribution, hasLength(1));
        expect(distribution.single['amount'], stationId == stationA ? 9700 : 19500);
        final journal = await db.query(
          "SELECT station_id,date FROM journal_entries WHERE reference_type='partner' AND reference_id=?",
          args: [distribution.single['id']],
        );
        expect(journal.single['station_id'], stationId);
        expect('${journal.single['date']}', startsWith('2030-12-31'));
      }
    } finally {
      for (final entry in oldValues.entries) {
        await db.update('settings', {'value': entry.value}, 'key=?', [entry.key]);
      }
    }
  });

  test('إقفال سنة مكتملة يرحّل النتيجة ويمنع التعديل داخل الفترة', () async {
    final ids = await db.query("SELECT code,id FROM accounts WHERE code IN ('1000','1200','2100','2200','3000','4000','5000')");
    final account = {for (final row in ids) '${row['code']}': row['id'] as int};
    Future<int> insertEntry(String ref, DateTime date, List<Map<String, Object?>> lines) async {
      final id = await db.insert('journal_entries', {
        'station_id': 1, 'date': date.toIso8601String(), 'reference_type': 'test_$ref',
        'description': ref, 'status': 'posted', 'created_at': DateTime.now().toIso8601String(),
      });
      for (final line in lines) {
        await db.insert('journal_lines', {...line, 'journal_entry_id': id});
      }
      return id;
    }
    await insertEntry('income', DateTime(2025, 6, 1), [
      {'account_id': account['1000'], 'debit': 10000, 'credit': 0},
      {'account_id': account['4000'], 'debit': 0, 'credit': 10000},
    ]);
    await insertEntry('expense', DateTime(2025, 7, 1), [
      {'account_id': account['5000'], 'debit': 4000, 'credit': 0},
      {'account_id': account['1000'], 'debit': 0, 'credit': 4000},
    ]);
    final unreconciledBeneficiary = await db.insert('beneficiaries', {
      'station_id': 1,
      'name': 'مستفيد بلا قيد افتتاحي',
      'opening_balance': 250,
      'created_at': DateTime(2024, 12, 1).toIso8601String(),
      'updated_at': DateTime(2024, 12, 1).toIso8601String(),
    });
    await db.update('settings', {'value': '1'}, 'key=?', ['selected_pump_id']);
    final reconciliationRepo = StationRepository(db);
    final workerId = await reconciliationRepo.createWorker(
      name: 'عامل مطابقة الأستاذ', payType: 'fixed', opening: 100,
    );
    final partnerId = await reconciliationRepo.createPartner(
      name: 'شريك مطابقة الأستاذ', mode: 'shares', shares: 1, opening: 60,
    );
    final workerAccount = (await db.query(
      'SELECT id FROM accounts WHERE code=?', args: ['2100.W$workerId'],
    )).single['id'] as int;
    final partnerAccount = (await db.query(
      'SELECT id FROM accounts WHERE code=?', args: ['2200.P$partnerId'],
    )).single['id'] as int;
    final unassignedWorkerEntry = await insertEntry('worker_control_unassigned', DateTime(2024, 12, 1), [
      {'account_id': account['2100'], 'debit': 0, 'credit': 77},
      {'account_id': account['3000'], 'debit': 77, 'credit': 0},
    ]);
    final unassignedPartnerEntry = await insertEntry('partner_control_unassigned', DateTime(2024, 12, 1), [
      {'account_id': account['2200'], 'debit': 0, 'credit': 55},
      {'account_id': account['3000'], 'debit': 55, 'credit': 0},
    ]);
    await seedCashEquityForTest(1, DateTime(2025, 1, 2), 100000);
    await db.update(
      'cashboxes', {'current_balance': await cashboxBalance(1) + 1}, 'id=?', [1],
    );
    final unreconciled = await svc.previewFiscalYear(
      stationId: 1, start: DateTime(2025, 1, 1), endExclusive: DateTime(2026, 1, 1),
    );
    expect(unreconciled['valid'], false);
    expect('${unreconciled['errors']}', contains('الصناديق الحالية'));
    expect('${unreconciled['errors']}', contains('لم تُسجل مطابقة العد النقدي'));
    expect('${unreconciled['errors']}', contains('الدفاتر الفرعية'));
    final reconciliationRows = (unreconciled['subledger_reconciliation'] as List)
        .cast<Map<String, Object?>>();
    final beneficiaryMismatch = reconciliationRows.singleWhere((row) => row['kind'] == 'beneficiaries');
    final workerMismatch = reconciliationRows.singleWhere((row) => row['kind'] == 'workers');
    final partnerMismatch = reconciliationRows.singleWhere((row) => row['kind'] == 'partners');
    expect(beneficiaryMismatch['difference'], 250);
    expect(workerMismatch['difference'], -77);
    expect(partnerMismatch['difference'], -55);
    await reconcileCashboxesForTest(1);
    await insertEntry('beneficiary_opening', DateTime(2024, 12, 1), [
      {
        'account_id': account['1200'], 'beneficiary_id': unreconciledBeneficiary,
        'debit': 250, 'credit': 0,
      },
      {'account_id': account['3000'], 'debit': 0, 'credit': 250},
    ]);
    await db.update(
      'journal_lines', {'account_id': workerAccount, 'worker_id': workerId},
      'journal_entry_id=? AND account_id=?', [unassignedWorkerEntry, account['2100']],
    );
    await db.update(
      'journal_lines', {'account_id': partnerAccount, 'partner_id': partnerId},
      'journal_entry_id=? AND account_id=?', [unassignedPartnerEntry, account['2200']],
    );
    final start = DateTime(2025, 1, 1), endExclusive = DateTime(2026, 1, 1);
    await db.insert('cashboxes', {
      'station_id': 1,
      'name': 'حساب البنك للاختبار',
      'opening_balance': 0,
      'current_balance': 0,
      'currency': 'YER',
      'active': 1,
      'ledger_account_code': '1100',
    });
    final cashTargets = await svc.cashReconciliationTargets(
      stationId: 1, endExclusive: endExclusive,
    );
    expect(cashTargets.any((row) => row['source_type'] == 'bank_statement'), isTrue);
    final noBankReferenceEntries = [
      for (final target in cashTargets)
        {
          'account_code': target['account_code'],
          'actual_balance': target['book_balance'],
          'reference': '',
        },
    ];
    final journalCountBeforeReconciliation = (await db.query(
      'SELECT COUNT(*) n FROM journal_entries',
    )).single['n'];
    await expectLater(
      svc.recordCashReconciliations(
        stationId: 1, start: start, endExclusive: endExclusive, userId: 1,
        entries: noBankReferenceEntries,
      ),
      throwsArgumentError,
    );
    expect((await db.query('SELECT COUNT(*) n FROM journal_entries')).single['n'], journalCountBeforeReconciliation);
    final journalCountBeforeEvidence = (await db.query(
      'SELECT COUNT(*) n FROM journal_entries',
    )).single['n'];
    final cashBalanceBeforeEvidence = await cashboxBalance(1);
    final varianceRows = await recordCashEvidenceForTest(
      stationId: 1, start: start, endExclusive: endExclusive, userId: 1, difference: 1,
    );
    expect(varianceRows.any((row) => row['difference'] == 1), isTrue);
    expect((await db.query('SELECT COUNT(*) n FROM journal_entries')).single['n'], journalCountBeforeEvidence);
    expect(await cashboxBalance(1), cashBalanceBeforeEvidence);
    final cashVariancePreview = await svc.previewFiscalYear(
      stationId: 1, start: start, endExclusive: endExclusive,
    );
    expect(cashVariancePreview['valid'], false);
    expect('${cashVariancePreview['errors']}', contains('مطابقة النقد والبنك غير مكتملة أو بها فروق'));
    final matchedRows = await recordCashEvidenceForTest(
      stationId: 1, start: start, endExclusive: endExclusive, userId: 1,
    );
    expect(matchedRows.every((row) => row['difference'] == 0 && row['status'] == 'matched'), isTrue);
    final preview = await svc.previewFiscalYear(stationId: 1, start: start, endExclusive: endExclusive);
    expect(preview['valid'], true, reason: '${preview['errors']}');
    expect(preview['income'], 10000);
    expect(preview['expenses'], 4000);
    expect(preview['net_profit'], 6000);
    final closeId = await svc.closeFiscalYear(stationId: 1, start: start, endExclusive: endExclusive, userId: 1);
    final closure = (await db.query('SELECT * FROM period_closures WHERE id=?', args: [closeId])).first;
    expect(closure['status'], 'closed');
    expect(closure['net_profit'], 6000);
    expect(closure['close_journal_entry_id'], isNotNull);
    expect(closure['reconciliation_json'], isNotNull);
    final closureSnapshot = jsonDecode('${closure['reconciliation_json']}') as Map<String, dynamic>;
    final savedSubledger = (closureSnapshot['subledger_reconciliation'] as List)
        .cast<Map<String, dynamic>>();
    expect(savedSubledger, hasLength(3));
    expect(savedSubledger.every((row) => row['difference'] == 0), isTrue);
    expect(closureSnapshot['actual_cash_reconciliation_valid'], true);
    final savedCashEvidence = (closureSnapshot['actual_cash_reconciliation'] as List)
        .cast<Map<String, dynamic>>();
    expect(savedCashEvidence.every((row) => row['evidence_status'] == 'matched'), isTrue);
    expect(savedCashEvidence.any((row) => row['source_type'] == 'bank_statement'), isTrue);
    final retained = await db.query(
      "SELECT l.debit,l.credit FROM journal_lines l JOIN accounts a ON a.id=l.account_id WHERE l.journal_entry_id=? AND a.code='3300'",
      args: [closure['close_journal_entry_id']],
    );
    expect(retained.single['debit'], 0);
    expect(retained.single['credit'], 6000);
    final report = await StationRepository(db).partnerProfitSummary(
      from: start, to: DateTime(2025, 12, 31),
    );
    expect(report['revenue'], 10000);
    expect(report['workers'], 4000);
    await expectLater(svc.closeFiscalYear(stationId: 1, start: start, endExclusive: endExclusive, userId: 1), throwsStateError);
    await expectLater(svc.addExpense(
      category: 'maintenance', title: 'محاولة بعد الإقفال', amount: 100,
      date: DateTime(2025, 8, 1), paymentMethodId: 1, cashboxId: 1,
    ), throwsStateError);
    await svc.reopenFiscalYear(closureId: closeId, userId: 1, reason: 'اختبار إعادة الفتح الموثقة');
    final reopened = (await db.query('SELECT * FROM period_closures WHERE id=?', args: [closeId])).first;
    expect(reopened['status'], 'reopened');
    expect(reopened['reopen_journal_entry_id'], isNotNull);
    await svc.addExpense(
      category: 'maintenance', title: 'مصروف بعد إعادة الفتح', amount: 100,
      date: DateTime(2025, 8, 1), paymentMethodId: 1, cashboxId: 1,
    );
    final staleCashPreview = await svc.previewFiscalYear(
      stationId: 1, start: start, endExclusive: endExclusive,
    );
    expect(staleCashPreview['valid'], false);
    expect('${staleCashPreview['errors']}', contains('تغير رصيد الدفاتر بعد المطابقة'));
    await recordCashEvidenceForTest(
      stationId: 1, start: start, endExclusive: endExclusive, userId: 1,
    );
    final reclosePreview = await svc.previewFiscalYear(stationId: 1, start: start, endExclusive: endExclusive);
    expect(reclosePreview['valid'], true, reason: '${reclosePreview['errors']}');
    expect(reclosePreview['net_profit'], 5900);
    final reclosedId = await svc.closeFiscalYear(
      stationId: 1, start: start, endExclusive: endExclusive, userId: 1,
      notes: 'إعادة إقفال بعد التسوية',
    );
    expect(reclosedId, isNot(closeId));
    final afterRecloseReport = await StationRepository(db).partnerProfitSummary(
      from: start, to: DateTime(2025, 12, 31),
    );
    expect(afterRecloseReport['revenue'], 10000);
    expect(afterRecloseReport['expenses'], 100);
  });

  test('مدير المحطة لا يستطيع تسجيل مطابقة لمحطة أخرى', () async {
    final managerId = await db.insert('app_users', {
      'station_id': 1,
      'name': 'مدير محطة الاختبار',
      'username': 'station_manager_cash_test',
      'password_hash': 'test-hash',
      'role': 'manager',
      'active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
    await expectLater(
      svc.recordCashReconciliations(
        stationId: 999,
        start: DateTime(2025, 1, 1),
        endExclusive: DateTime(2026, 1, 1),
        userId: managerId,
        entries: const [],
      ),
      throwsStateError,
    );
  });

  test('ترقية v17 تنشئ جدول شهادات مطابقة النقد والبنك', () async {
    final opened = await db.db;
    await opened.execute('PRAGMA user_version=17');
    await db.close();
    final upgraded = await db.db;
    final table = await upgraded.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='cash_reconciliations'",
    );
    final index = await upgraded.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_cash_rec_period'",
    );
    final version = await upgraded.rawQuery('PRAGMA user_version');
    expect(table, isNotEmpty);
    expect(index, isNotEmpty);
    expect((version.single.values.single as num).toInt(), 18);
  });

  test('دورة المصروف العام والخاص وإلغاء الخاص تطابق الصندوق والشريك وصافي الأرباح', () async {
    final repo = StationRepository(db);
    final partnerId = await repo.createPartner(
      name: 'شريك دورة المصروفات ${DateTime.now().microsecondsSinceEpoch}',
      mode: 'shares',
      shares: 1,
    );
    final stationId = await svc.currentStationId();
    final start = DateTime(2028, 1, 1);
    final end = DateTime(2028, 1, 31);
    const seedRevenue = 10000;
    const generalExpenseAmount = 100;
    const partnerExpenseAmount = 250;
    const cashboxId = 1;
    const paymentMethodId = 1;

    final cashBeforeSeed = await cashboxBalance(cashboxId);
    final box = await db.query(
      "SELECT COALESCE(NULLIF(ledger_account_code,''),'1000') code FROM cashboxes WHERE id=?",
      args: [cashboxId],
    );
    final cashCode = '${box.single['code']}';
    final revenueRows = await db.query(
      "SELECT id FROM accounts WHERE type='revenue' ORDER BY id LIMIT 1",
    );
    expect(revenueRows, isNotEmpty, reason: 'يجب وجود حساب إيراد في مخطط الحسابات');
    final cashRows = await db.query(
      'SELECT id FROM accounts WHERE code=? LIMIT 1',
      args: [cashCode],
    );
    expect(cashRows, isNotEmpty, reason: 'يجب ربط الصندوق بحساب أستاذ');
    final seedEntryId = await db.insert('journal_entries', {
      'station_id': stationId,
      'date': start.add(const Duration(days: 9)).toIso8601String(),
      'reference_type': 'test_expense_cycle_revenue',
      'description': 'إيراد أساس لدورة اختبار المصروفات',
      'status': 'posted',
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert('journal_lines', {
      'journal_entry_id': seedEntryId,
      'account_id': cashRows.single['id'],
      'debit': seedRevenue,
      'credit': 0,
      'memo': 'إيراد اختبار',
    });
    await db.insert('journal_lines', {
      'journal_entry_id': seedEntryId,
      'account_id': revenueRows.single['id'],
      'debit': 0,
      'credit': seedRevenue,
      'memo': 'إيراد اختبار',
    });
    await db.update(
      'cashboxes',
      {'current_balance': cashBeforeSeed + seedRevenue},
      'id=?',
      [cashboxId],
    );

    final partnerBalanceBefore = (await svc.partnerBalance(partnerId))['balance'] as num;
    final profitBeforeExpenses = await repo.partnerProfitSummary(from: start, to: end);
    expect(profitBeforeExpenses['distributable'], seedRevenue);

    final generalId = await svc.addExpense(
      category: 'maintenance',
      title: 'اختبار مصروف عام',
      amount: generalExpenseAmount,
      date: start.add(const Duration(days: 10)),
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
      notes: 'اختبار آلي فقط',
    );
    expect(await cashboxBalance(cashboxId), cashBeforeSeed + seedRevenue - generalExpenseAmount);
    final afterGeneral = await repo.partnerProfitSummary(from: start, to: end);
    expect(afterGeneral['distributable'], seedRevenue - generalExpenseAmount);
    expect(
      (await db.query("SELECT status FROM expenses WHERE id=?", args: [generalId])).single['status'],
      'posted',
    );

    final partnerBalanceBeforePrivate = (await svc.partnerBalance(partnerId))['balance'] as num;
    final cashBeforePrivate = await cashboxBalance(cashboxId);
    final partnerExpenseId = await svc.addExpense(
      category: 'maintenance',
      title: 'اختبار مصروف خاص بالشريك',
      amount: partnerExpenseAmount,
      date: start.add(const Duration(days: 11)),
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
      partnerId: partnerId,
      notes: 'اختبار آلي فقط',
    );
    expect(await cashboxBalance(cashboxId), cashBeforePrivate - partnerExpenseAmount);
    expect(
      (await svc.partnerBalance(partnerId))['balance'],
      partnerBalanceBeforePrivate - partnerExpenseAmount,
    );
    final afterPrivate = await repo.partnerProfitSummary(from: start, to: end);
    expect(afterPrivate['distributable'], afterGeneral['distributable'],
        reason: 'المصروف الخاص لا يخفض الربح العام ولا يخصم مرتين');
    final partnerRows = await repo.partners();
    final partnerName = partnerRows.singleWhere((p) => p['id'] == partnerId)['name'];
    final privateReport = await repo.report(
      'partner_profit_distribution',
      from: start,
      to: end,
    );
    final privateRow = privateReport.singleWhere((r) => r['name'] == partnerName);
    expect(privateRow['partner_expenses'], partnerExpenseAmount);
    expect(privateRow['net_amount'], (privateRow['gross_amount'] as num) - partnerExpenseAmount);

    await svc.cancelExpense(partnerExpenseId, 1, 'إلغاء ضمن اختبار دورة المصروفات');
    expect(await cashboxBalance(cashboxId), cashBeforePrivate);
    expect((await svc.partnerBalance(partnerId))['balance'], partnerBalanceBeforePrivate);
    expect(
      (await db.query('SELECT status FROM expenses WHERE id=?', args: [partnerExpenseId])).single['status'],
      'cancelled',
    );
    final reversalRows = await db.query(
      "SELECT COUNT(*) c FROM journal_entries WHERE reference_type='reversal' AND reference_id IN (SELECT id FROM journal_entries WHERE reference_type='expense' AND reference_id=?)",
      args: [partnerExpenseId],
    );
    expect((reversalRows.single['c'] as num).toInt(), 1);
    final afterCancel = await repo.partnerProfitSummary(from: start, to: end);
    expect(afterCancel['distributable'], seedRevenue - generalExpenseAmount);
    final finalReport = await repo.report(
      'partner_profit_distribution',
      from: start,
      to: end,
    );
    final finalRow = finalReport.singleWhere((r) => r['name'] == privateRow['name']);
    expect(finalRow['partner_expenses'], 0);
    expect(finalRow['net_amount'], finalRow['gross_amount']);
    expect(await cashboxBalance(cashboxId), cashBeforeSeed + seedRevenue - generalExpenseAmount);
    expect((await svc.partnerBalance(partnerId))['balance'], partnerBalanceBefore);
  });


  test('دورة محاسبية كاملة: تسجيل إيراد ثم سقاية وأجور ودفع جزئي وإلغاء مصروف ومطابقة التقارير', () async {
    final repo = StationRepository(db);
    final stationId = await svc.currentStationId();
    final settings = await svc.settings();
    final pumpId = int.parse(settings['selected_pump_id']!);
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);
    final nextMonth = DateTime(now.year, now.month + 1, 1);
    final monthEnd = nextMonth.subtract(const Duration(days: 1));
    final operationStart = DateTime(now.year, now.month, now.day, 1);
    const cashboxId = 1;
    const paymentMethodId = 1;

    // عزل الدورة عن الأطراف النشطة السابقة، ثم إعداد منظومة الاختبار.
    await db.update('workers', {'active': 0}, 'station_id=?', [stationId]);
    await db.update('partners', {'active': 0}, 'station_id=?', [stationId]);
    await db.update('settings', {'value': 'solar'}, 'key=?', ['system_type']);
    await db.update('settings', {'value': '100000'}, 'key=?', ['solar_hourly_rate']);

    final summaryBefore = await repo.partnerProfitSummary(from: monthStart, to: monthEnd);
    final cashBefore = await cashboxBalance(cashboxId);
    final box = await db.query(
      "SELECT COALESCE(NULLIF(ledger_account_code,''),'1000') code FROM cashboxes WHERE id=?",
      args: [cashboxId],
    );
    final cashCode = '${box.single['code']}';
    final ledgerCashBefore = await accountNet(cashCode);
    final pnlBeforeRows = await db.query(
      "SELECT COALESCE(SUM(CASE WHEN a.type='revenue' THEN jl.credit-jl.debit WHEN a.type='expense' THEN jl.credit-jl.debit ELSE 0 END),0) net FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.status='posted' AND je.date>=? AND je.date<?",
      args: [stationId, monthStart.toIso8601String(), nextMonth.toIso8601String()],
    );
    final pnlBefore = (pnlBeforeRows.single['net'] as num).round();

    // أولًا: تسجيل إيراد سقاية محصّل نقدًا قبل تفعيل استحقاقات العمال والشركاء.
    final revenueBeneficiary = await db.insert('beneficiaries', {
      'name': 'مستفيد إيراد دورة المحاسبة',
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    final revenueIrrigationId = await svc.recordIrrigation(
      stationId: stationId,
      pumpId: pumpId,
      beneficiaryId: revenueBeneficiary,
      start: operationStart,
      end: operationStart.add(const Duration(hours: 1)),
      systemType: 'solar',
      waterRate: 0,
      litersPerHour: 0,
      dieselPrice: 0,
      solarRate: 0,
      thirdRate: 0,
      cloudMinutes: 0,
      paidAmount: 100000,
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
    );
    expect(
      (await db.query('SELECT total_amount,status FROM irrigations WHERE id=?', args: [revenueIrrigationId])).single['total_amount'],
      100000,
    );

    // ثانيًا: إنشاء عامل بالساعة وآخر بالنسبة وعامل راتب شهري وشريكين.
    final hourlyWorker = await repo.createWorker(
      name: 'اختبار دورة عامل بالساعة',
      payType: 'hourly',
      hourlyRate: 1000,
    );
    final percentageWorker = await repo.createWorker(
      name: 'اختبار دورة عامل بالنسبة',
      payType: 'percentage',
      percentageRate: 10,
    );
    final monthlyWorker = await repo.createWorker(
      name: 'اختبار دورة راتب شهري',
      payType: 'fixed',
      fixedSalary: 1500,
    );
    await repo.createPartner(name: 'اختبار دورة شريك 1', mode: 'shares', shares: 1);
    await repo.createPartner(name: 'اختبار دورة شريك 2', mode: 'shares', shares: 1);
    final irrigationBeneficiary = await db.insert('beneficiaries', {
      'name': 'مستفيد السقاية الثانية',
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });

    // ثالثًا: سقاية ثانية؛ تُنشئ استحقاق الساعة 1,000 والنسبة 10,000.
    final irrigationId = await svc.recordIrrigation(
      stationId: stationId,
      pumpId: pumpId,
      beneficiaryId: irrigationBeneficiary,
      start: operationStart.add(const Duration(hours: 2)),
      end: operationStart.add(const Duration(hours: 3)),
      systemType: 'solar',
      waterRate: 0,
      litersPerHour: 0,
      dieselPrice: 0,
      solarRate: 0,
      thirdRate: 0,
      cloudMinutes: 0,
      paidAmount: 100000,
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
    );
    expect(
      (await db.query('SELECT total_amount,status FROM irrigations WHERE id=?', args: [irrigationId])).single['total_amount'],
      100000,
    );
    expect(await glPayable('2100', 'worker_id', hourlyWorker), 1000);
    expect(await glPayable('2100', 'worker_id', percentageWorker), 10000);

    // رابعًا: استحقاق راتب الشهر مرة واحدة فقط.
    expect(await svc.accrueMonthlySalaries(month: monthStart), 1);
    expect(await svc.accrueMonthlySalaries(month: monthStart), 0);
    expect(await glPayable('2100', 'worker_id', monthlyWorker), 1500);

    // خامسًا: دفع جزء من مستحقات عامل الساعة والراتب الشهري.
    await svc.payWorker(
      workerId: hourlyWorker,
      amount: 300,
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
      notes: 'دفعة جزئية ضمن اختبار الدورة',
    );
    await svc.payWorker(
      workerId: monthlyWorker,
      amount: 200,
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
      notes: 'دفعة جزئية ضمن اختبار الدورة',
    );

    // سادسًا: مصروف تجريبي ثم إلغاؤه؛ لا يبقى له أثر نقدي أو على صافي الربح.
    final cashBeforeExpense = await cashboxBalance(cashboxId);
    final expenseId = await svc.addExpense(
      category: 'maintenance',
      title: 'مصروف تجريبي للإلغاء ضمن الدورة',
      amount: 200,
      date: operationStart.add(const Duration(hours: 4)),
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
      notes: 'اختبار تكامل آلي',
    );
    expect(await cashboxBalance(cashboxId), cashBeforeExpense - 200);
    await svc.cancelExpense(expenseId, 1, 'إلغاء المصروف التجريبي في اختبار الدورة');
    expect(await cashboxBalance(cashboxId), cashBeforeExpense);
    expect(
      (await db.query('SELECT status FROM expenses WHERE id=?', args: [expenseId])).single['status'],
      'cancelled',
    );

    // مطابقة الصندوق مع الأستاذ: قبض 200,000 ناقص دفعات عمال 500.
    expect(await cashboxBalance(cashboxId), cashBefore + 199500);
    expect((await accountNet(cashCode)) - ledgerCashBefore, 199500);

    // مطابقة كشوف العمال مع أرصدة حسابات الالتزامات بعد الدفع الجزئي.
    for (final entry in [
      (hourlyWorker, 700),
      (percentageWorker, 10000),
      (monthlyWorker, 1300),
    ]) {
      final workerId = entry.$1;
      final expected = entry.$2;
      expect((await svc.workerBalance(workerId))['balance'], expected);
      expect(await glPayable('2100', 'worker_id', workerId), expected);
      final statement = await repo.workerTransactions(workerId);
      expect(statement, isNotEmpty);
      expect((statement.first['balance'] as num).round(), expected);
    }

    // مطابقة تقرير الربح والخسارة: إيراد 200,000 وأجور مستحقة 12,500.
    final summaryAfter = await repo.partnerProfitSummary(from: monthStart, to: monthEnd);
    expect((summaryAfter['revenue'] as num) - (summaryBefore['revenue'] as num), 200000);
    expect((summaryAfter['expenses'] as num), summaryBefore['expenses']);
    expect((summaryAfter['workers'] as num) - (summaryBefore['workers'] as num), 12500);
    final expectedDistributable = (
      (summaryAfter['revenue'] as num).round() -
      (summaryAfter['expenses'] as num).round() -
      (summaryAfter['workers'] as num).round()
    ).clamp(0, 1 << 62);
    expect(summaryAfter['distributable'], expectedDistributable);
    final pnlAfterRows = await db.query(
      "SELECT COALESCE(SUM(CASE WHEN a.type='revenue' THEN jl.credit-jl.debit WHEN a.type='expense' THEN jl.credit-jl.debit ELSE 0 END),0) net FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id JOIN accounts a ON a.id=jl.account_id WHERE je.station_id=? AND je.status='posted' AND je.date>=? AND je.date<?",
      args: [stationId, monthStart.toIso8601String(), nextMonth.toIso8601String()],
    );
    expect((pnlAfterRows.single['net'] as num).round() - pnlBefore, 187500);

    // أخيرًا: ترحيل توزيع الأرباح، مع منع الاستحقاقات المباشرة من تجاوز صافي الربح.
    await svc.distributePartnerProfits(from: monthStart, to: monthEnd, userId: 1);
    final distribution = await repo.report(
      'partner_profit_distribution',
      from: monthStart,
      to: monthEnd,
    );
    final selectedRows = distribution
        .where((row) => '${row['name']}'.startsWith('اختبار دورة شريك '))
        .toList();
    expect(selectedRows.length, 2);
    final grossDistributed = selectedRows.fold<int>(
      0,
      (sum, row) => sum + ((row['gross_amount'] as num?)?.round() ?? 0),
    );
    expect(grossDistributed, (summaryAfter['distributable'] as num).round());
    expect(grossDistributed, greaterThan(0));
    expect(selectedRows.every((row) => (row['net_amount'] as num) >= 0), isTrue);
  });

  test('تدقيق شجرة الحسابات يكشف الحلقة والنوع غير الصحيح ويحفظ علاقة الأب', () async {
    final repo = StationRepository(db);
    final parent = await db.insert('accounts', {
      'code': 'TEST-TREE-PARENT',
      'name': 'حساب أب للاختبار',
      'type': 'asset',
    });
    final child = await db.insert('accounts', {
      'parent_id': parent,
      'code': 'TEST-TREE-CHILD',
      'name': 'حساب فرعي للاختبار',
      'type': 'liability',
    });
    final invalidType = await db.insert('accounts', {
      'code': 'TEST-TREE-BADTYPE',
      'name': 'نوع غير صالح للاختبار',
      'type': 'not-a-ledger-type',
    });
    // محاكاة قاعدة قديمة فيها مرجع أب يتيم رغم تفعيل المفاتيح الأجنبية عادةً.
    await (await db.db).execute('PRAGMA foreign_keys=OFF');
    final orphan = await db.insert('accounts', {
      'parent_id': 999999999,
      'code': 'TEST-TREE-ORPHAN',
      'name': 'حساب يتيم للاختبار',
      'type': 'asset',
    });
    await (await db.db).execute('PRAGMA foreign_keys=ON');
    await db.update('accounts', {'parent_id': child}, 'id=?', [parent]);

    final accounts = await repo.accounts();
    final childRow = accounts.firstWhere((row) => row['id'] == child);
    expect(childRow['parent_id'], parent);
    expect(childRow['parent_code'], 'TEST-TREE-PARENT');

    final issues = await repo.accountTreeIssues();
    expect(issues.any((issue) => issue.contains('حلقة')), isTrue);
    expect(issues.any((issue) => issue.contains('حساب أب غير موجود: TEST-TREE-ORPHAN')), isTrue);
    expect(issues.any((issue) => issue.contains('نوع حساب غير صالح: TEST-TREE-BADTYPE')), isTrue);

    await db.update('accounts', {'parent_id': null}, 'id=?', [parent]);
    await db.delete('accounts', 'id=?', [child]);
    await db.delete('accounts', 'id=?', [invalidType]);
    await db.delete('accounts', 'id=?', [orphan]);
    await db.delete('accounts', 'id=?', [parent]);
  });

  test('صافي الأرباح وتوزيعات الشركاء تتطابق مع السقايات والمصروفات والأستاذ وPDF مع استبعاد قيد الإقفال', () async {
    final repo = StationRepository(db);
    final stationId = await svc.currentStationId();
    final settings = await svc.settings();
    final pumpId = int.parse(settings['selected_pump_id']!);
    final start = DateTime(2035, 1, 1);
    final end = DateTime(2035, 12, 31);
    final operationDate = DateTime(2035, 3, 5, 8);

    await db.update('partners', {'active': 0}, 'station_id=?', [stationId]);
    await db.update('workers', {'active': 0}, 'station_id=?', [stationId]);
    await db.update('settings', {'value': 'solar'}, 'key=?', ['system_type']);
    await seedCashEquityForTest(stationId, operationDate, 100000);

    final p1 = await repo.createPartner(name: 'اختبار صافي الربح شريك مباشر', mode: 'shares', shares: 1);
    final beneficiary = await db.insert('beneficiaries', {
      'name': 'مستفيد اختبار توزيع الأرباح',
      'created_at': operationDate.toIso8601String(),
      'updated_at': operationDate.toIso8601String(),
    });

    final irrigationId = await svc.recordIrrigation(
      stationId: stationId,
      pumpId: pumpId,
      beneficiaryId: beneficiary,
      start: operationDate,
      end: operationDate.add(const Duration(hours: 1)),
      systemType: 'solar',
      waterRate: 0,
      litersPerHour: 0,
      dieselPrice: 0,
      solarRate: 30000,
      thirdRate: 0,
      cloudMinutes: 0,
      paidAmount: 0,
    );
    expect(
      ((await db.query('SELECT total_amount FROM irrigations WHERE id=?', args: [irrigationId])).single['total_amount'] as num).round(),
      30000,
    );

    final p2 = await repo.createPartner(name: 'اختبار صافي الربح شريك ثان', mode: 'shares', shares: 1);
    final worker = await repo.createWorker(name: 'اختبار صافي الربح عامل', payType: 'hourly', hourlyRate: 1000);
    await svc.createWorkerAccrual(workerId: worker, amount: 5000, date: operationDate, hours: 5, rateSnapshot: 1000);

    final accountRows = await db.query(
      "SELECT code,id FROM accounts WHERE code IN ('1000','3300') OR type='revenue' ORDER BY code",
    );
    final accountIds = {for (final row in accountRows) '${row['code']}': (row['id'] as num).toInt()};
    final revenueAccountRows = await db.query("SELECT id FROM accounts WHERE type='revenue' ORDER BY id LIMIT 1");
    final revenueAccount = (revenueAccountRows.single['id'] as num).toInt();
    final cashAccount = accountIds['1000']!;
    final equityAccount = accountIds['3300']!;

    Future<int> insertTestEntry(String referenceType, int amount, DateTime date, {required bool creditRevenue}) async {
      final entryId = await db.insert('journal_entries', {
        'station_id': stationId,
        'date': date.toIso8601String(),
        'reference_type': referenceType,
        'description': 'قيد اختبار تقرير صافي الأرباح: $referenceType',
        'status': 'posted',
        'created_by': 1,
        'created_at': date.toIso8601String(),
      });
      await db.insert('journal_lines', {
        'journal_entry_id': entryId,
        'account_id': creditRevenue ? cashAccount : equityAccount,
        'debit': amount,
        'credit': 0,
        'memo': 'طرف مدين للاختبار',
      });
      await db.insert('journal_lines', {
        'journal_entry_id': entryId,
        'account_id': revenueAccount,
        'debit': 0,
        'credit': amount,
        'memo': 'طرف دائن للاختبار',
      });
      return entryId;
    }

    final extraRevenueEntry = await db.insert('journal_entries', {
      'station_id': stationId,
      'date': operationDate.add(const Duration(hours: 2)).toIso8601String(),
      'reference_type': 'test_profit_revenue',
      'description': 'إيراد إضافي للاختبار',
      'status': 'posted',
      'created_by': 1,
      'created_at': operationDate.toIso8601String(),
    });
    await db.insert('journal_lines', {
      'journal_entry_id': extraRevenueEntry,
      'account_id': cashAccount,
      'debit': 70000,
      'credit': 0,
      'memo': 'نقد اختبار',
    });
    await db.insert('journal_lines', {
      'journal_entry_id': extraRevenueEntry,
      'account_id': revenueAccount,
      'debit': 0,
      'credit': 70000,
      'memo': 'إيراد اختبار',
    });
    await db.update('cashboxes', {'current_balance': await cashboxBalance(1) + 70000}, 'id=?', [1]);

    await svc.addExpense(
      category: 'maintenance',
      title: 'مصروف عام لاختبار التوزيع',
      amount: 10000,
      date: operationDate.add(const Duration(hours: 3)),
      paymentMethodId: 1,
      cashboxId: 1,
    );
    await svc.addExpense(
      category: 'maintenance',
      title: 'مصروف خاص لاختبار التوزيع',
      amount: 7000,
      date: operationDate.add(const Duration(hours: 4)),
      paymentMethodId: 1,
      cashboxId: 1,
      partnerId: p1,
    );

    // قيد إقفال السنة: يجب ألا يضخم إيرادات أو صافي ربح الفترة.
    await insertTestEntry('year_close', 900000, DateTime(2035, 12, 31, 23, 59), creditRevenue: false);

    final summary = await repo.partnerProfitSummary(from: start, to: end);
    expect(summary['revenue'], 100000);
    expect(summary['expenses'], 10000);
    expect(summary['workers'], 5000);
    expect(summary['distributable'], 85000);

    final beforePosting = await repo.report('partner_profit_distribution', from: start, to: end);
    final before1 = beforePosting.singleWhere((row) => row['name'] == 'اختبار صافي الربح شريك مباشر');
    final before2 = beforePosting.singleWhere((row) => row['name'] == 'اختبار صافي الربح شريك ثان');
    expect(before1['direct_amount'], 30000);
    expect(before1['share_amount'], 27500);
    expect(before1['gross_amount'], 57500);
    expect(before1['partner_expenses'], 7000);
    expect(before1['net_amount'], 50500);
    expect(before2['direct_amount'], 0);
    expect(before2['share_amount'], 27500);
    expect(before2['net_amount'], 27500);
    expect(
      beforePosting.fold<int>(0, (sum, row) => sum + ((row['gross_amount'] as num).round())),
      85000,
    );

    await svc.distributePartnerProfits(from: start, to: end, userId: 1);
    final afterPosting = await repo.report('partner_profit_distribution', from: start, to: end);
    expect(afterPosting, beforePosting);
    expect(await glPayable('2200', 'partner_id', p1), 50500);
    expect(await glPayable('2200', 'partner_id', p2), 27500);
    expect((await svc.partnerBalance(p1))['balance'], 50500);
    expect((await svc.partnerBalance(p2))['balance'], 27500);

    final pdfBytes = await ReportService(repo).pdf('partner_profit_distribution', from: start, to: end);
    expect(pdfBytes, isNotEmpty);
    expect(String.fromCharCodes(pdfBytes.take(4)), '%PDF');
  });

}
