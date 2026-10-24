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
  for (final code in ['1000', '1100', '1200', '2100', '2200']) {
    db.execute('INSERT INTO accounts(code,name,type) VALUES(?,?,?)',
        [code, 'حساب $code', 'asset']);
  }
  return db;
}

Future<Response> _postPayment(
  Handler handler,
  Map<String, Object?> body, {
  int stationId = 1,
}) async {
  final token = JWT({
    'kind': 'admin',
    'userId': 7,
    'stationId': stationId,
    'role': 'manager'
  }).sign(SecretKey(_secret));
  return handler(
    Request(
      'POST',
      Uri.parse('http://localhost/api/v1/payments'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: jsonEncode(body),
    ),
  );
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
  });
}
