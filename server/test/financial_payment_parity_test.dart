import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../lib/server.dart';

const _secret = 'financial-parity-test-secret-at-least-32-chars';

Database _newFinancialDatabase() {
  final db = sqlite3.openInMemory();
  db.execute('PRAGMA foreign_keys=ON;');
  db.execute('''
    CREATE TABLE stations (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE beneficiaries (
      id INTEGER PRIMARY KEY,
      station_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'active',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE workers (
      id INTEGER PRIMARY KEY,
      station_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      pay_type TEXT NOT NULL,
      active INTEGER NOT NULL DEFAULT 1
    );
    CREATE TABLE partners (
      id INTEGER PRIMARY KEY,
      station_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      ownership_mode TEXT NOT NULL,
      active INTEGER NOT NULL DEFAULT 1
    );
    CREATE TABLE cashboxes (
      id INTEGER PRIMARY KEY,
      station_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      opening_balance INTEGER NOT NULL DEFAULT 0,
      current_balance INTEGER NOT NULL DEFAULT 0,
      currency TEXT NOT NULL DEFAULT 'YER',
      active INTEGER NOT NULL DEFAULT 1,
      ledger_account_code TEXT
    );
    CREATE TABLE payment_methods (
      id INTEGER PRIMARY KEY,
      station_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      type TEXT NOT NULL,
      cashbox_id INTEGER,
      ledger_account_code TEXT,
      active INTEGER NOT NULL DEFAULT 1
    );
    CREATE TABLE payments (
      id INTEGER PRIMARY KEY,
      beneficiary_id INTEGER,
      partner_id INTEGER,
      worker_id INTEGER,
      amount INTEGER NOT NULL,
      date TEXT NOT NULL,
      payment_method_id INTEGER NOT NULL,
      cashbox_id INTEGER NOT NULL,
      reference_number TEXT,
      notes TEXT,
      status TEXT NOT NULL,
      created_by INTEGER,
      CHECK(((beneficiary_id IS NOT NULL)+(partner_id IS NOT NULL)+(worker_id IS NOT NULL))=1)
    );
    CREATE TABLE worker_transactions (
      id INTEGER PRIMARY KEY,
      worker_id INTEGER NOT NULL,
      date TEXT NOT NULL,
      type TEXT NOT NULL,
      hours REAL DEFAULT 0,
      rate_snapshot INTEGER DEFAULT 0,
      percentage_snapshot REAL DEFAULT 0,
      amount INTEGER NOT NULL,
      cashbox_id INTEGER,
      reference_type TEXT,
      reference_id INTEGER,
      notes TEXT,
      created_by INTEGER
    );
    CREATE TABLE partner_transactions (
      id INTEGER PRIMARY KEY,
      partner_id INTEGER NOT NULL,
      date TEXT NOT NULL,
      type TEXT NOT NULL,
      amount INTEGER NOT NULL,
      ownership_snapshot REAL,
      reference_type TEXT,
      reference_id INTEGER,
      notes TEXT,
      created_by INTEGER
    );
    CREATE TABLE accounts (
      id INTEGER PRIMARY KEY,
      code TEXT UNIQUE NOT NULL,
      name TEXT NOT NULL,
      type TEXT NOT NULL
    );
    CREATE TABLE journal_entries (
      id INTEGER PRIMARY KEY,
      station_id INTEGER,
      date TEXT NOT NULL,
      reference_type TEXT,
      reference_id INTEGER,
      description TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'posted',
      created_by INTEGER,
      created_at TEXT NOT NULL
    );
    CREATE TABLE journal_lines (
      id INTEGER PRIMARY KEY,
      journal_entry_id INTEGER NOT NULL,
      account_id INTEGER NOT NULL,
      beneficiary_id INTEGER,
      worker_id INTEGER,
      partner_id INTEGER,
      debit INTEGER NOT NULL DEFAULT 0,
      credit INTEGER NOT NULL DEFAULT 0,
      memo TEXT
    );
    CREATE TABLE cashbox_transfers (
      id INTEGER PRIMARY KEY,
      from_cashbox_id INTEGER,
      to_cashbox_id INTEGER NOT NULL,
      amount INTEGER NOT NULL,
      date TEXT NOT NULL,
      is_opening_transfer INTEGER NOT NULL DEFAULT 0,
      reference TEXT,
      notes TEXT,
      created_by INTEGER
    );
    CREATE TABLE period_closures (
      id INTEGER PRIMARY KEY,
      station_id INTEGER NOT NULL,
      period_start TEXT NOT NULL,
      period_end TEXT NOT NULL,
      period_end_exclusive TEXT,
      status TEXT NOT NULL DEFAULT 'locked'
    );
    CREATE TABLE audit_logs (
      id INTEGER PRIMARY KEY,
      user_id INTEGER,
      operation TEXT NOT NULL,
      table_name TEXT NOT NULL,
      record_id INTEGER,
      old_values TEXT,
      new_values TEXT,
      reason TEXT,
      created_at TEXT NOT NULL
    );
    CREATE TABLE expenses (
      id INTEGER PRIMARY KEY,
      category TEXT NOT NULL,
      title TEXT NOT NULL,
      amount INTEGER NOT NULL,
      date TEXT NOT NULL,
      payment_method_id INTEGER,
      cashbox_id INTEGER,
      status TEXT NOT NULL,
      created_by INTEGER,
      notes TEXT
    );
  ''');

  final now = DateTime.utc(2026, 1, 1).toIso8601String();
  db.execute(
      'INSERT INTO stations(id,name,created_at,updated_at) VALUES(1,?,?,?)',
      ['محطة اختبار', now, now]);
  db.execute(
      'INSERT INTO beneficiaries(id,station_id,name,status,created_at,updated_at) VALUES(1,1,?,?,?,?)',
      ['مستفيد اختبار', 'active', now, now]);
  db.execute(
      'INSERT INTO workers(id,station_id,name,pay_type,active) VALUES(1,1,?,?,1)',
      ['عامل اختبار', 'fixed']);
  db.execute(
      'INSERT INTO partners(id,station_id,name,ownership_mode,active) VALUES(1,1,?,?,1)',
      ['شريك اختبار', 'shares']);
  db.execute(
      'INSERT INTO cashboxes(id,station_id,name,current_balance,active,ledger_account_code) VALUES(1,1,?,1000,1,?)',
      ['صندوق البنك', '1100']);
  db.execute(
      'INSERT INTO cashboxes(id,station_id,name,current_balance,active,ledger_account_code) VALUES(2,1,?,500,1,?)',
      ['صندوق نقدي ثانٍ', '1000']);
  db.execute(
      'INSERT INTO payment_methods(id,station_id,name,type,cashbox_id,ledger_account_code,active) VALUES(1,1,?,?,1,?,1)',
      ['طريقة نقدية', 'cash', '1000']);
  for (final code in ['1000', '1100', '1200', '2100', '2200', '3000', '5030']) {
    db.execute('INSERT INTO accounts(code,name,type) VALUES(?,?,?)',
        [code, 'حساب $code', 'asset']);
  }
  return db;
}

Future<Response> _postPayment(
  Handler handler,
  Map<String, Object?> body, {
  int stationId = 1,
  String? idempotencyKey = 'payment-test-key-0001',
}) =>
    _postJson(
      handler,
      '/api/v1/payments',
      body,
      stationId: stationId,
      idempotencyKey: idempotencyKey,
    );

Future<Response> _postJson(
  Handler handler,
  String path,
  Map<String, Object?> body, {
  int stationId = 1,
  String? idempotencyKey,
}) async {
  final token = JWT({
    'kind': 'admin',
    'userId': 7,
    'stationId': stationId,
    'role': 'manager',
  }).sign(SecretKey(_secret));
  final headers = <String, String>{
    'authorization': 'Bearer $token',
    'content-type': 'application/json',
    if (idempotencyKey != null) 'idempotency-key': idempotencyKey,
  };
  return handler(Request(
    'POST',
    Uri.parse('http://localhost$path'),
    headers: headers,
    body: jsonEncode(body),
  ));
}

Map<String, Object?> _decode(Response response, String text) =>
    Map<String, Object?>.from(jsonDecode(text) as Map);

void main() {
  group('financial payment parity on synthetic SQLite fixtures', () {
    late Database db;
    late Handler handler;

    setUp(() {
      db = _newFinancialDatabase();
      handler = SaqiaServer(db, jwtSecret: _secret).router();
    });

    tearDown(() => db.dispose());

    test(
        'beneficiary receipt increases cash and posts to the cashbox ledger account',
        () async {
      final response = await _postPayment(handler, {
        'beneficiary_id': 1,
        'amount': 300,
        'payment_method_id': 1,
        'cashbox_id': 1,
        'reference_number': 'GOLDEN-IN-001',
      });
      expect(response.statusCode, 200);
      final result = _decode(response, await response.readAsString());
      final paymentId = result['id'] as int;

      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1300);
      expect(
          db
              .select(
                  "SELECT id FROM payments WHERE reference_number='GOLDEN-IN-001' AND status='posted'")
              .length,
          1);
      final lines = db.select('''
        SELECT a.code,jl.debit,jl.credit,je.station_id,je.reference_type,je.reference_id
        FROM journal_entries je
        JOIN journal_lines jl ON jl.journal_entry_id=je.id
        JOIN accounts a ON a.id=jl.account_id
        WHERE je.reference_type='payment' AND je.reference_id=?
        ORDER BY jl.id
      ''', [paymentId]);
      expect(lines.length, 2);
      expect(lines.map((r) => [r['code'], r['debit'], r['credit']]).toList(), [
        ['1100', 300, 0],
        ['1200', 0, 300],
      ]);
      expect(lines.map((r) => r['station_id']).toSet(), {1});
    });

    test(
        'worker payout decreases cash and creates linked party and ledger entries',
        () async {
      final response = await _postPayment(handler, {
        'worker_id': 1,
        'amount': 250,
        'payment_method_id': 1,
        'cashbox_id': 1,
        'reference_number': 'GOLDEN-OUT-W-001',
      });
      expect(response.statusCode, 200);
      final result = _decode(response, await response.readAsString());
      final paymentId = result['id'] as int;

      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          750);
      final payment =
          db.select('SELECT * FROM payments WHERE id=?', [paymentId]).single;
      expect(payment['status'], 'posted');
      expect(payment['worker_id'], 1);
      final workerTransactions = db.select(
          'SELECT * FROM worker_transactions WHERE reference_type=? AND reference_id=?',
          ['payment', paymentId]);
      expect(workerTransactions.length, 1);
      expect(workerTransactions.single['amount'], 250);

      final lines = db.select('''
        SELECT a.code,jl.debit,jl.credit,jl.worker_id,je.station_id,je.reference_type,je.reference_id
        FROM journal_entries je
        JOIN journal_lines jl ON jl.journal_entry_id=je.id
        JOIN accounts a ON a.id=jl.account_id
        WHERE je.reference_type='payment' AND je.reference_id=?
        ORDER BY jl.id
      ''', [paymentId]);
      expect(
          lines
              .map((r) => [r['code'], r['debit'], r['credit'], r['worker_id']])
              .toList(),
          [
            ['2100', 250, 0, 1],
            ['1100', 0, 250, null],
          ]);
      expect(lines.map((r) => r['station_id']).toSet(), {1});
    });

    test('partner payout decreases cash and creates a linked party transaction',
        () async {
      final response = await _postPayment(handler, {
        'partner_id': 1,
        'amount': 175,
        'payment_method_id': 1,
        'cashbox_id': 1,
        'reference_number': 'GOLDEN-OUT-P-001',
      });
      expect(response.statusCode, 200);
      final result = _decode(response, await response.readAsString());
      final paymentId = result['id'] as int;

      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          825);
      final partnerTransactions = db.select(
          'SELECT * FROM partner_transactions WHERE reference_type=? AND reference_id=?',
          ['payment', paymentId]);
      expect(partnerTransactions.length, 1);
      expect(partnerTransactions.single['amount'], 175);
      final lines = db.select('''
        SELECT a.code,jl.debit,jl.credit,jl.partner_id,je.station_id
        FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id
        JOIN accounts a ON a.id=jl.account_id
        WHERE je.reference_type='payment' AND je.reference_id=? ORDER BY jl.id
      ''', [paymentId]);
      expect(
          lines
              .map((r) => [r['code'], r['debit'], r['credit'], r['partner_id']])
              .toList(),
          [
            ['2200', 175, 0, 1],
            ['1100', 0, 175, null],
          ]);
      expect(lines.map((r) => r['station_id']).toSet(), {1});
    });

    test(
        'outgoing payment over balance and invalid source are atomic rejections',
        () async {
      final response = await _postPayment(handler, {
        'worker_id': 1,
        'amount': 1001,
        'payment_method_id': 1,
        'cashbox_id': 1,
      });
      expect(response.statusCode, 422);
      await response.readAsString();
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1000);
      expect(db.select('SELECT id FROM payments').length, 0);
      expect(db.select('SELECT id FROM journal_entries').length, 0);
      expect(db.select('SELECT id FROM worker_transactions').length, 0);

      final mismatchedSource = await _postPayment(handler, {
        'beneficiary_id': 1,
        'amount': 50,
        'payment_method_id': 1,
        'cashbox_id': 2,
      });
      expect(mismatchedSource.statusCode, 422);
      await mismatchedSource.readAsString();
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1000);
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=2')
                  .first['current_balance'] as num)
              .toInt(),
          500);
      expect(db.select('SELECT id FROM payments').length, 0);
      expect(db.select('SELECT id FROM journal_entries').length, 0);
    });

    test(
        'rejects zero, fractional, missing-party, and multi-party payments without writes',
        () async {
      final invalidBodies = <Map<String, Object?>>[
        {
          'beneficiary_id': 1,
          'amount': 0,
          'payment_method_id': 1,
          'cashbox_id': 1
        },
        {
          'beneficiary_id': 1,
          'amount': 100.4,
          'payment_method_id': 1,
          'cashbox_id': 1
        },
        {'amount': 100, 'payment_method_id': 1, 'cashbox_id': 1},
        {
          'beneficiary_id': 1,
          'worker_id': 1,
          'amount': 100,
          'payment_method_id': 1,
          'cashbox_id': 1
        },
      ];
      for (final body in invalidBodies) {
        final response = await _postPayment(handler, body);
        expect(response.statusCode, 422);
        await response.readAsString();
      }
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1000);
      expect(db.select('SELECT id FROM payments').length, 0);
      expect(db.select('SELECT id FROM journal_entries').length, 0);
    });

    test('rejects inactive sources and cross-station parties without writes',
        () async {
      db.execute('UPDATE payment_methods SET active=0 WHERE id=1');
      var response = await _postPayment(handler, {
        'beneficiary_id': 1,
        'amount': 100,
        'payment_method_id': 1,
        'cashbox_id': 1,
      });
      expect(response.statusCode, 422);
      await response.readAsString();

      db.execute('UPDATE payment_methods SET active=1 WHERE id=1');
      db.execute('UPDATE cashboxes SET active=0 WHERE id=1');
      response = await _postPayment(handler, {
        'beneficiary_id': 1,
        'amount': 100,
        'payment_method_id': 1,
        'cashbox_id': 1,
      });
      expect(response.statusCode, 422);
      await response.readAsString();

      db.execute('UPDATE cashboxes SET active=1 WHERE id=1');
      response = await _postPayment(
        handler,
        {
          'beneficiary_id': 1,
          'amount': 100,
          'payment_method_id': 1,
          'cashbox_id': 1,
        },
        stationId: 2,
      );
      expect(response.statusCode, 422);
      await response.readAsString();
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1000);
      expect(db.select('SELECT id FROM payments').length, 0);
      expect(db.select('SELECT id FROM journal_entries').length, 0);
    });

    test(
        'same idempotency key replays the exact payment and rejects changed payload',
        () async {
      const key = 'payment-idempotency-0001';
      final body = <String, Object?>{
        'beneficiary_id': 1,
        'amount': 300,
        'payment_method_id': 1,
        'cashbox_id': 1,
        'reference_number': 'IDEM-GOLDEN-001',
      };
      final responses = await Future.wait([
        _postPayment(handler, body, idempotencyKey: key),
        _postPayment(handler, body, idempotencyKey: key),
      ]);
      expect(responses.map((r) => r.statusCode), everyElement(200));
      final responseBodies =
          await Future.wait(responses.map((r) => r.readAsString()));
      expect(responseBodies[0], responseBodies[1]);
      expect(db.select('SELECT id FROM payments').length, 1);
      expect(
          db
              .select(
                  "SELECT id FROM journal_entries WHERE reference_type='payment'")
              .length,
          1);
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1300);

      final changed = await _postPayment(handler, {...body, 'amount': 301},
          idempotencyKey: key);
      expect(changed.statusCode, 409);
      await changed.readAsString();
      expect(db.select('SELECT id FROM payments').length, 1);
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1300);
    });

    test('financial writes require an idempotency key', () async {
      final response = await _postPayment(
        handler,
        {
          'beneficiary_id': 1,
          'amount': 100,
          'payment_method_id': 1,
          'cashbox_id': 1
        },
        idempotencyKey: null,
      );
      expect(response.statusCode, 422);
      await response.readAsString();
      expect(db.select('SELECT id FROM payments').length, 0);
      expect(db.select('SELECT id FROM journal_entries').length, 0);
    });

    test('cashbox transfer journals use the actual source and target accounts',
        () async {
      const date = '2026-01-15T12:00:00.000Z';
      final body = <String, Object?>{
        'from_cashbox_id': 1,
        'to_cashbox_id': 2,
        'amount': 100,
        'date': date
      };
      final first = await _postJson(handler, '/api/v1/cashbox-transfers', body,
          idempotencyKey: 'transfer-idempotency-0001');
      expect(first.statusCode, 200);
      final firstBody = await first.readAsString();
      final replay = await _postJson(handler, '/api/v1/cashbox-transfers', body,
          idempotencyKey: 'transfer-idempotency-0001');
      expect(replay.statusCode, 200);
      expect(await replay.readAsString(), firstBody);
      expect(db.select('SELECT id FROM cashbox_transfers').length, 1);
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          900);
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=2')
                  .first['current_balance'] as num)
              .toInt(),
          600);
      final lines = db.select('''
        SELECT a.code,jl.debit,jl.credit,je.station_id,je.date
        FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id
        JOIN accounts a ON a.id=jl.account_id
        WHERE je.reference_type='cashbox_transfer'
        ORDER BY jl.id
      ''');
      expect(lines.map((r) => [r['code'], r['debit'], r['credit']]).toList(), [
        ['1000', 100, 0],
        ['1100', 0, 100],
      ]);
      expect(lines.map((r) => r['station_id']).toSet(), {1});
      expect(lines.map((r) => r['date']).toSet(), {date});
    });

    test('opening cashbox transfer debits its account and credits equity 3000',
        () async {
      const date = '2026-01-16T12:00:00.000Z';
      final response = await _postJson(
        handler,
        '/api/v1/cashbox-transfers',
        {'to_cashbox_id': 2, 'amount': 200, 'date': date},
        idempotencyKey: 'opening-transfer-0001',
      );
      expect(response.statusCode, 200);
      await response.readAsString();
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=2')
                  .first['current_balance'] as num)
              .toInt(),
          700);
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1000);
      final lines = db.select('''
        SELECT a.code,jl.debit,jl.credit,je.station_id
        FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id
        JOIN accounts a ON a.id=jl.account_id
        WHERE je.reference_type='cashbox_transfer'
        ORDER BY jl.id
      ''');
      expect(lines.map((r) => [r['code'], r['debit'], r['credit']]).toList(), [
        ['1000', 200, 0],
        ['3000', 0, 200],
      ]);
      expect(lines.map((r) => r['station_id']).toSet(), {1});
      expect(
          db
              .select('SELECT is_opening_transfer FROM cashbox_transfers')
              .single['is_opening_transfer'],
          1);
    });

    test('transfer rejects a closed period and self-transfer without writes',
        () async {
      db.execute(
          'INSERT INTO period_closures(station_id,period_start,period_end,period_end_exclusive,status) VALUES(1,?,?,?,?)',
          [
            '2026-01-01T00:00:00.000Z',
            '2026-01-31T23:59:59.000Z',
            '2026-02-01T00:00:00.000Z',
            'locked'
          ]);
      final closed = await _postJson(
        handler,
        '/api/v1/cashbox-transfers',
        {
          'from_cashbox_id': 1,
          'to_cashbox_id': 2,
          'amount': 50,
          'date': '2026-01-15T12:00:00.000Z'
        },
        idempotencyKey: 'closed-period-transfer-1',
      );
      expect(closed.statusCode, 422);
      await closed.readAsString();
      final self = await _postJson(
        handler,
        '/api/v1/cashbox-transfers',
        {
          'from_cashbox_id': 1,
          'to_cashbox_id': 1,
          'amount': 50,
          'date': '2026-03-15T12:00:00.000Z'
        },
        idempotencyKey: 'self-transfer-key-0001',
      );
      expect(self.statusCode, 422);
      await self.readAsString();
      final fractionalSource = await _postJson(
        handler,
        '/api/v1/cashbox-transfers',
        {
          'from_cashbox_id': 1.5,
          'to_cashbox_id': 2,
          'amount': 50,
          'date': '2026-03-15T12:00:00.000Z'
        },
        idempotencyKey: 'fractional-source-id-01',
      );
      expect(fractionalSource.statusCode, 422);
      await fractionalSource.readAsString();
      expect(db.select('SELECT id FROM cashbox_transfers').length, 0);
      expect(db.select('SELECT id FROM journal_entries').length, 0);
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1000);
    });

    test(
        'beneficiary payment cancellation posts one reversal and replays idempotently',
        () async {
      final created = await _postPayment(
        handler,
        {
          'beneficiary_id': 1,
          'amount': 300,
          'payment_method_id': 1,
          'cashbox_id': 1
        },
        idempotencyKey: 'create-payment-before-cancel-1',
      );
      expect(created.statusCode, 200);
      final paymentId =
          _decode(created, await created.readAsString())['id'] as int;
      final originalEntry = (db.select(
              "SELECT id FROM journal_entries WHERE reference_type='payment' AND reference_id=?",
              [paymentId]).single['id'] as num)
          .toInt();

      final body = <String, Object?>{'reason': 'تصحيح إيصال تجريبي'};
      final cancel = await _postJson(
          handler, '/api/v1/payments/$paymentId/cancel', body,
          idempotencyKey: 'cancel-payment-idem-001');
      expect(cancel.statusCode, 200);
      final cancelText = await cancel.readAsString();
      expect(
          db.select('SELECT status FROM payments WHERE id=?',
              [paymentId]).single['status'],
          'cancelled');
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1000);
      final reversal = db
          .select(
              "SELECT id,station_id,reference_id FROM journal_entries WHERE reference_type='reversal'")
          .single;
      expect(reversal['station_id'], 1);
      expect(reversal['reference_id'], originalEntry);
      final reverseLines = db.select('''
        SELECT a.code,jl.debit,jl.credit
        FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id=je.id
        JOIN accounts a ON a.id=jl.account_id
        WHERE je.reference_type='reversal'
      ''');
      expect(
          reverseLines
              .map((r) => [r['code'], r['debit'], r['credit']])
              .toList(),
          [
            ['1100', 0, 300],
            ['1200', 300, 0],
          ]);
      final replay = await _postJson(
          handler, '/api/v1/payments/$paymentId/cancel', body,
          idempotencyKey: 'cancel-payment-idem-001');
      expect(replay.statusCode, 200);
      expect(await replay.readAsString(), cancelText);
      expect(
          db
              .select(
                  "SELECT id FROM journal_entries WHERE reference_type='reversal'")
              .length,
          1);
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1000);
      final secondKey = await _postJson(
          handler, '/api/v1/payments/$paymentId/cancel', body,
          idempotencyKey: 'cancel-payment-second-key-01');
      expect(secondKey.statusCode, 409);
      await secondKey.readAsString();
      expect(
          db
              .select(
                  "SELECT id FROM journal_entries WHERE reference_type='reversal'")
              .length,
          1);
    });

    test('cancelling beneficiary receipt with insufficient cash is rolled back',
        () async {
      final created = await _postPayment(
          handler,
          {
            'beneficiary_id': 1,
            'amount': 300,
            'payment_method_id': 1,
            'cashbox_id': 1
          },
          idempotencyKey: 'receipt-before-low-cancel-01');
      final paymentId =
          _decode(created, await created.readAsString())['id'] as int;
      db.execute('UPDATE cashboxes SET current_balance=100 WHERE id=1');
      final response = await _postJson(
          handler,
          '/api/v1/payments/$paymentId/cancel',
          {'reason': 'اختبار نقص الصندوق'},
          idempotencyKey: 'low-cash-cancel-payment-01');
      expect(response.statusCode, 422);
      await response.readAsString();
      expect(
          db.select('SELECT status FROM payments WHERE id=?',
              [paymentId]).single['status'],
          'posted');
      expect(
          db
              .select(
                  "SELECT id FROM journal_entries WHERE reference_type='reversal'")
              .length,
          0);
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          100);
    });

    test(
        'worker payment cancellation refunds cash and records a party reversal',
        () async {
      final created = await _postPayment(
          handler,
          {
            'worker_id': 1,
            'amount': 200,
            'payment_method_id': 1,
            'cashbox_id': 1
          },
          idempotencyKey: 'worker-payment-before-cancel-01');
      final paymentId =
          _decode(created, await created.readAsString())['id'] as int;
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          800);
      final response = await _postJson(handler,
          '/api/v1/payments/$paymentId/cancel', {'reason': 'إلغاء دفعة عامل'},
          idempotencyKey: 'worker-payment-cancel-001');
      expect(response.statusCode, 200);
      await response.readAsString();
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1000);
      expect(
          db.select(
              "SELECT id FROM worker_transactions WHERE type='payment_reversal' AND reference_type='payment_cancel' AND reference_id=?",
              [paymentId]).length,
          1);
      expect(
          db
              .select(
                  "SELECT id FROM journal_entries WHERE reference_type='reversal'")
              .length,
          1);
    });

    test('expense cancellation restores cash and reverses the posted journal',
        () async {
      final date = DateTime.now().toIso8601String();
      final expenseAccount =
          db.select("SELECT id FROM accounts WHERE code='5030'").single['id'];
      final cashAccount =
          db.select("SELECT id FROM accounts WHERE code='1100'").single['id'];
      db.execute('UPDATE cashboxes SET current_balance=900 WHERE id=1');
      db.execute(
          "INSERT INTO expenses(id,category,title,amount,date,payment_method_id,cashbox_id,status,created_by,notes) VALUES(1,'maintenance','إصلاح مضخة',100,?,1,1,'posted',7,'ملاحظة')",
          [date]);
      db.execute(
          "INSERT INTO journal_entries(station_id,date,reference_type,reference_id,description,status,created_by,created_at) VALUES(1,?,'expense',1,'إصلاح مضخة','posted',7,?)",
          [date, date]);
      final entryId = db.lastInsertRowId;
      db.execute(
          'INSERT INTO journal_lines(journal_entry_id,account_id,debit,credit,memo) VALUES(?,?,100,0,?)',
          [entryId, expenseAccount, 'مصروف']);
      db.execute(
          'INSERT INTO journal_lines(journal_entry_id,account_id,debit,credit,memo) VALUES(?,?,0,100,?)',
          [entryId, cashAccount, 'الصندوق']);

      final body = <String, Object?>{'reason': 'إلغاء فاتورة مصروف تجريبية'};
      final response = await _postJson(
          handler, '/api/v1/expenses/1/cancel', body,
          idempotencyKey: 'cancel-expense-idem-001');
      expect(response.statusCode, 200);
      final responseText = await response.readAsString();
      expect(
          db.select('SELECT status FROM expenses WHERE id=1').single['status'],
          'cancelled');
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1000);
      expect(
          db.select(
              "SELECT id FROM journal_entries WHERE reference_type='reversal' AND reference_id=?",
              [entryId]).length,
          1);
      final replay = await _postJson(handler, '/api/v1/expenses/1/cancel', body,
          idempotencyKey: 'cancel-expense-idem-001');
      expect(replay.statusCode, 200);
      expect(await replay.readAsString(), responseText);
      expect(
          db.select(
              "SELECT id FROM journal_entries WHERE reference_type='reversal' AND reference_id=?",
              [entryId]).length,
          1);
      expect(
          db
              .select(
                  "SELECT id FROM audit_logs WHERE operation='cancel' AND table_name='expenses' AND record_id=1")
              .length,
          1);
    });

    test('beneficiary creation refuses an opening balance without a journal',
        () async {
      final before = db.select('SELECT id FROM beneficiaries').length;
      final response = await _postJson(
        handler,
        '/api/v1/beneficiaries',
        {'name': 'مستفيد برصيد افتتاحي', 'opening_balance': 50},
        idempotencyKey: 'beneficiary-opening-balance-01',
      );
      expect(response.statusCode, 503);
      await response.readAsString();
      expect(db.select('SELECT id FROM beneficiaries').length, before);
      expect(db.select('SELECT id FROM journal_entries').length, 0);
    });

    test(
        'partner payment cancellation refunds cash and records a party reversal',
        () async {
      final created = await _postPayment(
        handler,
        {
          'partner_id': 1,
          'amount': 150,
          'payment_method_id': 1,
          'cashbox_id': 1
        },
        idempotencyKey: 'partner-payment-before-cancel-01',
      );
      final paymentId =
          _decode(created, await created.readAsString())['id'] as int;
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          850);
      final response = await _postJson(
        handler,
        '/api/v1/payments/$paymentId/cancel',
        {'reason': 'إلغاء دفعة شريك'},
        idempotencyKey: 'partner-payment-cancel-001',
      );
      expect(response.statusCode, 200);
      await response.readAsString();
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1000);
      expect(
          db.select(
              "SELECT id FROM partner_transactions WHERE type='payment_reversal' AND reference_type='payment_cancel' AND reference_id=?",
              [paymentId]).length,
          1);
    });

    test(
        'partial cancellation failure rolls back and the same key can be retried',
        () async {
      final created = await _postPayment(
        handler,
        {
          'worker_id': 1,
          'amount': 200,
          'payment_method_id': 1,
          'cashbox_id': 1
        },
        idempotencyKey: 'worker-payment-before-rollback-01',
      );
      final paymentId =
          _decode(created, await created.readAsString())['id'] as int;
      final original = db.select(
          "SELECT * FROM worker_transactions WHERE reference_type='payment' AND reference_id=?",
          [paymentId]).single;
      db.execute(
          "DELETE FROM worker_transactions WHERE reference_type='payment' AND reference_id=?",
          [paymentId]);

      final path = '/api/v1/payments/$paymentId/cancel';
      final body = <String, Object?>{'reason': 'اختبار rollback بعد بدء العكس'};
      final failed = await _postJson(handler, path, body,
          idempotencyKey: 'cancel-worker-rollback-001');
      expect(failed.statusCode, 422);
      await failed.readAsString();
      expect(
          db.select('SELECT status FROM payments WHERE id=?',
              [paymentId]).single['status'],
          'posted');
      expect(
          db
              .select(
                  "SELECT id FROM journal_entries WHERE reference_type='reversal'")
              .length,
          0);
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          800);

      db.execute(
        'INSERT INTO worker_transactions(worker_id,date,type,hours,rate_snapshot,percentage_snapshot,amount,cashbox_id,reference_type,reference_id,notes,created_by) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          original['worker_id'],
          original['date'],
          original['type'],
          original['hours'],
          original['rate_snapshot'],
          original['percentage_snapshot'],
          original['amount'],
          original['cashbox_id'],
          original['reference_type'],
          original['reference_id'],
          original['notes'],
          original['created_by']
        ],
      );
      final retry = await _postJson(handler, path, body,
          idempotencyKey: 'cancel-worker-rollback-001');
      expect(retry.statusCode, 200);
      await retry.readAsString();
      expect(
          db.select('SELECT status FROM payments WHERE id=?',
              [paymentId]).single['status'],
          'cancelled');
      expect(
          db
              .select(
                  "SELECT id FROM journal_entries WHERE reference_type='reversal'")
              .length,
          1);
      expect(
          (db
                  .select('SELECT current_balance FROM cashboxes WHERE id=1')
                  .first['current_balance'] as num)
              .toInt(),
          1000);
    });
  });
}
