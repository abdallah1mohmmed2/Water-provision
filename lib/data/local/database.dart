import '../../core/app_clock.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

class AppDatabase {
  static final AppDatabase instance = AppDatabase._();
  AppDatabase._();
  Database? _db;
  Future<Database> get db async {
    if (_db != null) return _db!;
    if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
    } else if (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'saqia_station_v2.db');
    _db = await openDatabase(
      path,
      version: 22,
      // المفاتيح الأجنبية تُعطَّل أثناء الإنشاء/الترقية لأن SQLite لا يسمح بتغيير
      // PRAGMA foreign_keys داخل معاملة الترقية، وتُفعَّل في onOpen بعد انتهائها.
      onConfigure: (d) async => d.execute('PRAGMA foreign_keys=OFF'),
      onCreate: (d, v) async => _create(d),
      onUpgrade: (d, oldV, newV) async => _upgrade(d, oldV, newV),
      onOpen: (d) async => d.execute('PRAGMA foreign_keys=ON'),
    );
    return _db!;
  }

  Future<void> _create(Database d) async {
    final sql = await rootBundle.loadString('assets/db/001_initial.sql');
    for (final statement in sql.split(';')) {
      final s = statement.trim();
      if (s.isNotEmpty) await d.execute(s);
    }
    await _createHelpers(d);
    await d.execute('CREATE INDEX IF NOT EXISTS idx_journal_station_date ON journal_entries(station_id,date)');
    await d.execute('CREATE INDEX IF NOT EXISTS idx_period_station_range ON period_closures(station_id,period_start,period_end)');
    await _seed(d);
  }

  Future<void> _upgrade(Database d, int oldV, int newV) async {
    await _createHelpers(d);
    if (oldV < 2) {
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sessions_status ON irrigation_sessions(status)',
      );
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_bookings_status ON booking_requests(status)',
      );
    }
    if (oldV < 3) {
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_status ON sync_queue(status)',
      );
    }
    if (oldV < 4) {
      await d.execute(
        'CREATE TABLE IF NOT EXISTS beneficiary_auth_codes (id INTEGER PRIMARY KEY, beneficiary_id INTEGER NOT NULL REFERENCES beneficiaries(id), code_hash TEXT NOT NULL, expires_at TEXT NOT NULL, used_at TEXT, attempts INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL)',
      );
      await d.execute(
        'CREATE TABLE IF NOT EXISTS period_closures (id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, period_start TEXT NOT NULL, period_end TEXT NOT NULL, period_end_exclusive TEXT, closed_at TEXT NOT NULL, closed_by INTEGER NOT NULL, opening_transfer INTEGER NOT NULL DEFAULT 0, close_journal_entry_id INTEGER, net_profit INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT \'locked\', reconciliation_json TEXT, reopened_at TEXT, reopened_by INTEGER, reopen_reason TEXT, reopen_journal_entry_id INTEGER, notes TEXT)',
      );
      await d.execute(
        'CREATE TABLE IF NOT EXISTS beneficiary_sessions (id INTEGER PRIMARY KEY, beneficiary_id INTEGER NOT NULL REFERENCES beneficiaries(id), token_hash TEXT UNIQUE NOT NULL, expires_at TEXT NOT NULL, created_at TEXT NOT NULL, revoked_at TEXT)',
      );
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_beneficiary_sessions_token ON beneficiary_sessions(token_hash)',
      );
    }
    if (oldV < 5) {
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_irrigations_status ON irrigations(status)',
      );
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_payments_beneficiary ON payments(beneficiary_id,date)',
      );
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_diesel_beneficiary ON diesel_movements(beneficiary_id,date)',
      );
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_journal_lines_account ON journal_lines(account_id,journal_entry_id)',
      );
    }
    if (oldV < 6) {
      await d.execute(
        'ALTER TABLE payment_methods ADD COLUMN ledger_account_code TEXT',
      );
      await d.execute(
        "UPDATE payment_methods SET ledger_account_code=CASE type WHEN 'cash' THEN '1000' WHEN 'bank_transfer' THEN '1100' WHEN 'wallet' THEN '1120' ELSE '1000' END WHERE ledger_account_code IS NULL",
      );
      await d.execute(
        "INSERT OR IGNORE INTO accounts(id,code,name,type) VALUES(17,'1120','المحافظ الإلكترونية','asset')",
      );
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_payments_date ON payments(date)',
      );
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_expenses_date ON expenses(date)',
      );
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_diesel_date ON diesel_movements(date)',
      );
    }
    if (oldV < 7) {
      await d.execute(
        'ALTER TABLE notifications ADD COLUMN snoozed_until TEXT',
      );
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_notifications_beneficiary ON notifications(beneficiary_id,created_at)',
      );
    }
    if (oldV < 8) {
      for (final table in [
        'beneficiaries',
        'partners',
        'workers',
        'cashboxes',
        'payment_methods',
      ]) {
        try {
          await d.execute(
            'ALTER TABLE $table ADD COLUMN station_id INTEGER NOT NULL DEFAULT 1 REFERENCES stations(id)',
          );
        } catch (_) {}
        await d.execute(
          'CREATE INDEX IF NOT EXISTS idx_${table}_station ON $table(station_id)',
        );
      }
    }
    if (oldV < 9) {
      // إصلاح قواعد البيانات المنشأة بإصدارات أقدم: بعض الأعمدة كانت موجودة في المخطط الجديد
      // لكنها لم تكن تضاف عند الترقية، مما كان يؤدي إلى خطأ carried_diesel_liters.
      for (final item in [
        ['beneficiaries', 'opening_diesel_liters', 'REAL NOT NULL DEFAULT 0'],
        ['beneficiaries', 'carried_diesel_liters', 'REAL NOT NULL DEFAULT 0'],
        ['cashboxes', 'station_id', 'INTEGER NOT NULL DEFAULT 1 REFERENCES stations(id)'],
        ['payment_methods', 'station_id', 'INTEGER NOT NULL DEFAULT 1 REFERENCES stations(id)'],
        ['partners', 'station_id', 'INTEGER NOT NULL DEFAULT 1 REFERENCES stations(id)'],
        ['workers', 'station_id', 'INTEGER NOT NULL DEFAULT 1 REFERENCES stations(id)'],
      ]) {
        try {
          final info = await d.rawQuery("PRAGMA table_info(${item[0]})");
          final exists = info.any((x) => x['name'] == item[1]);
          if (!exists) await d.execute("ALTER TABLE ${item[0]} ADD COLUMN ${item[1]} ${item[2]}");
        } catch (_) {}
      }
      await d.insert('settings', {
        'key': 'selected_pump_id',
        'value': '1',
        'updated_at': AppClock.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (oldV < 10) {
      // إضافة صاحب حساب السقاية للعامل أو الشريك مع الحفاظ على السجلات القديمة.
      // نبني الجدول الجديد باسم مؤقت ثم نحذف القديم ونعيد التسمية؛ إعادة تسمية الجدول القديم
      // كانت تُحوّل مراجع المفاتيح الأجنبية في الجداول التابعة إلى اسم محذوف.
      // المفاتيح الأجنبية معطّلة هنا (انظر onConfigure) فلا تُفعَّل حذوفات ضمنية عند DROP.
      await d.execute('''CREATE TABLE irrigations_new (id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL REFERENCES stations(id), pump_id INTEGER NOT NULL REFERENCES pumps(id), beneficiary_id INTEGER REFERENCES beneficiaries(id), worker_id INTEGER REFERENCES workers(id), partner_id INTEGER REFERENCES partners(id), party_type TEXT NOT NULL DEFAULT 'beneficiary' CHECK(party_type IN ('beneficiary','worker','partner')), booking_id INTEGER REFERENCES booking_requests(id), queue_entry_id INTEGER REFERENCES queue_entries(id), session_id INTEGER REFERENCES irrigation_sessions(id), date TEXT NOT NULL, start_datetime TEXT NOT NULL, end_datetime TEXT NOT NULL, minutes INTEGER NOT NULL, system_type TEXT NOT NULL, water_hourly_rate_snapshot INTEGER NOT NULL DEFAULT 0, diesel_liters_per_hour_snapshot REAL NOT NULL DEFAULT 0, diesel_price_snapshot INTEGER NOT NULL DEFAULT 0, solar_hourly_rate_snapshot INTEGER NOT NULL DEFAULT 0, third_type_hourly_rate_snapshot INTEGER NOT NULL DEFAULT 0, cloud_minutes INTEGER NOT NULL DEFAULT 0, chargeable_minutes INTEGER NOT NULL, water_amount INTEGER NOT NULL DEFAULT 0, diesel_amount INTEGER NOT NULL DEFAULT 0, total_amount INTEGER NOT NULL DEFAULT 0, paid_amount INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL, override_waiting_period INTEGER NOT NULL DEFAULT 0, override_reason TEXT, notes TEXT, created_by INTEGER, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''');
      await d.execute('''INSERT INTO irrigations_new (id,station_id,pump_id,beneficiary_id,booking_id,queue_entry_id,session_id,date,start_datetime,end_datetime,minutes,system_type,water_hourly_rate_snapshot,diesel_liters_per_hour_snapshot,diesel_price_snapshot,solar_hourly_rate_snapshot,third_type_hourly_rate_snapshot,cloud_minutes,chargeable_minutes,water_amount,diesel_amount,total_amount,paid_amount,status,override_waiting_period,override_reason,notes,created_by,created_at,updated_at) SELECT id,station_id,pump_id,beneficiary_id,booking_id,queue_entry_id,session_id,date,start_datetime,end_datetime,minutes,system_type,water_hourly_rate_snapshot,diesel_liters_per_hour_snapshot,diesel_price_snapshot,solar_hourly_rate_snapshot,third_type_hourly_rate_snapshot,cloud_minutes,chargeable_minutes,water_amount,diesel_amount,total_amount,paid_amount,status,override_waiting_period,override_reason,notes,created_by,created_at,updated_at FROM irrigations''');
      await d.execute('DROP TABLE irrigations');
      await d.execute('ALTER TABLE irrigations_new RENAME TO irrigations');
      await d.execute('CREATE INDEX IF NOT EXISTS idx_irrigations_beneficiary_date ON irrigations(beneficiary_id,date)');
      await d.execute('CREATE INDEX IF NOT EXISTS idx_irrigations_pump_time ON irrigations(pump_id,start_datetime,end_datetime)');
    }
    if (oldV < 11) {
      await d.execute('''CREATE TABLE IF NOT EXISTS cloud_periods (id INTEGER PRIMARY KEY, irrigation_id INTEGER NOT NULL REFERENCES irrigations(id) ON DELETE CASCADE, start_datetime TEXT NOT NULL, end_datetime TEXT NOT NULL, minutes INTEGER NOT NULL, created_at TEXT NOT NULL)''');
      await d.execute('CREATE INDEX IF NOT EXISTS idx_cloud_periods_irrigation ON cloud_periods(irrigation_id,start_datetime,end_datetime)');
    }
    if (oldV < 12) {
      // إصلاح قواعد رُقّيت سابقًا من إصدار أقدم من 10 بالتسلسل المعطوب، حيث بقيت مراجع
      // المفاتيح الأجنبية تشير إلى irrigations_old_v10 المحذوف فتفشل الإدخالات في الجداول التابعة.
      try {
        final bad = await d.rawQuery(
            "SELECT name FROM sqlite_master WHERE sql LIKE '%irrigations_old_v10%'");
        if (bad.isNotEmpty) {
          final sv = Sqflite.firstIntValue(await d.rawQuery('PRAGMA schema_version')) ?? 0;
          await d.execute('PRAGMA writable_schema=ON');
          await d.execute(
              "UPDATE sqlite_master SET sql=replace(replace(sql,'\"irrigations_old_v10\"','irrigations'),'irrigations_old_v10','irrigations') WHERE sql LIKE '%irrigations_old_v10%'");
          await d.execute('PRAGMA schema_version=${sv + 1}');
          await d.execute('PRAGMA writable_schema=OFF');
        }
      } catch (_) {
        // لا نمنع فتح التطبيق إن لم يسمح النظام بتعديل المخطط؛ تبقى القاعدة كما هي.
      }
    }
    if (oldV < 13) {
      await _migrateV13(d);
    }
    if (oldV < 14) {
      await _migrateV14(d);
    }
    if (oldV < 15) {
      await _migrateV15(d);
    }
    if (oldV < 16) {
      await _migrateV16(d);
    }
    if (oldV < 17) {
      await _migrateV17(d);
    }
    if (oldV < 18) {
      await d.execute(
        'CREATE TABLE IF NOT EXISTS cash_reconciliations (id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL REFERENCES stations(id), period_start TEXT NOT NULL, period_end_exclusive TEXT NOT NULL, account_code TEXT NOT NULL, account_name TEXT NOT NULL, currency TEXT NOT NULL, source_type TEXT NOT NULL CHECK(source_type IN (\'cash_count\',\'bank_statement\',\'wallet_statement\',\'other\')), book_balance INTEGER NOT NULL, actual_balance INTEGER NOT NULL, difference INTEGER NOT NULL, reference TEXT, notes TEXT, status TEXT NOT NULL CHECK(status IN (\'matched\',\'variance\')), created_by INTEGER NOT NULL REFERENCES app_users(id), approved_by INTEGER REFERENCES app_users(id), approved_at TEXT, created_at TEXT NOT NULL)',
      );
      await d.execute(
        'CREATE INDEX IF NOT EXISTS idx_cash_rec_period ON cash_reconciliations(station_id,period_start,period_end_exclusive,account_code,id)',
      );
    }
    if (oldV < 19) {
      await d.execute(
        "CREATE TABLE IF NOT EXISTS general_accounts (id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL DEFAULT 1 REFERENCES stations(id), name TEXT NOT NULL, phone TEXT, address TEXT, opening_balance INTEGER NOT NULL DEFAULT 0, notes TEXT, active INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)",
      );
      await d.execute(
        "CREATE TABLE IF NOT EXISTS general_account_transactions (id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL DEFAULT 1 REFERENCES stations(id), account_id INTEGER NOT NULL REFERENCES general_accounts(id), date TEXT NOT NULL, type TEXT NOT NULL CHECK(type IN ('receipt','payment')), amount INTEGER NOT NULL CHECK(amount > 0), reference_number TEXT, notes TEXT, created_by INTEGER REFERENCES app_users(id), created_at TEXT NOT NULL)",
      );
      await d.execute('CREATE INDEX IF NOT EXISTS idx_general_accounts_station_name ON general_accounts(station_id,name)');
      await d.execute('CREATE INDEX IF NOT EXISTS idx_general_account_transactions_account_date ON general_account_transactions(account_id,date,id)');
    }
    if (oldV < 21) {
      // ربط مستخدم التطبيق بسجل عامل موجود ليكون المحاسب مستخدمًا وعاملًا في الوقت نفسه.
      // إضافة العمود لا تغيّر أي سجل عامل أو حركة مالية سابقة.
      final userCols = await d.rawQuery('PRAGMA table_info(app_users)');
      if (!userCols.any((x) => x['name'] == 'accountant_worker_id')) {
        await d.execute(
          'ALTER TABLE app_users ADD COLUMN accountant_worker_id INTEGER REFERENCES workers(id)',
        );
      }
    }
    if (oldV < 22) {
      // سجل سندات تسويات المحاسب: ترقية إضافية لا تمس السجلات أو الحركات القائمة.
      await d.execute("CREATE TABLE IF NOT EXISTS accountant_settlements (id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL REFERENCES stations(id), worker_id INTEGER NOT NULL REFERENCES workers(id), partner_id INTEGER REFERENCES partners(id), cashbox_id INTEGER REFERENCES cashboxes(id), kind TEXT NOT NULL CHECK(kind IN ('deposit','partner_payout')), voucher_number TEXT NOT NULL, source_voucher_reference TEXT, worker_transaction_id INTEGER NOT NULL REFERENCES worker_transactions(id), partner_transaction_id INTEGER REFERENCES partner_transactions(id), journal_entry_id INTEGER NOT NULL REFERENCES journal_entries(id), amount INTEGER NOT NULL CHECK(amount>0), created_at TEXT NOT NULL, created_by INTEGER REFERENCES app_users(id), UNIQUE(station_id,voucher_number))");
      await d.execute('CREATE INDEX IF NOT EXISTS idx_accountant_settlements_worker_date ON accountant_settlements(worker_id,created_at,id)');
    }
  }

  Future<void> _migrateV15(Database d) async {
    final cols = await d.rawQuery('PRAGMA table_info(irrigations)');
    if (!cols.any((x) => x['name'] == 'operator_worker_id')) {
      await d.execute('ALTER TABLE irrigations ADD COLUMN operator_worker_id INTEGER REFERENCES workers(id)');
    }
    await d.execute('CREATE INDEX IF NOT EXISTS idx_irrigations_operator_worker ON irrigations(operator_worker_id,date)');
  }

  /// V16: ربط قيود الأستاذ بالمحطة وإضافة بيانات الإقفال الختامي.
  Future<void> _migrateV16(Database d) async {
    final journalCols = await d.rawQuery('PRAGMA table_info(journal_entries)');
    if (!journalCols.any((x) => x['name'] == 'station_id')) {
      await d.execute('ALTER TABLE journal_entries ADD COLUMN station_id INTEGER REFERENCES stations(id)');
    }
    final closureCols = await d.rawQuery('PRAGMA table_info(period_closures)');
    for (final c in const [
      ['period_end_exclusive', 'TEXT'],
      ['close_journal_entry_id', 'INTEGER'],
      ['net_profit', 'INTEGER NOT NULL DEFAULT 0'],
      ['status', "TEXT NOT NULL DEFAULT 'locked'"],
    ]) {
      if (!closureCols.any((x) => x['name'] == c[0])) {
        await d.execute('ALTER TABLE period_closures ADD COLUMN ${c[0]} ${c[1]}');
      }
    }
    final stations = await d.rawQuery('SELECT id FROM stations ORDER BY id');
    if (stations.length == 1) {
      await d.rawUpdate('UPDATE journal_entries SET station_id=? WHERE station_id IS NULL', [stations.first['id']]);
    }
    await d.execute('CREATE INDEX IF NOT EXISTS idx_journal_station_date ON journal_entries(station_id,date)');
    await d.execute('CREATE INDEX IF NOT EXISTS idx_period_station_range ON period_closures(station_id,period_start,period_end)');
    await d.insert('accounts', {'code': '3300', 'name': 'الأرباح المبقاة', 'type': 'equity'}, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> _migrateV17(Database d) async {
    final cols = await d.rawQuery('PRAGMA table_info(period_closures)');
    for (final c in const [
      ['reconciliation_json', 'TEXT'],
      ['reopened_at', 'TEXT'],
      ['reopened_by', 'INTEGER'],
      ['reopen_reason', 'TEXT'],
      ['reopen_journal_entry_id', 'INTEGER'],
    ]) {
      if (!cols.any((x) => x['name'] == c[0])) {
        await d.execute('ALTER TABLE period_closures ADD COLUMN ${c[0]} ${c[1]}');
      }
    }
  }

  /// V14: ربط حركات الشريك بأصلها (مرجع + منفّذ) كحركات العامل، وحساب مستقل لحصص الشركاء.
  Future<void> _migrateV14(Database d) async {
    final cols = await d.rawQuery('PRAGMA table_info(partner_transactions)');
    for (final c in const [
      ['reference_type', 'TEXT'],
      ['reference_id', 'INTEGER'],
      ['created_by', 'INTEGER'],
    ]) {
      if (!cols.any((x) => x['name'] == c[0])) {
        await d.execute('ALTER TABLE partner_transactions ADD COLUMN ${c[0]} ${c[1]}');
      }
    }
    await d.insert('accounts', {
      'code': '3200',
      'name': 'حصص الشركاء من الأرباح',
      'type': 'equity',
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    // قيود الحصص السابقة كانت على 5000 «مصروف العمال»؛ تُنقل إلى 3200 مع قيود عكسها.
    final a5000 = await _acc(d, '5000');
    final a3200 = await _acc(d, '3200');
    if (a5000 != null && a3200 != null) {
      await d.execute(
        "UPDATE journal_lines SET account_id=? WHERE account_id=? AND journal_entry_id IN (SELECT id FROM journal_entries WHERE reference_type='partner' OR (reference_type='reversal' AND description LIKE '%حصة شريك%'))",
        [a3200, a5000],
      );
    }
  }

  /// V13: توحيد اشتقاق حساب الصندوق، وقيود الأرصدة الافتتاحية، وفصل «عكس سقاية الشريك».
  Future<void> _migrateV13(Database d) async {
    final cols = await d.rawQuery('PRAGMA table_info(cashboxes)');
    if (!cols.any((x) => x['name'] == 'ledger_account_code')) {
      await d.execute('ALTER TABLE cashboxes ADD COLUMN ledger_account_code TEXT');
    }
    // حساب الصندوق = حساب أول طريقة دفع مفعّلة مرتبطة به (نفس ما كان يفعله التحويل)، وإلا الصندوق النقدي.
    await d.execute(
      "UPDATE cashboxes SET ledger_account_code=COALESCE((SELECT COALESCE(NULLIF(pm.ledger_account_code,''),CASE pm.type WHEN 'bank_transfer' THEN '1100' WHEN 'wallet' THEN '1120' ELSE '1000' END) FROM payment_methods pm WHERE pm.cashbox_id=cashboxes.id AND pm.active=1 ORDER BY pm.id LIMIT 1),'1000') WHERE ledger_account_code IS NULL OR ledger_account_code=''",
    );
    // طريقة الدفع المرتبطة بصندوق ترث حسابه، فلا يتباعد القيد عن الصندوق.
    await d.execute(
      "UPDATE payment_methods SET ledger_account_code=(SELECT c.ledger_account_code FROM cashboxes c WHERE c.id=payment_methods.cashbox_id) WHERE cashbox_id IS NOT NULL AND EXISTS (SELECT 1 FROM cashboxes c WHERE c.id=payment_methods.cashbox_id)",
    );
    // عكس سقاية الشريك كان يُسجَّل «مساهمة» فتتضخم الأرباح؛ يصبح نوعًا مستقلًا.
    await d.execute(
      "UPDATE partner_transactions SET type='irrigation_reversal' WHERE type='contribution' AND notes LIKE 'عكس سقاية رقم%'",
    );
    // قيمة «keep» القديمة في سياسة الغياب تُوحَّد مع القيمة الافتراضية.
    await d.execute("UPDATE settings SET value='keep_order' WHERE key='absence_policy' AND value='keep'");
    await _backfillOpeningEntries(d);
  }

  Future<int?> _acc(Database d, String code) async {
    final r = await d.rawQuery('SELECT id FROM accounts WHERE code=?', [code]);
    return r.isEmpty ? null : (r.first['id'] as num).toInt();
  }

  /// يرحّل قيدًا لكل رصيد افتتاحي/مرحّل قائم لم يُقيَّد من قبل (صناديق ومستفيدون).
  Future<void> _backfillOpeningEntries(Database d) async {
    final now = AppClock.now().toIso8601String();
    final eq3000 = await _acc(d, '3000');
    final eq3100 = await _acc(d, '3100');
    final ar = await _acc(d, '1200');
    if (eq3000 == null || eq3100 == null || ar == null) return;

    Future<void> post(String refType, int refId, String desc, String date,
        List<Map<String, Object?>> lines) async {
      final id = await d.insert('journal_entries', {
        'date': date,
        'reference_type': refType,
        'reference_id': refId,
        'description': desc,
        'status': 'posted',
        'created_by': null,
        'created_at': now,
      });
      for (final l in lines) {
        await d.insert('journal_lines', {...l, 'journal_entry_id': id});
      }
    }

    final boxes = await d.rawQuery(
      "SELECT c.id,c.name,c.opening_balance,c.ledger_account_code FROM cashboxes c WHERE c.opening_balance>0 AND NOT EXISTS (SELECT 1 FROM journal_entries je WHERE je.reference_type='cashbox_opening' AND je.reference_id=c.id)",
    );
    for (final b in boxes) {
      final cash = await _acc(d, '${b['ledger_account_code'] ?? '1000'}') ?? await _acc(d, '1000');
      if (cash == null) continue;
      final amt = (b['opening_balance'] as num).round();
      await post('cashbox_opening', (b['id'] as num).toInt(), 'رصيد افتتاحي للصندوق ${b['name']}', now, [
        {'account_id': cash, 'debit': amt, 'credit': 0},
        {'account_id': eq3000, 'debit': 0, 'credit': amt},
      ]);
    }

    final bens = await d.rawQuery('SELECT id,name,opening_balance,carried_balance,created_at FROM beneficiaries');
    for (final b in bens) {
      final id = (b['id'] as num).toInt();
      final date = '${b['created_at'] ?? now}';
      for (final spec in [
        ('beneficiary_opening', (b['opening_balance'] as num?)?.round() ?? 0, eq3000, 'رصيد افتتاحي للمستفيد'),
        ('beneficiary_carried', (b['carried_balance'] as num?)?.round() ?? 0, eq3100, 'رصيد مرحَّل للمستفيد'),
      ]) {
        final amt = spec.$2;
        if (amt == 0) continue;
        final exists = await d.rawQuery(
          'SELECT 1 FROM journal_entries WHERE reference_type=? AND reference_id=? LIMIT 1',
          [spec.$1, id],
        );
        if (exists.isNotEmpty) continue;
        // موجب = عليه: مدين ذمم المستفيدين. سالب = له: دائن ذمم المستفيدين.
        final owes = amt > 0;
        final abs = amt.abs();
        await post(spec.$1, id, '${spec.$4} ${b['name']}', date, [
          {'account_id': ar, 'beneficiary_id': id, 'debit': owes ? abs : 0, 'credit': owes ? 0 : abs},
          {'account_id': spec.$3, 'debit': owes ? 0 : abs, 'credit': owes ? abs : 0},
        ]);
      }
    }
  }

  Future<void> _createHelpers(Database d) async {
    await d.execute(
      'CREATE TABLE IF NOT EXISTS app_users (id INTEGER PRIMARY KEY, station_id INTEGER, name TEXT NOT NULL, phone TEXT, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, role TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1, accountant_worker_id INTEGER REFERENCES workers(id), created_at TEXT NOT NULL)',
    );
    await d.execute(
      'CREATE TABLE IF NOT EXISTS notification_templates (key TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL, updated_at TEXT NOT NULL)',
    );
    await d.execute(
      'CREATE TABLE IF NOT EXISTS report_runs (id INTEGER PRIMARY KEY, report_key TEXT NOT NULL, filters_json TEXT NOT NULL, generated_at TEXT NOT NULL, row_count INTEGER NOT NULL DEFAULT 0, duration_ms INTEGER NOT NULL DEFAULT 0)',
    );
    await d.execute(
      'CREATE TABLE IF NOT EXISTS performance_metrics (id INTEGER PRIMARY KEY, screen TEXT NOT NULL, opened_at TEXT NOT NULL, open_ms INTEGER NOT NULL, query_ms INTEGER NOT NULL, pdf_ms INTEGER NOT NULL DEFAULT 0)',
    );
    await d.execute(
      'CREATE TABLE IF NOT EXISTS period_closures (id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, period_start TEXT NOT NULL, period_end TEXT NOT NULL, period_end_exclusive TEXT, closed_at TEXT NOT NULL, closed_by INTEGER NOT NULL, opening_transfer INTEGER NOT NULL DEFAULT 0, close_journal_entry_id INTEGER, net_profit INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT \'locked\', reconciliation_json TEXT, reopened_at TEXT, reopened_by INTEGER, reopen_reason TEXT, reopen_journal_entry_id INTEGER, notes TEXT)',
    );
    await d.execute(
      'CREATE TABLE IF NOT EXISTS cash_reconciliations (id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL REFERENCES stations(id), period_start TEXT NOT NULL, period_end_exclusive TEXT NOT NULL, account_code TEXT NOT NULL, account_name TEXT NOT NULL, currency TEXT NOT NULL, source_type TEXT NOT NULL CHECK(source_type IN (\'cash_count\',\'bank_statement\',\'wallet_statement\',\'other\')), book_balance INTEGER NOT NULL, actual_balance INTEGER NOT NULL, difference INTEGER NOT NULL, reference TEXT, notes TEXT, status TEXT NOT NULL CHECK(status IN (\'matched\',\'variance\')), created_by INTEGER NOT NULL REFERENCES app_users(id), approved_by INTEGER REFERENCES app_users(id), approved_at TEXT, created_at TEXT NOT NULL)',
    );
    await d.execute(
      'CREATE INDEX IF NOT EXISTS idx_cash_rec_period ON cash_reconciliations(station_id,period_start,period_end_exclusive,account_code,id)',
    );
    await d.execute(
      'CREATE TABLE IF NOT EXISTS beneficiary_auth_codes (id INTEGER PRIMARY KEY, beneficiary_id INTEGER NOT NULL REFERENCES beneficiaries(id), code_hash TEXT NOT NULL, expires_at TEXT NOT NULL, used_at TEXT, attempts INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL)',
    );
    await d.execute(
      'CREATE TABLE IF NOT EXISTS period_closures (id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, period_start TEXT NOT NULL, period_end TEXT NOT NULL, period_end_exclusive TEXT, closed_at TEXT NOT NULL, closed_by INTEGER NOT NULL, opening_transfer INTEGER NOT NULL DEFAULT 0, close_journal_entry_id INTEGER, net_profit INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT \'locked\', reconciliation_json TEXT, reopened_at TEXT, reopened_by INTEGER, reopen_reason TEXT, reopen_journal_entry_id INTEGER, notes TEXT)',
    );
    await d.execute(
      'CREATE TABLE IF NOT EXISTS beneficiary_sessions (id INTEGER PRIMARY KEY, beneficiary_id INTEGER NOT NULL REFERENCES beneficiaries(id), token_hash TEXT UNIQUE NOT NULL, expires_at TEXT NOT NULL, created_at TEXT NOT NULL, revoked_at TEXT)',
    );
    await d.execute(
      'CREATE TABLE IF NOT EXISTS beneficiary_credentials (id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL REFERENCES stations(id), beneficiary_id INTEGER NOT NULL REFERENCES beneficiaries(id), username_normalized TEXT NOT NULL, password_phc TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1)), created_at TEXT NOT NULL, updated_at TEXT NOT NULL, created_by INTEGER REFERENCES app_users(id), updated_by INTEGER REFERENCES app_users(id))',
    );
    await d.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_beneficiary_credentials_username ON beneficiary_credentials(station_id, username_normalized)');
    await d.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_beneficiary_credentials_owner ON beneficiary_credentials(station_id, beneficiary_id)');
    await d.execute("CREATE TABLE IF NOT EXISTS accountant_settlements (id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL REFERENCES stations(id), worker_id INTEGER NOT NULL REFERENCES workers(id), partner_id INTEGER REFERENCES partners(id), cashbox_id INTEGER REFERENCES cashboxes(id), kind TEXT NOT NULL CHECK(kind IN ('deposit','partner_payout')), voucher_number TEXT NOT NULL, source_voucher_reference TEXT, worker_transaction_id INTEGER NOT NULL REFERENCES worker_transactions(id), partner_transaction_id INTEGER REFERENCES partner_transactions(id), journal_entry_id INTEGER NOT NULL REFERENCES journal_entries(id), amount INTEGER NOT NULL CHECK(amount>0), created_at TEXT NOT NULL, created_by INTEGER REFERENCES app_users(id), UNIQUE(station_id,voucher_number))");
    await d.execute('CREATE INDEX IF NOT EXISTS idx_accountant_settlements_worker_date ON accountant_settlements(worker_id,created_at,id)');
  }

  Future<void> _seed(Database d) async {
    final now = AppClock.now().toIso8601String();
    if ((await d.query('stations')).isEmpty) {
      await d.insert('stations', {
        'id': 1,
        'name': 'محطة ساقية',
        'address': '',
        'phone': '',
        'active': 1,
        'created_at': now,
        'updated_at': now,
      });
    }
    if ((await d.query('pumps')).isEmpty) {
      await d.insert('pumps', {
        'id': 1,
        'station_id': 1,
        'name': 'المضخة الرئيسية',
        'system_type': 'diesel',
        'active': 1,
      });
    }
    if ((await d.query('accounts')).isEmpty) {
      final accounts = [
        ['1000', 'الصندوق', 'asset'],
        ['1100', 'البنك والتحويلات', 'asset'],
        ['1200', 'ذمم المستفيدين', 'asset'],
        ['1300', 'مخزون الديزل', 'asset'],
        ['1400', 'سلف الديزل', 'asset'],
        ['2100', 'مستحقات العمال', 'liability'],
        ['2200', 'مستحقات الشركاء', 'liability'],
        ['4000', 'إيرادات السقي', 'revenue'],
        ['4010', 'إيرادات الديزل', 'revenue'],
        ['5000', 'مصروف العمال', 'expense'],
        ['5010', 'مصروف الوقود', 'expense'],
        ['5020', 'مصروف الزيت', 'expense'],
        ['5030', 'مصروف الصيانة', 'expense'],
        ['3000', 'الأرصدة الافتتاحية', 'equity'],
        ['3100', 'الأرصدة المرحلة', 'equity'],
        ['3990', 'الفروقات والتصحيحات', 'equity'],
        ['1120', 'المحافظ الإلكترونية', 'asset'],
        ['3200', 'حصص الشركاء من الأرباح', 'equity'],
        ['3300', 'الأرباح المبقاة', 'equity'],
      ];
      for (var i = 0; i < accounts.length; i++) {
        await d.insert('accounts', {
          'id': i + 1,
          'code': accounts[i][0],
          'name': accounts[i][1],
          'type': accounts[i][2],
        });
      }
    }
    if ((await d.query('cashboxes')).isEmpty) {
      await d.insert('cashboxes', {
        'id': 1,
        'station_id': 1,
        'name': 'الصندوق الرئيسي',
        'opening_balance': 0,
        'current_balance': 0,
        'currency': 'YER',
        'ledger_account_code': '1000',
        'active': 1,
      });
    }
    if ((await d.query('payment_methods')).isEmpty) {
      await d.insert('payment_methods', {
        'id': 1,
        'station_id': 1,
        'name': 'نقدي',
        'type': 'cash',
        'cashbox_id': 1,
        'ledger_account_code': '1000',
        'active': 1,
      });
    }
    await d.rawUpdate(
      "UPDATE payment_methods SET ledger_account_code=CASE type WHEN 'cash' THEN '1000' WHEN 'bank_transfer' THEN '1100' WHEN 'wallet' THEN '1120' ELSE COALESCE(ledger_account_code,'1000') END WHERE ledger_account_code IS NULL",
    );
    final defaults = {
      'station_name': 'محطة ساقية',
      'pump_name': 'المضخة الأولى',
      'selected_pump_id': '1',
      'address': '',
      'phone': '',
      'currency': 'ريال يمني',
      'timezone': 'Asia/Aden',
      'week_start': 'saturday',
      'financial_year_start': '01-01',
      'app_name': 'منظومة',
      'system_type': 'diesel',
      'queue_type': 'circular',
      'time_source': 'device',
      'server_url': '',
      'min_wait_days': '3',
      'manager_override_required': 'true',
      'absence_policy': 'keep_order',
      'allow_midnight_crossing': 'false',
      'diesel_warning_percent': '20',
      'diesel_warning_snoozed_until': '',
      'diesel_tank_capacity_liters': '0',
      'diesel_snooze_minutes': '10',
      'pdf_rows': '30',
      'solar_hourly_rate': '0',
      'diesel_hourly_water_rate': '0',
      'diesel_liters_per_hour': '0',
      'diesel_price_per_liter': '0',
      'third_type_hourly_rate': '0',
      'rounding': 'nearest',
      'partial_hour': 'true',
      'diesel_delivery_financial_credit': 'false',
      'sound_notifications': 'true',
      'popup_notifications': 'true',
      'reduced_motion': 'false',
      'notification_appointment_title': 'موعد السقي',
      'notification_appointment_body': 'تم تحديد موعد السقي: {date}',
      'notification_payment_title': 'تسجيل دفعة',
      'notification_payment_body': 'تم تسجيل دفعة بمبلغ {amount} ريال',
      'notification_balance_title': 'تحديث الرصيد',
      'notification_balance_body': 'الرصيد الحالي: {balance}',
    };
    for (final e in defaults.entries) {
      await d.insert('settings', {
        'key': e.key,
        'value': e.value,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if ((await d.query('app_users')).isEmpty) {
      await d.insert('app_users', {
        'id': 1,
        'station_id': 1,
        'name': 'مدير النظام',
        'phone': '',
        'username': 'admin',
        'password_hash':
            '240be518fabd2724ddb6f04eeb1da5967448d7e831c08c8fa822809f74c720a9',
        'role': 'manager',
        'active': 1,
        'created_at': now,
      });
    }
  }

  /// Unified query API: accepts either raw SELECT/CTE SQL or a table name with
  /// sqflite-style filters. This keeps the UI/repository layer on one contract.
  Future<List<Map<String, Object?>>> query(
    String source, {
    List<Object?> args = const [],
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    // \b بدل المسافة الحرفية: الاستعلامات متعددة الأسطر تبدأ بـ SELECT ثم سطر جديد.
    if (RegExp(r'^\s*(select|with|pragma)\b', caseSensitive: false)
        .hasMatch(source)) {
      return (await db).rawQuery(source, args);
    }
    return (await db).query(
      source,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? args,
  ]) async => (await db).rawQuery(sql, args);

  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    ConflictAlgorithm? conflictAlgorithm,
  }) async =>
      (await db).insert(table, values, conflictAlgorithm: conflictAlgorithm);
  Future<int> update(
    String table,
    Map<String, Object?> values,
    String where,
    List<Object?> args,
  ) async => (await db).update(table, values, where: where, whereArgs: args);
  Future<int> delete(String table, String where, List<Object?> args) async =>
      (await db).delete(table, where: where, whereArgs: args);
  Future<T> transaction<T>(Future<T> Function(Transaction tx) action) async =>
      (await db).transaction(action);
  Future<void> close() async {
    final d = _db;
    _db = null;
    if (d != null) await d.close();
  }

  Future<void> auditTx(
    Transaction tx, {
    int? userId,
    required String operation,
    required String table,
    int? recordId,
    Object? oldValues,
    Object? newValues,
    String? reason,
  }) async {
    await tx.insert('audit_logs', {
      'user_id': userId,
      'operation': operation,
      'table_name': table,
      'record_id': recordId,
      'old_values': oldValues == null ? null : jsonEncode(oldValues),
      'new_values': newValues == null ? null : jsonEncode(newValues),
      'reason': reason,
      'created_at': AppClock.now().toIso8601String(),
    });
  }

  Future<void> audit({
    int? userId,
    required String operation,
    required String table,
    int? recordId,
    Object? oldValues,
    Object? newValues,
    String? reason,
  }) async {
    await insert('audit_logs', {
      'user_id': userId,
      'operation': operation,
      'table_name': table,
      'record_id': recordId,
      'old_values': oldValues == null ? null : jsonEncode(oldValues),
      'new_values': newValues == null ? null : jsonEncode(newValues),
      'reason': reason,
      'created_at': AppClock.now().toIso8601String(),
    });
  }
}
