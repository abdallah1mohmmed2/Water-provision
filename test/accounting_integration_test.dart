// اختبارات تكامل على قاعدة SQLite حقيقية (sqflite_common_ffi).
// تغطي الإصلاحات: اتجاه دفع العامل، منع ازدواج الديزل، عدم تضاعف السلفة،
// القيد العكسي عند الإلغاء، وتاريخ القيد = تاريخ العملية.
// ملاحظة: كُتبت دون تشغيل (لا يوجد Flutter SDK في بيئة الكتابة) — شغّلها بـ flutter test.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';
import 'package:saqia_station/domain/accounting/accounting_service.dart';
import 'package:saqia_station/services/admin_service.dart';
import 'package:saqia_station/services/backup_service.dart';

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

  test('رصيد العامل يشمل الافتتاحي والمرحّل', () async {
    final w = await db.insert('workers', {
      'name': 'عامل برصيد افتتاحي',
      'pay_type': 'fixed',
      'opening_balance': 1000,
      'carried_balance': 200,
    });
    expect((await svc.workerBalance(w))['balance'], 1200);
  });

  test('رصيد الشريك يشمل الافتتاحي والمرحّل', () async {
    final p = await db.insert('partners', {
      'name': 'شريك',
      'ownership_mode': 'shares',
      'opening_balance': 0,
      'carried_balance': 700,
    });
    expect((await svc.partnerBalance(p))['balance'], 700);
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
    await AdminService(db).closePeriod(
      stationId: 1, start: DateTime(2020, 1, 1), end: DateTime(2020, 12, 31), userId: 1,
    );

    Future<int> count(String t) async =>
        (await db.query('SELECT COUNT(*) n FROM $t')).first['n'] as int;
    final clouds = await count('cloud_periods');
    final closures = await count('period_closures');
    final codes = await count('beneficiary_auth_codes');
    expect(clouds, greaterThan(0));
    expect(closures, greaterThan(0));

    final json = await svc.exportStateJson();
    final backup = BackupService(svc);
    final bytes = Uint8List.fromList(utf8.encode(json));
    expect((await backup.validatePortableJson(bytes))['valid'], true);
    await backup.restorePortableJson(bytes);
    expect(await count('cloud_periods'), clouds);
    expect(await count('period_closures'), closures);
    expect(await count('beneficiary_auth_codes'), codes);

    // ملف قديم بلا الجداول الجديدة: يُقبل، ولا تُفتح الفترات المغلقة.
    final old = jsonDecode(json) as Map<String, dynamic>;
    for (final k in AccountingService.optionalPortableTables) old.remove(k);
    final oldBytes = Uint8List.fromList(utf8.encode(jsonEncode(old)));
    expect((await backup.validatePortableJson(oldBytes))['valid'], true);
    await backup.restorePortableJson(oldBytes);
    expect(await count('period_closures'), closures);
  });

  // ---------- تطابق الأرقام بين الشاشات ----------
  test('كشف المستفيد: الرصيد الجاري الأخير = beneficiaryBalance (دفعات + سلف الديزل)', () async {
    await useSolar6000();
    final repo = StationRepository(db);
    final now = DateTime.now().toIso8601String();
    final b = await db.insert('beneficiaries', {
      'name': 'مستفيد كشف', 'opening_balance': 1000, 'created_at': now, 'updated_at': now,
    });
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
    final p = await repo.createPartner(name: 'شريك افتتاحي', mode: 'shares', opening: -300);
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

  test('الصندوق والشريك الجديدان يتبعان محطة المضخة المحددة لا الرقم 1', () async {
    final repo = StationRepository(db);
    final now = DateTime(2026, 1, 1).toIso8601String();
    final st = await db.insert('stations', {'name': 'محطة ثانية', 'created_at': now, 'updated_at': now});
    final pump = await db.insert('pumps', {'station_id': st, 'name': 'مضخة 2', 'system_type': 'diesel', 'active': 1});
    await db.update('settings', {'value': '$pump'}, 'key=?', ['selected_pump_id']);
    try {
      expect(await svc.currentStationId(), st);
      final cb = await repo.createCashbox(name: 'صندوق المحطة الثانية');
      final pt = await repo.createPartner(name: 'شريك المحطة الثانية', mode: 'shares');
      expect((await db.query('SELECT station_id FROM cashboxes WHERE id=?', args: [cb])).first['station_id'], st);
      expect((await db.query('SELECT station_id FROM partners WHERE id=?', args: [pt])).first['station_id'], st);
    } finally {
      await db.update('settings', {'value': '1'}, 'key=?', ['selected_pump_id']);
    }
  });
}
