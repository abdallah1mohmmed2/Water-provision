import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../lib/server.dart';

void main() {
  const secret = 'sync-protocol-test-secret-at-least-32-bytes';
  late Database database;
  late SaqiaServer server;
  late String stationOneToken;
  late String stationTwoToken;

  setUp(() {
    database = sqlite3.openInMemory();
    database.execute('CREATE TABLE stations(id INTEGER PRIMARY KEY, name TEXT NOT NULL)');
    database.execute('INSERT INTO stations(id,name) VALUES(1,\'Station One\'),(2,\'Station Two\')');
    database.execute('''CREATE TABLE beneficiaries(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      station_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      phone TEXT,
      address TEXT,
      location TEXT,
      jerba_number TEXT,
      area TEXT,
      is_needy INTEGER NOT NULL DEFAULT 0,
      notes TEXT,
      status TEXT NOT NULL DEFAULT 'active',
      created_at TEXT,
      updated_at TEXT
    )''');
    database.execute('''CREATE TABLE app_users(
      id INTEGER PRIMARY KEY, station_id INTEGER, role TEXT, active INTEGER
    )''');
    database.execute("INSERT INTO app_users(id,station_id,role,active) VALUES(11,1,'manager',1),(22,2,'manager',1)");
    database.execute('''CREATE TABLE queue_entries(
      id INTEGER PRIMARY KEY AUTOINCREMENT, beneficiary_id INTEGER NOT NULL,
      position INTEGER NOT NULL, cycle_number INTEGER NOT NULL DEFAULT 1,
      status TEXT NOT NULL, last_served_at TEXT, postponed_count INTEGER NOT NULL DEFAULT 0,
      skip_reason TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )''');
    database.execute('''CREATE TABLE booking_requests(
      id INTEGER PRIMARY KEY AUTOINCREMENT, beneficiary_id INTEGER NOT NULL,
      created_at TEXT NOT NULL, status TEXT NOT NULL, scheduled_date TEXT,
      scheduled_start TEXT, scheduled_end TEXT, priority INTEGER, notes TEXT,
      cancel_reason TEXT, reviewed_by INTEGER, reviewed_at TEXT
    )''');
    server = SaqiaServer(database, jwtSecret: secret);
    stationOneToken = JWT({'kind':'admin','userId':11,'stationId':1,'role':'manager'})
        .sign(SecretKey(secret));
    stationTwoToken = JWT({'kind':'admin','userId':22,'stationId':2,'role':'manager'})
        .sign(SecretKey(secret));
  });

  tearDown(() => database.dispose());

  Future<Map<String, dynamic>> postEvents(
    String token,
    List<Map<String, dynamic>> events, {
    String device = 'device-a',
  }) async {
    final response = await server.router().call(Request(
      'POST',
      Uri.parse('http://localhost/api/v1/sync/events'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: jsonEncode({'device_id':device,'events':events}),
    ));
    return jsonDecode(await response.readAsString()) as Map<String,dynamic>;
  }

  Future<Map<String, dynamic>> getInbox(
    String token, {
    String device = 'device-b',
  }) async {
    final response = await server.router().call(Request(
      'GET',
      Uri.parse('http://localhost/api/v1/sync/inbox?after=0&device_id=$device'),
      headers: {'authorization':'Bearer $token'},
    ));
    return jsonDecode(await response.readAsString()) as Map<String,dynamic>;
  }

  Map<String,dynamic> event({
    String id = '11111111-1111-4111-8111-111111111111',
    String globalId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    int baseVersion = 0,
    String operation = 'create',
    Map<String,dynamic>? payload,
  }) => {
    'event_id':id,
    'entity_type':'beneficiaries',
    'entity_key':'beneficiaries:$globalId',
    'operation':operation,
    'base_version':baseVersion,
    'payload':{
      '_global_id':globalId,
      'name':'Test Beneficiary',
      ...?payload,
    },
  };

  void prepareReceiptFixture({String beneficiaryGlobalId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'}) {
    database.execute("INSERT INTO beneficiaries(id,station_id,name,status) VALUES(1,1,'Receipt Beneficiary','active')");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(1,'beneficiaries',?,1,'2026-11-08T00:00:00Z')", [beneficiaryGlobalId]);
    database.execute('''CREATE TABLE cashboxes(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, name TEXT NOT NULL,
      opening_balance INTEGER NOT NULL DEFAULT 0, current_balance INTEGER NOT NULL DEFAULT 0,
      currency TEXT NOT NULL DEFAULT 'YER', active INTEGER NOT NULL DEFAULT 1,
      ledger_account_code TEXT
    )''');
    database.execute('''CREATE TABLE payment_methods(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, name TEXT NOT NULL,
      type TEXT NOT NULL, cashbox_id INTEGER, ledger_account_code TEXT, active INTEGER NOT NULL DEFAULT 1
    )''');
    database.execute('''CREATE TABLE payments(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, beneficiary_id INTEGER,
      partner_id INTEGER, worker_id INTEGER, amount INTEGER NOT NULL, date TEXT NOT NULL,
      payment_method_id INTEGER NOT NULL, cashbox_id INTEGER NOT NULL, reference_number TEXT,
      notes TEXT, status TEXT NOT NULL, created_by INTEGER
    )''');
    database.execute('CREATE TABLE accounts(id INTEGER PRIMARY KEY, code TEXT UNIQUE NOT NULL, name TEXT NOT NULL, type TEXT NOT NULL)');
    database.execute('''CREATE TABLE journal_entries(
      id INTEGER PRIMARY KEY, station_id INTEGER, date TEXT NOT NULL, reference_type TEXT,
      reference_id INTEGER, description TEXT NOT NULL, status TEXT NOT NULL,
      created_by INTEGER, created_at TEXT NOT NULL
    )''');
    database.execute('''CREATE TABLE journal_lines(
      id INTEGER PRIMARY KEY, journal_entry_id INTEGER NOT NULL, account_id INTEGER NOT NULL,
      beneficiary_id INTEGER, worker_id INTEGER, partner_id INTEGER, debit INTEGER NOT NULL DEFAULT 0,
      credit INTEGER NOT NULL DEFAULT 0, memo TEXT
    )''');
    database.execute("INSERT INTO cashboxes(id,station_id,name,current_balance,currency,active,ledger_account_code) VALUES(1,1,'Main Cashbox',500,'YER',1,'1000')");
    database.execute("INSERT INTO payment_methods(id,station_id,name,type,cashbox_id,ledger_account_code,active) VALUES(1,1,'Cash','cash',1,'1000',1)");
    database.execute("INSERT INTO accounts(id,code,name,type) VALUES(1,'1000','Cash','asset'),(2,'1200','Beneficiary receivables','asset')");
  }


  void prepareDieselFixture() {
    database.execute('''CREATE TABLE diesel_movements(
      id INTEGER PRIMARY KEY AUTOINCREMENT, station_id INTEGER NOT NULL,
      beneficiary_id INTEGER, irrigation_id INTEGER, cashbox_id INTEGER,
      kind TEXT NOT NULL, liters REAL NOT NULL, unit_price INTEGER NOT NULL,
      amount INTEGER NOT NULL, date TEXT NOT NULL, notes TEXT, created_by INTEGER
    )''');
    database.execute('''CREATE TABLE cashboxes(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, name TEXT NOT NULL,
      current_balance INTEGER NOT NULL DEFAULT 0, active INTEGER NOT NULL DEFAULT 1,
      ledger_account_code TEXT, currency TEXT NOT NULL DEFAULT 'YER'
    )''');
    database.execute('''CREATE TABLE payment_methods(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, name TEXT NOT NULL,
      type TEXT NOT NULL, cashbox_id INTEGER, ledger_account_code TEXT, active INTEGER NOT NULL DEFAULT 1
    )''');
    database.execute('CREATE TABLE station_settings(station_id INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY(station_id,key))');
    database.execute('CREATE TABLE accounts(id INTEGER PRIMARY KEY, code TEXT UNIQUE NOT NULL, name TEXT NOT NULL, type TEXT NOT NULL)');
    database.execute('''CREATE TABLE journal_entries(
      id INTEGER PRIMARY KEY AUTOINCREMENT, station_id INTEGER NOT NULL, date TEXT NOT NULL,
      reference_type TEXT, reference_id INTEGER, description TEXT NOT NULL,
      status TEXT NOT NULL, created_by INTEGER, created_at TEXT NOT NULL
    )''');
    database.execute('''CREATE TABLE journal_lines(
      id INTEGER PRIMARY KEY AUTOINCREMENT, journal_entry_id INTEGER NOT NULL,
      account_id INTEGER NOT NULL, beneficiary_id INTEGER, worker_id INTEGER, partner_id INTEGER,
      debit INTEGER NOT NULL DEFAULT 0, credit INTEGER NOT NULL DEFAULT 0, memo TEXT
    )''');
    database.execute("INSERT INTO accounts(id,code,name,type) VALUES(1,'1000','Cash','asset'),(2,'1200','Receivables','asset'),(3,'1300','Diesel inventory','asset'),(4,'3000','Opening balances','equity'),(5,'5010','Fuel expense','expense')");
    database.execute("INSERT INTO cashboxes(id,station_id,name,current_balance,active,ledger_account_code) VALUES(1,1,'Main',5000,1,'1000'),(2,2,'Foreign',5000,1,'1000')");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(2,'cashboxes','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',2,'2026-11-08T00:00:00Z')");
  }
  void prepareExpenseAndTransferFixture() {
    database.execute('''CREATE TABLE cashboxes(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, name TEXT NOT NULL,
      opening_balance INTEGER NOT NULL DEFAULT 0, current_balance INTEGER NOT NULL DEFAULT 0,
      currency TEXT NOT NULL DEFAULT 'YER', active INTEGER NOT NULL DEFAULT 1, ledger_account_code TEXT
    )''');
    database.execute('''CREATE TABLE payment_methods(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, name TEXT NOT NULL, type TEXT NOT NULL,
      cashbox_id INTEGER, ledger_account_code TEXT, active INTEGER NOT NULL DEFAULT 1
    )''');
    database.execute('''CREATE TABLE expenses(
      id INTEGER PRIMARY KEY AUTOINCREMENT, station_id INTEGER NOT NULL, category TEXT NOT NULL,
      title TEXT NOT NULL, amount INTEGER NOT NULL, date TEXT NOT NULL, payment_method_id INTEGER,
      cashbox_id INTEGER, beneficiary_id INTEGER, worker_id INTEGER, partner_id INTEGER,
      attachment_path TEXT, notes TEXT, status TEXT NOT NULL, created_by INTEGER
    )''');
    database.execute('''CREATE TABLE cashbox_transfers(
      id INTEGER PRIMARY KEY AUTOINCREMENT, station_id INTEGER NOT NULL, from_cashbox_id INTEGER,
      to_cashbox_id INTEGER NOT NULL, amount INTEGER NOT NULL, date TEXT NOT NULL,
      is_opening_transfer INTEGER NOT NULL DEFAULT 0, reference TEXT, notes TEXT, created_by INTEGER
    )''');
    database.execute('CREATE TABLE accounts(id INTEGER PRIMARY KEY, parent_id INTEGER, code TEXT UNIQUE NOT NULL, name TEXT NOT NULL, type TEXT NOT NULL)');
    database.execute('''CREATE TABLE journal_entries(
      id INTEGER PRIMARY KEY AUTOINCREMENT, station_id INTEGER NOT NULL, date TEXT NOT NULL,
      reference_type TEXT, reference_id INTEGER, description TEXT NOT NULL, status TEXT NOT NULL,
      created_by INTEGER, created_at TEXT NOT NULL
    )''');
    database.execute('''CREATE TABLE journal_lines(
      id INTEGER PRIMARY KEY AUTOINCREMENT, journal_entry_id INTEGER NOT NULL, account_id INTEGER NOT NULL,
      beneficiary_id INTEGER, worker_id INTEGER, partner_id INTEGER, debit INTEGER NOT NULL DEFAULT 0,
      credit INTEGER NOT NULL DEFAULT 0, memo TEXT
    )''');
    database.execute("INSERT INTO cashboxes(id,station_id,name,current_balance,active,ledger_account_code,currency) VALUES(1,1,'Cash',5000,1,'1000','YER'),(2,1,'Bank',2000,1,'1100','YER'),(3,2,'Foreign',7000,1,'1000','YER')");
    database.execute("INSERT INTO payment_methods(id,station_id,name,type,cashbox_id,ledger_account_code,active) VALUES(1,1,'Cash','cash',1,'1000',1),(2,1,'Bank','bank_transfer',2,'1100',1)");
    database.execute("INSERT INTO accounts(id,code,name,type) VALUES(1,'1000','Cash','asset'),(2,'1100','Bank','asset'),(3,'3000','Opening balances','equity'),(4,'5010','Fuel expense','expense'),(5,'5020','Oil expense','expense'),(6,'5030','Other expense','expense'),(7,'5000','Wages','expense'),(8,'2200','Partner balances','liability')");
    const methodGlobal = '11111111-1111-4111-8111-111111111111';
    const cashGlobal = '22222222-2222-4222-8222-222222222222';
    const bankGlobal = '33333333-3333-4333-8333-333333333333';
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(1,'payment_methods',?,1,'2026-11-08T00:00:00Z'),(1,'cashboxes',?,1,'2026-11-08T00:00:00Z'),(1,'cashboxes',?,2,'2026-11-08T00:00:00Z')",[methodGlobal,cashGlobal,bankGlobal]);
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(2,'cashboxes','44444444-4444-4444-8444-444444444444',3,'2026-11-08T00:00:00Z')");
  }
  void prepareManualDebtFixture({
    String beneficiaryGlobalId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  }) {
    database.execute("INSERT INTO beneficiaries(id,station_id,name,status) VALUES(1,1,'Debt Beneficiary','active')");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(1,'beneficiaries',?,1,'2026-11-08T00:00:00Z')",[beneficiaryGlobalId]);
    database.execute("""CREATE TABLE beneficiary_manual_debts(
      id INTEGER PRIMARY KEY AUTOINCREMENT, beneficiary_id INTEGER NOT NULL,
      date TEXT NOT NULL, amount INTEGER NOT NULL, notes TEXT NOT NULL,
      status TEXT NOT NULL, journal_entry_id INTEGER, created_by INTEGER,
      created_at TEXT NOT NULL, cancelled_at TEXT, cancel_reason TEXT
    )""");
    database.execute("CREATE TABLE accounts(id INTEGER PRIMARY KEY,code TEXT UNIQUE NOT NULL,name TEXT NOT NULL,type TEXT NOT NULL)");
    database.execute("INSERT INTO accounts(id,code,name,type) VALUES(1,'1200','Beneficiary receivables','asset'),(2,'3100','Carried balances','equity')");
    database.execute("""CREATE TABLE journal_entries(
      id INTEGER PRIMARY KEY AUTOINCREMENT, station_id INTEGER NOT NULL, date TEXT NOT NULL,
      reference_type TEXT, reference_id INTEGER, description TEXT NOT NULL,
      status TEXT NOT NULL, created_by INTEGER, created_at TEXT NOT NULL
    )""");
    database.execute("""CREATE TABLE journal_lines(
      id INTEGER PRIMARY KEY AUTOINCREMENT, journal_entry_id INTEGER NOT NULL,
      account_id INTEGER NOT NULL, beneficiary_id INTEGER, worker_id INTEGER,
      partner_id INTEGER, debit INTEGER NOT NULL DEFAULT 0,
      credit INTEGER NOT NULL DEFAULT 0, memo TEXT
    )""");
  }

  Map<String,dynamic> manualDebtEvent({
    String id = '55555555-5555-4555-8555-555555555555',
    String debtGlobalId = 'abababab-abab-4bab-8bab-abababababab',
    String beneficiaryGlobalId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    int amount = 1800,
    String operation = 'create',
    int? baseVersion,
    String status = 'posted',
    String? cancelledAt,
    String? cancelReason,
  }) => {
    'event_id': id,
    'entity_type': 'beneficiary_manual_debts',
    'entity_key': 'beneficiary_manual_debts:$debtGlobalId',
    'operation': operation,
    'base_version': baseVersion ?? (operation == 'create' ? 0 : 1),
    'payload': {
      '_global_id': debtGlobalId,
      'beneficiary_id': 1,
      'date': '2026-11-07T09:00:00.000',
      'amount': amount,
      'notes': 'رصيد سابق مثبت',
      'status': status,
      'journal_entry_id': 1,
      'created_by': 11,
      'created_at': '2026-11-08T00:00:00.000',
      if (cancelledAt != null) 'cancelled_at': cancelledAt,
      if (cancelReason != null) 'cancel_reason': cancelReason,
      '_global_refs': {
        'beneficiary_id': {'table':'beneficiaries','global_id':beneficiaryGlobalId},
      },
      '_unresolved_refs': {},
    },
  };

  Map<String,dynamic> receiptEvent({
    String id = '33333333-3333-4333-8333-333333333333',
    String paymentGlobalId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    String beneficiaryGlobalId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    int amount = 250,
  }) => {
    'event_id': id,
    'entity_type': 'payments',
    'entity_key': 'payments:$paymentGlobalId',
    'operation': 'create',
    'base_version': 0,
    'payload': {
      '_global_id': paymentGlobalId, 'beneficiary_id': 1, 'partner_id': null, 'worker_id': null,
      'amount': amount, 'date': '2026-11-08T08:30:00.000', 'status': 'posted',
      'payment_method_id': 1, 'cashbox_id': 1, 'reference_number': 'RCPT-001', 'notes': 'test receipt',
      '_global_refs': {
        'beneficiary_id': {'table':'beneficiaries','global_id':beneficiaryGlobalId},
        'payment_method_id': {'table':'payment_methods','global_id':'dddddddd-dddd-4ddd-8ddd-dddddddddddd','name':'Cash','type':'cash'},
        'cashbox_id': {'table':'cashboxes','global_id':'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','name':'Main Cashbox','currency':'YER'},
      },
      '_unresolved_refs': {},
    },
  };



  void preparePartyDebtFixture() {
    database.execute("CREATE TABLE workers(id INTEGER PRIMARY KEY,station_id INTEGER NOT NULL,name TEXT NOT NULL,active INTEGER NOT NULL DEFAULT 1)");
    database.execute("CREATE TABLE partners(id INTEGER PRIMARY KEY,station_id INTEGER NOT NULL,name TEXT NOT NULL,active INTEGER NOT NULL DEFAULT 1)");
    database.execute("""CREATE TABLE worker_transactions(
      id INTEGER PRIMARY KEY AUTOINCREMENT,worker_id INTEGER NOT NULL,station_id INTEGER NOT NULL,
      date TEXT NOT NULL,type TEXT NOT NULL,hours REAL NOT NULL DEFAULT 0,
      rate_snapshot REAL NOT NULL DEFAULT 0,percentage_snapshot REAL NOT NULL DEFAULT 0,
      amount INTEGER NOT NULL,reference_type TEXT,reference_id INTEGER,notes TEXT,created_by INTEGER
    )""");
    database.execute("""CREATE TABLE partner_transactions(
      id INTEGER PRIMARY KEY AUTOINCREMENT,partner_id INTEGER NOT NULL,station_id INTEGER NOT NULL,
      date TEXT NOT NULL,type TEXT NOT NULL,amount INTEGER NOT NULL,ownership_snapshot REAL,
      reference_type TEXT,reference_id INTEGER,notes TEXT,created_by INTEGER
    )""");
    database.execute("""CREATE TABLE accounts(
      id INTEGER PRIMARY KEY AUTOINCREMENT,code TEXT UNIQUE NOT NULL,name TEXT NOT NULL,
      type TEXT NOT NULL,parent_id INTEGER
    )""");
    database.execute("INSERT INTO accounts(id,code,name,type,parent_id) VALUES(1,'2100','Workers','liability',NULL),(2,'2200','Partners','liability',NULL),(3,'3000','Opening equity','equity',NULL)");
    database.execute("""CREATE TABLE journal_entries(
      id INTEGER PRIMARY KEY AUTOINCREMENT,station_id INTEGER NOT NULL,date TEXT NOT NULL,
      reference_type TEXT,reference_id INTEGER,description TEXT NOT NULL,status TEXT NOT NULL,
      created_by INTEGER,created_at TEXT NOT NULL
    )""");
    database.execute("""CREATE TABLE journal_lines(
      id INTEGER PRIMARY KEY AUTOINCREMENT,journal_entry_id INTEGER NOT NULL,account_id INTEGER NOT NULL,
      beneficiary_id INTEGER,worker_id INTEGER,partner_id INTEGER,debit INTEGER NOT NULL DEFAULT 0,
      credit INTEGER NOT NULL DEFAULT 0,memo TEXT
    )""");
    database.execute("CREATE TABLE cashboxes(id INTEGER PRIMARY KEY,station_id INTEGER NOT NULL,current_balance INTEGER NOT NULL)");
    database.execute("INSERT INTO cashboxes(id,station_id,current_balance) VALUES(1,1,777)");
    database.execute("INSERT INTO workers(id,station_id,name,active) VALUES(1,1,'Worker A',1),(2,2,'Worker B',1)");
    database.execute("INSERT INTO partners(id,station_id,name,active) VALUES(1,1,'Partner A',1),(2,2,'Partner B',1)");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(1,'workers','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',1,'2026-11-08T00:00:00Z'),(2,'workers','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',2,'2026-11-08T00:00:00Z'),(1,'partners','cccccccc-cccc-4ccc-8ccc-cccccccccccc',1,'2026-11-08T00:00:00Z'),(2,'partners','dddddddd-dddd-4ddd-8ddd-dddddddddddd',2,'2026-11-08T00:00:00Z')");
  }

  Map<String,dynamic> partyDebtEvent({
    required bool worker,
    String? eventId,
    String? transactionGlobalId,
    String? partyGlobalId,
    int amount = 4200,
    int baseVersion = 0,
  }) {
    final table = worker ? 'worker_transactions' : 'partner_transactions';
    final partyColumn = worker ? 'worker_id' : 'partner_id';
    final globalId = transactionGlobalId ?? (worker
      ? 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
      : 'ffffffff-ffff-4fff-8fff-ffffffffffff');
    final partyId = partyGlobalId ?? (worker
      ? 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
      : 'cccccccc-cccc-4ccc-8ccc-cccccccccccc');
    return {
      'event_id':eventId ?? (worker
        ? '11111111-aaaa-4111-8111-111111111111'
        : '22222222-bbbb-4222-8222-222222222222'),
      'entity_type':table,
      'entity_key':'$table:$globalId',
      'operation':'create',
      'base_version':baseVersion,
      'payload':{
        '_global_id':globalId,
        if(worker) 'worker_id':1 else 'partner_id':1,
        'type':'opening_balance',
        'date':'2026-11-07T09:00:00.000',
        'amount':amount,
        'reference_type':'previous_debt',
        'reference_id':99999,
        'notes':'مديونية سابقة تجريبية',
        if(worker) 'hours':0,
        if(worker) 'rate_snapshot':0,
        if(worker) 'percentage_snapshot':0,
        if(!worker) 'ownership_snapshot':null,
        '_global_refs': worker
          ? {'worker_id':{'table':'workers','global_id':partyId}}
          : {'partner_id':{'table':'partners','global_id':partyId}},
        '_unresolved_refs':{},
      },
    };
  }

  test('sync enforces terminal queue transitions and rejects reopening completed turns', () async {
    database.execute("INSERT INTO beneficiaries(id,station_id,name,status) VALUES(1,1,'A','active')");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(1,'beneficiaries','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',1,'2026-11-08T00:00:00Z')");
    const global = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    final create = await postEvents(stationOneToken, [{
      'event_id':'15111111-1111-4111-8111-111111111111',
      'entity_type':'queue_entries', 'entity_key':'queue_entries:$global',
      'operation':'create', 'base_version':0,
      'payload':{
        '_global_id':global, 'position':1, 'status':'waiting',
        '_global_refs':{'beneficiary_id':{'table':'beneficiaries','global_id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'}},
      },
    }]);
    expect(create['results'][0]['status'], 'accepted');
    final complete = await postEvents(stationOneToken, [{
      'event_id':'16111111-1111-4111-8111-111111111111',
      'entity_type':'queue_entries', 'entity_key':'queue_entries:$global',
      'operation':'update', 'base_version':1,
      'payload':{
        '_global_id':global, 'status':'completed',
        '_global_refs':{'beneficiary_id':{'table':'beneficiaries','global_id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'}},
      },
    }]);
    expect(complete['results'][0]['status'], 'accepted');
    final reopen = await postEvents(stationOneToken, [{
      'event_id':'17111111-1111-4111-8111-111111111111',
      'entity_type':'queue_entries', 'entity_key':'queue_entries:$global',
      'operation':'update', 'base_version':2,
      'payload':{
        '_global_id':global, 'status':'waiting',
        '_global_refs':{'beneficiary_id':{'table':'beneficiaries','global_id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'}},
      },
    }]);
    expect(reopen['results'][0]['status'], 'rejected');
    expect(database.select('SELECT status FROM queue_entries').first['status'], 'completed');
  });

  test('sync applies queue and booking creates using station-owned global beneficiary refs', () async {
    database.execute("INSERT INTO beneficiaries(id,station_id,name,status) VALUES(1,1,'A','active')");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(1,'beneficiaries','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',1,'2026-11-08T00:00:00Z')");
    final queueGlobal = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    final bookingGlobal = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    final results = await postEvents(stationOneToken, [
      {
        'event_id':'12111111-1111-4111-8111-111111111111',
        'entity_type':'queue_entries',
        'entity_key':'queue_entries:$queueGlobal',
        'operation':'create',
        'base_version':0,
        'payload':{
          '_global_id':queueGlobal, 'position':1, 'cycle_number':1,
          'status':'waiting', 'postponed_count':0,
          '_global_refs':{
            'beneficiary_id':{'table':'beneficiaries','global_id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'},
          },
        },
      },
      {
        'event_id':'13111111-1111-4111-8111-111111111111',
        'entity_type':'booking_requests',
        'entity_key':'booking_requests:$bookingGlobal',
        'operation':'create',
        'base_version':0,
        'payload':{
          '_global_id':bookingGlobal, 'status':'new',
          'scheduled_date':'2026-11-09',
          '_global_refs':{
            'beneficiary_id':{'table':'beneficiaries','global_id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'},
          },
        },
      },
    ]);
    final statuses = (results['results'] as List).map((x) => x['status']).toList();
    expect(statuses, everyElement('accepted'));
    expect(database.select("SELECT COUNT(*) n FROM queue_entries WHERE beneficiary_id=1 AND status='waiting'").first['n'], 1);
    expect(database.select("SELECT COUNT(*) n FROM booking_requests WHERE beneficiary_id=1 AND status='new'").first['n'], 1);
    expect(database.select("SELECT COUNT(*) n FROM sync_entity_links WHERE entity_type IN ('queue_entries','booking_requests')").first['n'], 2);
  });

  test('sync rejects queue and booking references owned by another station', () async {
    database.execute("INSERT INTO beneficiaries(id,station_id,name,status) VALUES(2,2,'B','active')");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(2,'beneficiaries','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',2,'2026-11-08T00:00:00Z')");
    final global = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    final result = await postEvents(stationOneToken, [{
      'event_id':'14111111-1111-4111-8111-111111111111',
      'entity_type':'queue_entries',
      'entity_key':'queue_entries:$global',
      'operation':'create',
      'base_version':0,
      'payload':{
        '_global_id':global, 'position':1, 'status':'waiting',
        '_global_refs':{
          'beneficiary_id':{'table':'beneficiaries','global_id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'},
        },
      },
    }]);
    expect(result['results'][0]['status'], 'rejected');
    expect(database.select('SELECT COUNT(*) n FROM queue_entries').first['n'], 0);
  });

  test('worker and partner opening debts create balanced central journals once', () async {
    preparePartyDebtFixture();
    for (final worker in [true,false]) {
      final command = partyDebtEvent(worker:worker);
      final first = await postEvents(stationOneToken,[command]);
      final replay = await postEvents(stationOneToken,[command]);
      final table = worker ? 'worker_transactions' : 'partner_transactions';
      expect((first['results'] as List).first['status'],'accepted');
      expect((replay['results'] as List).first['status'],'duplicate');
      final duplicateIdentity = partyDebtEvent(
        worker:worker,
        eventId:worker?'99999999-aaaa-4999-8999-999999999999':'aaaaaaaa-bbbb-4aaa-8aaa-aaaaaaaaaaaa',
        baseVersion:1,
      );
      final duplicateIdentityResult = await postEvents(stationOneToken,[duplicateIdentity]);
      expect((duplicateIdentityResult['results'] as List).first['status'],'rejected');
      expect(database.select('SELECT COUNT(*) n FROM ' + table).single['n'],1);
      expect(database.select('SELECT COUNT(*) n FROM journal_entries').single['n'],worker ? 1 : 2);
      final journal = database.select('SELECT id FROM journal_entries ORDER BY id DESC LIMIT 1').single['id'];
      final totals = database.select('SELECT SUM(debit) debit,SUM(credit) credit,COUNT(*) lines FROM journal_lines WHERE journal_entry_id=?',[journal]).single;
      expect(totals['debit'],4200);
      expect(totals['credit'],4200);
      expect(totals['lines'],2);
      expect(database.select('SELECT reference_id FROM ' + table).single['reference_id'],journal);
      expect(database.select("SELECT COUNT(*) n FROM sync_entity_links WHERE entity_type=?",[table]).single['n'],1);
    }
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],777);
  });

  test('worker and partner debt handlers reject a party owned by another station', () async {
    preparePartyDebtFixture();
    for (final worker in [true,false]) {
      final command = partyDebtEvent(
        worker:worker,
        eventId:worker?'33333333-aaaa-4333-8333-333333333333':'44444444-bbbb-4444-8444-444444444444',
        transactionGlobalId:worker?'12121212-1212-4212-8212-121212121212':'13131313-1313-4313-8313-131313131313',
        partyGlobalId:worker?'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb':'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      );
      final result = await postEvents(stationOneToken,[command]);
      expect((result['results'] as List).first['status'],'rejected');
    }
    expect(database.select('SELECT COUNT(*) n FROM worker_transactions').single['n'],0);
    expect(database.select('SELECT COUNT(*) n FROM partner_transactions').single['n'],0);
    expect(database.select('SELECT COUNT(*) n FROM journal_entries').single['n'],0);
  });

  test('worker and partner debt handlers roll back transaction and journal when a journal line fails', () async {
    preparePartyDebtFixture();
    for (final worker in [true,false]) {
      database.execute("CREATE TRIGGER fail_party_debt_line BEFORE INSERT ON journal_lines WHEN NEW.memo='مديونية سابقة تجريبية' BEGIN SELECT RAISE(ABORT,'forced journal line failure'); END");
      final command = partyDebtEvent(
        worker:worker,
        eventId:worker?'55555555-aaaa-4555-8555-555555555555':'66666666-bbbb-4666-8666-666666666666',
        transactionGlobalId:worker?'14141414-1414-4414-8414-141414141414':'15151515-1515-4515-8515-151515151515',
      );
      final result = await postEvents(stationOneToken,[command]);
      expect((result['results'] as List).first['status'],'rejected');
      database.execute('DROP TRIGGER fail_party_debt_line');
    }
    expect(database.select('SELECT COUNT(*) n FROM worker_transactions').single['n'],0);
    expect(database.select('SELECT COUNT(*) n FROM partner_transactions').single['n'],0);
    expect(database.select('SELECT COUNT(*) n FROM journal_entries').single['n'],0);
    expect(database.select('SELECT COUNT(*) n FROM journal_lines').single['n'],0);
    expect(database.select("SELECT COUNT(*) n FROM accounts WHERE code LIKE '2100.W%' OR code LIKE '2200.P%'").single['n'],0);
    expect(database.select("SELECT COUNT(*) n FROM sync_entity_links WHERE entity_type IN ('worker_transactions','partner_transactions')").single['n'],0);
  });

  test('worker and partner handlers reject invalid amount, role, and non-debt transaction types', () async {
    preparePartyDebtFixture();
    final invalid = partyDebtEvent(worker:true,amount:0);
    expect(((await postEvents(stationOneToken,[invalid]))['results'] as List).first['status'],'rejected');
    final badType = partyDebtEvent(worker:false,eventId:'77777777-bbbb-4777-8777-777777777777');
    (badType['payload'] as Map)['reference_type']='profit_share';
    expect(((await postEvents(stationOneToken,[badType]))['results'] as List).first['status'],'rejected');
    final operationsToken = JWT({'kind':'admin','userId':11,'stationId':1,'role':'operations'}).sign(SecretKey(secret));
    database.execute("UPDATE app_users SET role='operations' WHERE id=11");
    final denied = partyDebtEvent(worker:true,eventId:'88888888-aaaa-4888-8888-888888888888');
    expect(((await postEvents(operationsToken,[denied]))['results'] as List).first['status'],'rejected');
    expect(database.select('SELECT COUNT(*) n FROM worker_transactions').single['n'],0);
    expect(database.select('SELECT COUNT(*) n FROM partner_transactions').single['n'],0);
  });

  test('manual beneficiary debt creates one balanced journal and replay is idempotent', () async {
    prepareManualDebtFixture();
    final command = manualDebtEvent();
    final first = await postEvents(stationOneToken,[command]);
    final replay = await postEvents(stationOneToken,[command]);
    expect((first['results'] as List).first['status'],'accepted');
    expect((replay['results'] as List).first['status'],'duplicate');
    expect(database.select('SELECT COUNT(*) n FROM beneficiary_manual_debts').single['n'],1);
    expect(database.select('SELECT COUNT(*) n FROM journal_entries').single['n'],1);
    expect(database.select('SELECT COUNT(*) n FROM journal_lines').single['n'],2);
    final totals=database.select('SELECT SUM(debit) debit,SUM(credit) credit FROM journal_lines').single;
    expect(totals['debit'],1800);
    expect(totals['credit'],1800);
    expect(database.select("SELECT COUNT(*) n FROM sync_entity_links WHERE entity_type='beneficiary_manual_debts'").single['n'],1);
  });

  test('manual beneficiary debt rejects a beneficiary owned by another station', () async {
    prepareManualDebtFixture();
    database.execute("INSERT INTO beneficiaries(id,station_id,name,status) VALUES(2,2,'Foreign Debt Beneficiary','active')");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(2,'beneficiaries','ffffffff-ffff-4fff-8fff-ffffffffffff',2,'2026-11-08T00:00:00Z')");
    final result=await postEvents(stationOneToken,[manualDebtEvent(beneficiaryGlobalId:'ffffffff-ffff-4fff-8fff-ffffffffffff')]);
    expect((result['results'] as List).first['status'],'rejected');
    expect(database.select('SELECT COUNT(*) n FROM beneficiary_manual_debts').single['n'],0);
    expect(database.select('SELECT COUNT(*) n FROM journal_entries').single['n'],0);
    expect(database.select('SELECT COUNT(*) n FROM sync_entity_links WHERE entity_type=' + "'beneficiary_manual_debts'").single['n'],0);
  });

  test('manual beneficiary debt rejects non-positive or fractional amounts', () async {
    prepareManualDebtFixture();
    for (final amount in [0,-5]) {
      final result=await postEvents(stationOneToken,[manualDebtEvent(id:amount==0?'56565656-5656-4565-8565-565656565656':'57575757-5757-4575-8575-575757575757',amount:amount)]);
      expect((result['results'] as List).first['status'],'rejected');
    }
    final fractional=manualDebtEvent(id:'58585858-5858-4585-8585-585858585858');
    (fractional['payload'] as Map<String,dynamic>)['amount']=12.5;
    final result=await postEvents(stationOneToken,[fractional]);
    expect((result['results'] as List).first['status'],'rejected');
    expect(database.select('SELECT COUNT(*) n FROM beneficiary_manual_debts').single['n'],0);
  });

  test('operations role cannot create manual beneficiary debt', () async {
    prepareManualDebtFixture();
    database.execute("UPDATE app_users SET role='operations' WHERE id=11");
    final token=JWT({'kind':'admin','userId':11,'stationId':1,'role':'operations'}).sign(SecretKey(secret));
    final result=await postEvents(token,[manualDebtEvent()]);
    expect((result['results'] as List).first['status'],'rejected');
    expect(database.select('SELECT COUNT(*) n FROM beneficiary_manual_debts').single['n'],0);
  });

  test('manual beneficiary debt rolls back fully when journal creation fails', () async {
    prepareManualDebtFixture();
    database.execute("""CREATE TRIGGER reject_manual_debt_journal BEFORE INSERT ON journal_entries
      BEGIN SELECT RAISE(ABORT,'journal unavailable'); END""");
    final result=await postEvents(stationOneToken,[manualDebtEvent()]);
    expect((result['results'] as List).first['status'],'rejected');
    expect(database.select('SELECT COUNT(*) n FROM beneficiary_manual_debts').single['n'],0);
    expect(database.select('SELECT COUNT(*) n FROM journal_entries').single['n'],0);
    expect(database.select('SELECT COUNT(*) n FROM sync_event_log').single['n'],0);
    expect(database.select('SELECT COUNT(*) n FROM sync_entity_versions').single['n'],0);
    expect(database.select("SELECT COUNT(*) n FROM sync_entity_links WHERE entity_type='beneficiary_manual_debts'").single['n'],0);
  });

  test('manual beneficiary debt cancellation reverses the journal exactly once', () async {
    prepareManualDebtFixture();
    final create=manualDebtEvent();
    final accepted=await postEvents(stationOneToken,[create]);
    expect((accepted['results'] as List).first['status'],'accepted');
    final cancel=manualDebtEvent(
      id:'59595959-5959-4595-8595-595959595959',
      operation:'update',
      status:'cancelled',
      cancelledAt:'2026-11-08T10:00:00.000',
      cancelReason:'إدخال مكرر',
    );
    final cancelled=await postEvents(stationOneToken,[cancel]);
    expect((cancelled['results'] as List).first['status'],'accepted');
    expect(database.select("SELECT status FROM beneficiary_manual_debts").single['status'],'cancelled');
    expect(database.select('SELECT COUNT(*) n FROM journal_entries').single['n'],2);
    final totals=database.select('SELECT SUM(debit) debit,SUM(credit) credit FROM journal_lines').single;
    expect(totals['debit'],3600);
    expect(totals['credit'],3600);
    final repeated=manualDebtEvent(
      id:'60606060-6060-4606-8606-606060606060',
      operation:'update',
      baseVersion:2,
      status:'cancelled',
      cancelledAt:'2026-11-08T10:01:00.000',
      cancelReason:'إلغاء مكرر',
    );
    final rejected=await postEvents(stationOneToken,[repeated]);
    expect((rejected['results'] as List).first['status'],'rejected');
    expect(database.select('SELECT COUNT(*) n FROM journal_entries').single['n'],2);
  });

  test('manual debt cancellation cannot alter the amount', () async {
    prepareManualDebtFixture();
    await postEvents(stationOneToken,[manualDebtEvent()]);
    final altered=manualDebtEvent(
      id:'61616161-6161-4616-8616-616161616161',
      amount:9999,
      operation:'update',
      status:'cancelled',
      cancelledAt:'2026-11-08T10:00:00.000',
      cancelReason:'tamper',
    );
    final result=await postEvents(stationOneToken,[altered]);
    expect((result['results'] as List).first['status'],'rejected');
    expect(database.select("SELECT status FROM beneficiary_manual_debts").single['status'],'posted');
    expect(database.select('SELECT COUNT(*) n FROM journal_entries').single['n'],1);
  });

  test('beneficiary receipt applies once and replay returns duplicate without double posting', () async {
    prepareReceiptFixture();
    final command = receiptEvent();
    final first = await postEvents(stationOneToken, [command]);
    final replay = await postEvents(stationOneToken, [command]);
    expect((first['results'] as List).first['status'], 'accepted');
    expect((replay['results'] as List).first['status'], 'duplicate');
    expect(database.select('SELECT COUNT(*) AS n FROM payments').single['n'], 1);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'], 750);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_entries').single['n'], 1);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_lines').single['n'], 2);
    expect(database.select('SELECT SUM(debit) AS debit,SUM(credit) AS credit FROM journal_lines').single['debit'], 250);
    expect(database.select('SELECT SUM(debit) AS debit,SUM(credit) AS credit FROM journal_lines').single['credit'], 250);
  });

  test('receipt publishes server-owned journal and cashbox projections to the second device once', () async {
    prepareReceiptFixture();
    final command = receiptEvent();
    final payload = Map<String, dynamic>.from(command['payload'] as Map);
    payload['_derived_global_ids'] = {
      'journal_entries': ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab'],
      'journal_lines': [
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbc',
        'cccccccc-cccc-4ccc-8ccc-cccccccccccd',
      ],
      'cashboxes': ['eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeef'],
    };
    command['payload'] = payload;
    final accepted = await postEvents(stationOneToken, [command], device: 'device-a');
    expect((accepted['results'] as List).first['status'], 'accepted');

    final originInbox = await getInbox(stationOneToken, device: 'device-a');
    final originEvents = originInbox['events'] as List;
    expect(
      originEvents.map((event) => (event as Map)['entity_type']).toList(),
      ['journal_entries', 'journal_lines', 'journal_lines', 'cashboxes'],
    );

    final secondDeviceInbox = await getInbox(stationOneToken, device: 'device-b');
    final events = secondDeviceInbox['events'] as List;
    expect(
      events.map((event) => (event as Map)['entity_type']).toList(),
      ['payments', 'journal_entries', 'journal_lines', 'cashboxes'],
    );
    expect(
      events.skip(1).map((event) => (event as Map)['source_device']).toSet(),
      {'__server_projection__'},
    );

    final replay = await postEvents(stationOneToken, [command], device: 'device-a');
    expect((replay['results'] as List).first['status'], 'duplicate');
    expect(database.select('SELECT COUNT(*) n FROM payments').single['n'], 1);
    expect(database.select('SELECT COUNT(*) n FROM journal_entries').single['n'], 1);
    expect(database.select('SELECT COUNT(*) n FROM journal_lines').single['n'], 2);
    expect(database.select('SELECT COUNT(*) n FROM sync_event_log').single['n'], 4);
    final totals = database.select(
      'SELECT SUM(debit) debit,SUM(credit) credit FROM journal_lines',
    ).single;
    expect(totals['debit'], 250);
    expect(totals['credit'], 250);
  });

  test('receipt rejects a beneficiary identity owned by another station without writes', () async {
    prepareReceiptFixture();
    database.execute("INSERT INTO beneficiaries(id,station_id,name,status) VALUES(2,2,'Foreign Beneficiary','active')");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(2,'beneficiaries','ffffffff-ffff-4fff-8fff-ffffffffffff',2,'2026-11-08T00:00:00Z')");
    final result = await postEvents(stationOneToken, [receiptEvent(beneficiaryGlobalId:'ffffffff-ffff-4fff-8fff-ffffffffffff')]);
    expect((result['results'] as List).first['status'], 'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM payments').single['n'], 0);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'], 500);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_entries').single['n'], 0);
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').single['n'], 0);
  });

  test('receipt rejects a globally identified payment method from another station', () async {
    prepareReceiptFixture();
    database.execute("INSERT INTO payment_methods(id,station_id,name,type,cashbox_id,ledger_account_code,active) VALUES(2,2,'Cash','cash',NULL,'1000',1)");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(2,'payment_methods','ffffffff-ffff-4fff-8fff-ffffffffffff',2,'2026-11-08T00:00:00Z')");
    final command = receiptEvent();
    final payload = Map<String,dynamic>.from(command['payload'] as Map);
    final refs = Map<String,dynamic>.from(payload['_global_refs'] as Map);
    refs['payment_method_id'] = {'table':'payment_methods','global_id':'ffffffff-ffff-4fff-8fff-ffffffffffff','name':'Cash','type':'cash'};
    payload['_global_refs'] = refs;
    command['payload'] = payload;
    final result = await postEvents(stationOneToken,[command]);
    expect((result['results'] as List).first['status'],'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM payments').single['n'],0);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],500);
  });

  test('operations role cannot submit beneficiary receipt commands', () async {
    prepareReceiptFixture();
    // Keep the database account role consistent with the signed JWT so the
    // request reaches the payment-domain authorization check.
    database.execute("UPDATE app_users SET role='operations' WHERE id=11");
    final operationsToken = JWT({'kind':'admin','userId':11,'stationId':1,'role':'operations'}).sign(SecretKey(secret));
    final result = await postEvents(operationsToken,[receiptEvent()]);
    expect((result['results'] as List).first['status'],'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM payments').single['n'],0);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],500);
  });

  test('receipt rejects zero amount without creating any financial rows', () async {
    prepareReceiptFixture();
    final result = await postEvents(stationOneToken,[receiptEvent(amount:0)]);
    expect((result['results'] as List).first['status'],'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM payments').single['n'],0);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],500);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_entries').single['n'],0);
  });

  test('receipt event id cannot be reused with a changed amount', () async {
    prepareReceiptFixture();
    final first = await postEvents(stationOneToken,[receiptEvent()]);
    final changed = await postEvents(stationOneToken,[receiptEvent(amount:999)]);
    expect((first['results'] as List).first['status'],'accepted');
    expect((changed['results'] as List).first['status'],'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM payments').single['n'],1);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],750);
  });

  test('receipt journal failure rolls back payment and cashbox balance', () async {
    prepareReceiptFixture();
    database.execute("DELETE FROM accounts WHERE code='1200'");
    final result = await postEvents(stationOneToken, [receiptEvent()]);
    expect((result['results'] as List).first['status'], 'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM payments').single['n'], 0);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'], 500);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_entries').single['n'], 0);
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').single['n'], 0);
  });

  test('replayed event is acknowledged as duplicate and stored once', () async {
    final first = await postEvents(stationOneToken,[event()]);
    final replay = await postEvents(stationOneToken,[event()]);
    expect((first['results'] as List).first['status'],'accepted');
    expect((replay['results'] as List).first['status'],'duplicate');
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').first['n'],1);
    expect(database.select('SELECT COUNT(*) AS n FROM beneficiaries WHERE station_id=1').first['n'],1);
  });

  test('reusing an event id with a different payload is rejected', () async {
    final first = await postEvents(stationOneToken, [event()]);
    final changed = event();
    changed['payload'] = {
      '_global_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'name': 'Tampered Beneficiary',
    };
    final replay = await postEvents(stationOneToken, [changed]);
    expect((first['results'] as List).first['status'], 'accepted');
    expect((replay['results'] as List).first['status'], 'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').first['n'], 1);
    expect(database.select('SELECT payload_json FROM sync_event_log').first['payload_json'],
        '{"_global_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Test Beneficiary"}');
  });

  test('unsupported entity types are rejected before entering the event log', () async {
    final invalid = event();
    invalid['entity_type'] = 'app_users';
    invalid['entity_key'] = 'app_users:admin';
    final response = await postEvents(stationOneToken, [invalid]);
    expect((response['results'] as List).first['status'], 'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').first['n'], 0);
    expect(database.select('SELECT COUNT(*) AS n FROM sync_entity_versions').first['n'], 0);
  });

  test('recognized but unimplemented financial events are rejected without acknowledgement', () async {
    final invalid = event();
    invalid['entity_type'] = 'payments';
    invalid['entity_key'] = 'payments:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final response = await postEvents(stationOneToken, [invalid]);
    expect((response['results'] as List).first['status'], 'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').single['n'], 0);
  });

  test('stale base version is recorded as conflict without advancing version', () async {
    await postEvents(stationOneToken,[event()]);
    final stale = event(
      id:'22222222-2222-4222-8222-222222222222',
      baseVersion:0,
    );
    final result = await postEvents(stationOneToken,[stale],device:'device-c');
    expect((result['results'] as List).first['status'],'conflict');
    expect(database.select(
      "SELECT version FROM sync_entity_versions WHERE station_id=1 AND entity_key='beneficiaries:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'",
    ).first['version'],1);
  });

  test('inbox is isolated by authenticated station', () async {
    await postEvents(stationOneToken,[event()]);
    final one = await getInbox(stationOneToken);
    final two = await getInbox(stationTwoToken);
    expect((one['events'] as List).length,1);
    expect((two['events'] as List),isEmpty);
  });

  test('inbox does not echo events back to their originating device', () async {
    await postEvents(stationOneToken,[event()],device:'device-a');
    final inbox = await getInbox(stationOneToken,device:'device-a');
    expect((inbox['events'] as List),isEmpty);
  });
  test('beneficiary create and update are applied atomically to business rows', () async {
    const globalId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final first = await postEvents(stationOneToken, [
      event(globalId: globalId, payload: {'phone': '777'}),
    ]);
    expect((first['results'] as List).first['status'], 'accepted');
    final row = database.select(
      "SELECT id,name,phone,station_id FROM beneficiaries WHERE station_id=1",
    ).single;
    expect(row['name'], 'Test Beneficiary');
    expect(row['phone'], '777');
    expect(row['station_id'], 1);

    final second = await postEvents(stationOneToken, [
      event(
        id: '44444444-4444-4444-8444-444444444444',
        globalId: globalId,
        baseVersion: 1,
        operation: 'update',
        payload: {'name': 'Updated Beneficiary'},
      ),
    ]);
    expect((second['results'] as List).first['status'], 'accepted');
    expect(database.select(
      "SELECT name FROM beneficiaries WHERE station_id=1",
    ).single['name'], 'Updated Beneficiary');
    expect(database.select(
      "SELECT version FROM sync_entity_versions WHERE station_id=1 AND entity_key='beneficiaries:$globalId'",
    ).single['version'], 2);
  });

  test('failed business application rolls back event log and entity version', () async {
    final invalid = event(payload: {'name': ''});
    final response = await postEvents(stationOneToken, [invalid]);
    expect((response['results'] as List).first['status'], 'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM beneficiaries').single['n'], 0);
    expect(database.select('SELECT COUNT(*) AS n FROM sync_event_log').single['n'], 0);
    expect(database.select('SELECT COUNT(*) AS n FROM sync_entity_versions').single['n'], 0);
  });

  test('event from another station cannot create a row in the first station', () async {
    final response = await postEvents(stationTwoToken, [event()]);
    expect((response['results'] as List).first['status'], 'accepted');
    expect(database.select('SELECT COUNT(*) AS n FROM beneficiaries WHERE station_id=1').single['n'], 0);
    expect(database.select('SELECT COUNT(*) AS n FROM beneficiaries WHERE station_id=2').single['n'], 1);
  });


  test('beneficiary API reads expose the stable global identity for client mapping', () async {
    const globalId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    final created = await postEvents(stationOneToken, [
      event(globalId: globalId, payload: {'name': 'Mapped Beneficiary'}),
    ]);
    expect((created['results'] as List).first['status'], 'accepted');

    final response = await server.router().call(Request(
      'GET',
      Uri.parse('http://localhost/api/v1/beneficiaries'),
      headers: {'authorization': 'Bearer $stationOneToken'},
    ));
    expect(response.statusCode, 200);
    final rows = jsonDecode(await response.readAsString()) as List;
    expect(rows, hasLength(1));
    expect(rows.single['_global_id'], globalId);
    expect(rows.single['name'], 'Mapped Beneficiary');
  });



    test('beneficiary detail and irrigation history resolve global UUID within JWT station', () async {
    const globalId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    database.execute('ALTER TABLE beneficiaries ADD COLUMN opening_balance INTEGER NOT NULL DEFAULT 0');
    database.execute('ALTER TABLE beneficiaries ADD COLUMN carried_balance INTEGER NOT NULL DEFAULT 0');
    database.execute('''CREATE TABLE station_settings(
      station_id INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
      PRIMARY KEY(station_id,key)
    )''');
    await postEvents(stationOneToken, [
      event(globalId: globalId, payload: {'name': 'Global Detail'}),
    ]);
    database.execute('''CREATE TABLE irrigations(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL,
      beneficiary_id INTEGER NOT NULL, date TEXT NOT NULL DEFAULT '2026-11-08',
      start_datetime TEXT NOT NULL, end_datetime TEXT,
      system_type TEXT, minutes INTEGER NOT NULL DEFAULT 0,
      cloud_minutes INTEGER NOT NULL DEFAULT 0,
      chargeable_minutes INTEGER NOT NULL DEFAULT 0,
      total_amount INTEGER NOT NULL DEFAULT 0,
      paid_amount INTEGER NOT NULL DEFAULT 0, notes TEXT,
      status TEXT NOT NULL
    )''');
    database.execute('''CREATE TABLE payments(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL,
      beneficiary_id INTEGER, date TEXT NOT NULL,
      amount INTEGER NOT NULL, status TEXT NOT NULL, notes TEXT
    )''');
    database.execute('''CREATE TABLE diesel_movements(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL,
      beneficiary_id INTEGER, irrigation_id INTEGER,
      kind TEXT NOT NULL, amount INTEGER NOT NULL,
      date TEXT NOT NULL, notes TEXT
    )''');
    database.execute('''CREATE TABLE beneficiary_manual_debts(
      id INTEGER PRIMARY KEY, beneficiary_id INTEGER NOT NULL,
      date TEXT NOT NULL, amount INTEGER NOT NULL, notes TEXT,
      status TEXT NOT NULL, cancelled_at TEXT, cancel_reason TEXT
    )''');
    database.execute("INSERT INTO irrigations(id,station_id,beneficiary_id,start_datetime,status) VALUES(1,1,1,'2026-11-08T08:00:00','posted')");
    Future<Response> get(String token, String suffix) => server.router().call(Request(
      'GET',
      Uri.parse('http://localhost/api/v1/beneficiaries/$globalId$suffix'),
      headers: {'authorization': 'Bearer $token'},
    ));
    final detail = await get(stationOneToken, '');
    expect(detail.statusCode, 200);
    final body = jsonDecode(await detail.readAsString()) as Map<String, dynamic>;
    expect(body['_global_id'], globalId);
    expect(body['name'], 'Global Detail');
    final history = await get(stationOneToken, '/statement');
    expect(history.statusCode, 200);
    final rows = jsonDecode(await history.readAsString()) as List;
    expect(rows, hasLength(1));
    expect(rows.single['id'], 1);
    final crossStation = await get(stationTwoToken, '');
    expect(crossStation.statusCode, 404);
  });

  test('complete beneficiary statement is station-isolated and does not duplicate ledger movements', () async {
    const globalId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    database.execute('ALTER TABLE beneficiaries ADD COLUMN opening_balance INTEGER NOT NULL DEFAULT 0');
    database.execute('ALTER TABLE beneficiaries ADD COLUMN carried_balance INTEGER NOT NULL DEFAULT 0');
    await postEvents(stationOneToken, [
      event(globalId: globalId, payload: {'name': 'Statement Beneficiary'}),
    ]);
    database.execute("UPDATE beneficiaries SET opening_balance=40,carried_balance=5 WHERE station_id=1");
    database.execute('''CREATE TABLE irrigations(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL,
      beneficiary_id INTEGER NOT NULL, date TEXT NOT NULL,
      start_datetime TEXT, end_datetime TEXT, system_type TEXT,
      minutes INTEGER, cloud_minutes INTEGER, chargeable_minutes INTEGER,
      total_amount INTEGER NOT NULL, paid_amount INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL, notes TEXT
    )''');
    database.execute('''CREATE TABLE payments(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL,
      beneficiary_id INTEGER, date TEXT NOT NULL, amount INTEGER NOT NULL,
      status TEXT NOT NULL, notes TEXT
    )''');
    database.execute('''CREATE TABLE diesel_movements(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL,
      beneficiary_id INTEGER, irrigation_id INTEGER, kind TEXT NOT NULL,
      amount INTEGER NOT NULL, date TEXT NOT NULL, notes TEXT
    )''');
    database.execute('''CREATE TABLE beneficiary_manual_debts(
      id INTEGER PRIMARY KEY, beneficiary_id INTEGER NOT NULL,
      date TEXT NOT NULL, amount INTEGER NOT NULL, notes TEXT,
      status TEXT NOT NULL, cancelled_at TEXT, cancel_reason TEXT
    )''');
    database.execute('''CREATE TABLE station_settings(
      station_id INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
      PRIMARY KEY(station_id,key)
    )''');
    database.execute("INSERT INTO station_settings(station_id,key,value) VALUES(1,'diesel_delivery_financial_credit','true')");
    database.execute("INSERT INTO irrigations(id,station_id,beneficiary_id,date,start_datetime,end_datetime,system_type,minutes,cloud_minutes,chargeable_minutes,total_amount,paid_amount,status,notes) VALUES(1,1,1,'2026-11-01','2026-11-01T08:00:00','2026-11-01T09:00:00','diesel',60,0,60,100,0,'posted','first irrigation')");
    database.execute("INSERT INTO payments(id,station_id,beneficiary_id,date,amount,status,notes) VALUES(1,1,1,'2026-11-02',30,'posted','cash receipt')");
    database.execute("INSERT INTO diesel_movements(id,station_id,beneficiary_id,irrigation_id,kind,amount,date,notes) VALUES(1,1,1,NULL,'advance',10,'2026-11-03','diesel advance'),(2,1,1,NULL,'delivery',5,'2026-11-04','diesel delivery')");
    database.execute("INSERT INTO beneficiary_manual_debts(id,beneficiary_id,date,amount,notes,status) VALUES(1,1,'2026-11-02',20,'manual balance','posted')");
    database.execute("INSERT INTO beneficiary_manual_debts(id,beneficiary_id,date,amount,notes,status,cancelled_at,cancel_reason) VALUES(2,1,'2026-11-01',7,'cancelled debt','cancelled','2026-11-05','duplicate entry')");

    Future<List<dynamic>> read(String token, String suffix) async {
      final response = await server.router().call(Request(
        'GET',
        Uri.parse('http://localhost/api/v1/beneficiaries/$globalId/statement$suffix'),
        headers: {'authorization': 'Bearer $token'},
      ));
      expect(response.statusCode, 200);
      return jsonDecode(await response.readAsString()) as List<dynamic>;
    }

    final first = await read(stationOneToken, '');
    final replay = await read(stationOneToken, '');
    expect(first, hasLength(9)); // 2 opening rows + 7 distinct source movements.
    expect(replay, first);
    expect(first.map((row) => '${row['type']}:${row['id']}').toSet(), hasLength(9));
    expect(first.last['balance'], 140); // 45 + 100 - 30 + 10 + 20 - 5.
    expect(first.map((row) => row['type']), containsAll([
      's','p','a','manual_debt','manual_debt_reversal','d',
    ]));
    final period = await read(
      stationOneToken,
      '?from=2026-11-02&to=2026-11-03',
    );
    expect(period.first['type'], 'opening_balance');
    expect(period.first['balance'], 152); // Includes the cancelled debt until its 5 November reversal.
    expect(period.last['balance'], 152); // 152 - 30 + 20 + 10.
    final foreign = await server.router().call(Request(
      'GET',
      Uri.parse('http://localhost/api/v1/beneficiaries/$globalId/statement'),
      headers: {'authorization': 'Bearer $stationTwoToken'},
    ));
    expect(foreign.statusCode, 404);
  });

test('legacy beneficiary rows receive a stable global identity on first API read', () async {
    database.execute(
      "INSERT INTO beneficiaries(station_id,name,status) VALUES(1,'Legacy Beneficiary','active')",
    );
    Future<Map<String, dynamic>> read() async {
      final response = await server.router().call(Request(
        'GET',
        Uri.parse('http://localhost/api/v1/beneficiaries'),
        headers: {'authorization': 'Bearer $stationOneToken'},
      ));
      expect(response.statusCode, 200);
      final rows = jsonDecode(await response.readAsString()) as List;
      return Map<String, dynamic>.from(
        rows.singleWhere((row) => row['name'] == 'Legacy Beneficiary') as Map,
      );
    }
    final first = await read();
    final second = await read();
    expect(first['_global_id'], isA<String>());
    expect(first['_global_id'], isNotEmpty);
    expect(second['_global_id'], first['_global_id']);
    expect(first['balance'], 0);
  });



  test('beneficiary API computes balance using only the authenticated station data', () async {
    database.execute('ALTER TABLE beneficiaries ADD COLUMN opening_balance INTEGER NOT NULL DEFAULT 0');
    database.execute('ALTER TABLE beneficiaries ADD COLUMN carried_balance INTEGER NOT NULL DEFAULT 0');
    database.execute('''CREATE TABLE station_settings(
      station_id INTEGER NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
      PRIMARY KEY(station_id,key)
    )''');
    database.execute('''CREATE TABLE irrigations(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, beneficiary_id INTEGER NOT NULL,
      total_amount INTEGER NOT NULL, status TEXT NOT NULL
    )''');
    database.execute('''CREATE TABLE payments(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, beneficiary_id INTEGER NOT NULL,
      amount INTEGER NOT NULL, status TEXT NOT NULL
    )''');
    database.execute('''CREATE TABLE diesel_movements(
      id INTEGER PRIMARY KEY, station_id INTEGER NOT NULL, beneficiary_id INTEGER NOT NULL,
      amount INTEGER NOT NULL, kind TEXT NOT NULL, irrigation_id INTEGER
    )''');
    database.execute('''CREATE TABLE beneficiary_manual_debts(
      id INTEGER PRIMARY KEY, beneficiary_id INTEGER NOT NULL,
      amount INTEGER NOT NULL, status TEXT NOT NULL
    )''');
    database.execute("INSERT INTO beneficiaries(id,station_id,name,status,opening_balance,carried_balance) VALUES(1,1,'Balance A','active',100,20),(2,2,'Balance B','active',500,0)");
    database.execute("INSERT INTO irrigations(station_id,beneficiary_id,total_amount,status) VALUES(1,1,300,'posted'),(2,2,9000,'posted')");
    database.execute("INSERT INTO payments(station_id,beneficiary_id,amount,status) VALUES(1,1,50,'posted'),(2,2,1000,'posted')");
    database.execute("INSERT INTO beneficiary_manual_debts(beneficiary_id,amount,status) VALUES(1,30,'posted')");
    database.execute("INSERT INTO diesel_movements(station_id,beneficiary_id,amount,kind,irrigation_id) VALUES(1,1,10,'advance',NULL)");
    database.execute("INSERT INTO station_settings(station_id,key,value) VALUES(1,'diesel_delivery_financial_credit','false')");

    final response = await server.router().call(Request(
      'GET',
      Uri.parse('http://localhost/api/v1/beneficiaries'),
      headers: {'authorization': 'Bearer $stationOneToken'},
    ));
    expect(response.statusCode, 200);
    final rows = jsonDecode(await response.readAsString()) as List;
    final beneficiary = rows.singleWhere((row) => row['name'] == 'Balance A');
    // Opening 120 + irrigation 300 + manual debt 30 + diesel advance 10 - payment 50.
    expect(beneficiary['balance'], 410);
    expect(rows.where((row) => row['name'] == 'Balance B'), isEmpty);
  });



  test('master-data events apply atomically with station ownership and soft deletion', () async {
    database.execute('''CREATE TABLE pumps(
      id INTEGER PRIMARY KEY AUTOINCREMENT, station_id INTEGER NOT NULL,
      name TEXT NOT NULL, system_type TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1,
      notes TEXT, created_at TEXT, updated_at TEXT
    )''');
    const globalId = 'abababab-abab-4bab-8bab-abababababab';
    Map<String, dynamic> masterEvent({
      required String eventId,
      required String operation,
      required int baseVersion,
      required Map<String, dynamic> payload,
    }) => {
      'event_id': eventId,
      'entity_type': 'pumps',
      'entity_key': 'pumps:$globalId',
      'operation': operation,
      'base_version': baseVersion,
      'payload': {'_global_id': globalId, ...payload},
    };

    final created = await postEvents(stationOneToken, [
      masterEvent(
        eventId: '12111111-1111-4111-8111-111111111111',
        operation: 'create',
        baseVersion: 0,
        payload: {'name': 'Pump A', 'system_type': 'diesel'},
      ),
    ]);
    expect((created['results'] as List).single['status'], 'accepted');
    final row = database.select(
      'SELECT * FROM pumps WHERE station_id=1 AND name=?',
      ['Pump A'],
    ).single;
    expect(row['active'], 1);
    expect(database.select(
      "SELECT local_id FROM sync_entity_links WHERE station_id=1 AND entity_type='pumps' AND global_id=?",
      [globalId],
    ), hasLength(1));

    final updated = await postEvents(stationOneToken, [
      masterEvent(
        eventId: '13111111-1111-4111-8111-111111111111',
        operation: 'update',
        baseVersion: 1,
        payload: {'name': 'Pump A Updated'},
      ),
    ]);
    expect((updated['results'] as List).single['status'], 'accepted');
    expect(database.select('SELECT name FROM pumps WHERE id=?', [row['id']]).single['name'],
        'Pump A Updated');

    final deleted = await postEvents(stationOneToken, [
      masterEvent(
        eventId: '14111111-1111-4111-8111-111111111111',
        operation: 'delete',
        baseVersion: 2,
        payload: const {},
      ),
    ]);
    expect((deleted['results'] as List).single['status'], 'accepted');
    expect(database.select('SELECT active FROM pumps WHERE id=?', [row['id']]).single['active'], 0);

    final replay = await postEvents(stationOneToken, [
      masterEvent(
        eventId: '14111111-1111-4111-8111-111111111111',
        operation: 'delete',
        baseVersion: 2,
        payload: const {},
      ),
    ]);
    expect((replay['results'] as List).single['status'], 'duplicate');

    final crossStation = await postEvents(stationTwoToken, [
      masterEvent(
        eventId: '15111111-1111-4111-8111-111111111111',
        operation: 'create',
        baseVersion: 0,
        payload: {'name': 'Foreign Pump', 'system_type': 'diesel'},
      ),
    ]);
    expect((crossStation['results'] as List).single['status'], 'rejected');
    expect(database.select("SELECT * FROM pumps WHERE name='Foreign Pump'"), isEmpty);
  });

  test('cashbox master sync cannot initialize or overwrite financial balances', () async {
    database.execute('''CREATE TABLE cashboxes(
      id INTEGER PRIMARY KEY AUTOINCREMENT, station_id INTEGER NOT NULL,
      name TEXT NOT NULL, opening_balance INTEGER NOT NULL DEFAULT 0,
      current_balance INTEGER NOT NULL DEFAULT 0, currency TEXT NOT NULL DEFAULT 'YER',
      active INTEGER NOT NULL DEFAULT 1, ledger_account_code TEXT
    )''');
    const globalId = 'acacacac-acac-4cac-8cac-acacacacacac';
    final response = await postEvents(stationOneToken, [{
      'event_id': '16111111-1111-4111-8111-111111111111',
      'entity_type': 'cashboxes',
      'entity_key': 'cashboxes:$globalId',
      'operation': 'create',
      'base_version': 0,
      'payload': {
        '_global_id': globalId,
        'name': 'Cashbox Injected',
        'currency': 'YER',
        'opening_balance': 900000,
        'current_balance': 900000,
      },
    }]);
    expect((response['results'] as List).single['status'], 'rejected');
    expect(database.select("SELECT * FROM cashboxes WHERE name='Cashbox Injected'"), isEmpty);
  });


  test('irrigation sync recalculates charges and posts diesel effects atomically', () async {
    database.execute("INSERT INTO beneficiaries(id,station_id,name,status) VALUES(1,1,'Irrigation Beneficiary','active')");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(1,'beneficiaries','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',1,'2026-11-08T00:00:00Z')");
    database.execute("CREATE TABLE pumps(id INTEGER PRIMARY KEY,station_id INTEGER NOT NULL,name TEXT NOT NULL,system_type TEXT NOT NULL,active INTEGER NOT NULL DEFAULT 1)");
    database.execute("INSERT INTO pumps(id,station_id,name,system_type,active) VALUES(1,1,'Pump A','diesel',1)");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(1,'pumps','cccccccc-cccc-4ccc-8ccc-cccccccccccc',1,'2026-11-08T00:00:00Z')");
    database.execute("CREATE TABLE workers(id INTEGER PRIMARY KEY,station_id INTEGER NOT NULL,name TEXT NOT NULL,pay_type TEXT NOT NULL,fixed_salary INTEGER NOT NULL DEFAULT 0,hourly_rate INTEGER NOT NULL DEFAULT 0,percentage_rate REAL NOT NULL DEFAULT 0,active INTEGER NOT NULL DEFAULT 1)");
    database.execute("CREATE TABLE partners(id INTEGER PRIMARY KEY,station_id INTEGER NOT NULL,name TEXT NOT NULL,ownership_mode TEXT NOT NULL,shares_count REAL NOT NULL DEFAULT 0,ownership_percentage REAL NOT NULL DEFAULT 0,active INTEGER NOT NULL DEFAULT 1)");
    database.execute("INSERT INTO workers(id,station_id,name,pay_type,hourly_rate,active) VALUES(1,1,'Hourly Worker','hourly',100,1)");
    database.execute("INSERT INTO partners(id,station_id,name,ownership_mode,shares_count,active) VALUES(1,1,'Share Partner','shares',1,1)");
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(1,'workers','abababab-1111-4111-8111-111111111111',1,'2026-11-08T00:00:00Z'),(1,'partners','bcbcbcbc-2222-4222-8222-222222222222',1,'2026-11-08T00:00:00Z')");
    database.execute("CREATE TABLE worker_transactions(id INTEGER PRIMARY KEY AUTOINCREMENT,station_id INTEGER NOT NULL,worker_id INTEGER NOT NULL,date TEXT NOT NULL,type TEXT NOT NULL,hours REAL NOT NULL DEFAULT 0,rate_snapshot REAL NOT NULL DEFAULT 0,percentage_snapshot REAL NOT NULL DEFAULT 0,amount INTEGER NOT NULL,reference_type TEXT,reference_id INTEGER,notes TEXT,created_by INTEGER)");
    database.execute("CREATE TABLE partner_transactions(id INTEGER PRIMARY KEY AUTOINCREMENT,station_id INTEGER NOT NULL,partner_id INTEGER NOT NULL,date TEXT NOT NULL,type TEXT NOT NULL,amount INTEGER NOT NULL,ownership_snapshot REAL,reference_type TEXT,reference_id INTEGER,notes TEXT,created_by INTEGER)");
    database.execute("CREATE TABLE irrigations(id INTEGER PRIMARY KEY AUTOINCREMENT,station_id INTEGER NOT NULL,pump_id INTEGER NOT NULL,beneficiary_id INTEGER,worker_id INTEGER,partner_id INTEGER,party_type TEXT NOT NULL,date TEXT NOT NULL,start_datetime TEXT NOT NULL,end_datetime TEXT NOT NULL,minutes INTEGER NOT NULL,system_type TEXT NOT NULL,water_hourly_rate_snapshot INTEGER NOT NULL DEFAULT 0,diesel_liters_per_hour_snapshot REAL NOT NULL DEFAULT 0,diesel_price_snapshot INTEGER NOT NULL DEFAULT 0,solar_hourly_rate_snapshot INTEGER NOT NULL DEFAULT 0,third_type_hourly_rate_snapshot INTEGER NOT NULL DEFAULT 0,cloud_minutes INTEGER NOT NULL DEFAULT 0,chargeable_minutes INTEGER NOT NULL,water_amount INTEGER NOT NULL DEFAULT 0,diesel_amount INTEGER NOT NULL DEFAULT 0,total_amount INTEGER NOT NULL DEFAULT 0,paid_amount INTEGER NOT NULL DEFAULT 0,status TEXT NOT NULL,created_by INTEGER,created_at TEXT NOT NULL,updated_at TEXT NOT NULL)");
    database.execute("CREATE TABLE irrigation_sessions(id INTEGER PRIMARY KEY AUTOINCREMENT,beneficiary_id INTEGER NOT NULL,queue_entry_id INTEGER,booking_id INTEGER,pump_id INTEGER NOT NULL,planned_start TEXT,actual_start TEXT,actual_end TEXT,status TEXT NOT NULL,timer_started_at TEXT,timer_stopped_at TEXT,diesel_before REAL DEFAULT 0,diesel_consumed REAL DEFAULT 0,diesel_after REAL DEFAULT 0,diesel_warning_shown INTEGER NOT NULL DEFAULT 0,postponement_reason TEXT,notes TEXT)");
    database.execute("ALTER TABLE irrigations ADD COLUMN session_id INTEGER");
    database.execute("ALTER TABLE irrigations ADD COLUMN queue_entry_id INTEGER");
    database.execute("ALTER TABLE irrigations ADD COLUMN booking_id INTEGER");
    const sessionGlobalId = 'eeeeeeee-1111-4111-8111-111111111111';

    database.execute("CREATE TABLE station_settings(station_id INTEGER NOT NULL,key TEXT NOT NULL,value TEXT NOT NULL,PRIMARY KEY(station_id,key))");
    database.execute("INSERT INTO station_settings(station_id,key,value) VALUES(1,'diesel_hourly_water_rate','6000'),(1,'diesel_liters_per_hour','2'),(1,'diesel_price_per_liter','500')");
    database.execute("CREATE TABLE accounts(id INTEGER PRIMARY KEY,parent_id INTEGER,code TEXT UNIQUE NOT NULL,name TEXT NOT NULL,type TEXT NOT NULL)");
    database.execute("INSERT INTO accounts(id,code,name,type) VALUES(1,'1200','Receivables','asset'),(2,'4000','Water Revenue','income'),(3,'4010','Diesel Revenue','income'),(4,'1000','Cash','asset'),(5,'5000','Worker Expense','expense'),(6,'2100','Worker Payables','liability'),(7,'2200','Partner Payables','liability'),(8,'3200','Partner Equity','equity')");
    database.execute("CREATE TABLE journal_entries(id INTEGER PRIMARY KEY AUTOINCREMENT,station_id INTEGER NOT NULL,date TEXT NOT NULL,reference_type TEXT,reference_id INTEGER,description TEXT NOT NULL,status TEXT NOT NULL,created_by INTEGER,created_at TEXT NOT NULL)");
    database.execute("CREATE TABLE journal_lines(id INTEGER PRIMARY KEY AUTOINCREMENT,journal_entry_id INTEGER NOT NULL,account_id INTEGER NOT NULL,beneficiary_id INTEGER,worker_id INTEGER,partner_id INTEGER,debit INTEGER NOT NULL DEFAULT 0,credit INTEGER NOT NULL DEFAULT 0,memo TEXT)");
    database.execute("CREATE TABLE cloud_periods(id INTEGER PRIMARY KEY AUTOINCREMENT,irrigation_id INTEGER NOT NULL,start_datetime TEXT NOT NULL,end_datetime TEXT NOT NULL,minutes INTEGER NOT NULL,created_at TEXT NOT NULL)");
    database.execute("CREATE TABLE diesel_movements(id INTEGER PRIMARY KEY AUTOINCREMENT,station_id INTEGER,beneficiary_id INTEGER,irrigation_id INTEGER,cashbox_id INTEGER,kind TEXT NOT NULL,liters REAL NOT NULL,unit_price INTEGER NOT NULL DEFAULT 0,amount INTEGER NOT NULL DEFAULT 0,date TEXT NOT NULL,notes TEXT,created_by INTEGER)");
    const globalId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    final payload = {
      '_global_id': globalId,
      'session_id':1,
      '_global_refs': {
        'pump_id': {'table':'pumps','global_id':'cccccccc-cccc-4ccc-8ccc-cccccccccccc'},
        'beneficiary_id': {'table':'beneficiaries','global_id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'},
        'session_id': {'table':'irrigation_sessions','global_id':sessionGlobalId},
      },
      'start_datetime':'2026-11-08T08:00:00.000',
      'end_datetime':'2026-11-08T09:00:00.000',
      'system_type':'diesel',
      'cloud_minutes':10,
      'cloud_periods':[{'start_datetime':'2026-11-08T08:20:00.000','end_datetime':'2026-11-08T08:30:00.000'}],
      'paid_amount':0,
      '_derived_global_ids': {
        'cloud_periods': ['ababcdcd-abab-4bab-8bab-ababcdcdabab'],
        'worker_transactions': ['acacacac-acac-4cac-8cac-acacacacacab'],
        'partner_transactions': ['adadadad-adad-4dad-8dad-adadadadadad'],
        'diesel_movements': [
          'aeaeaeae-aeae-4eae-8eae-aeaeaeaeaeae',
          'afafafaf-afaf-4faf-8faf-afafafafafaf',
        ],
        'journal_entries': [
          'babababa-baba-4bba-8bba-babababababa',
          'bcbcbcbc-bcbc-4cbc-8cbc-bcbcbcbcbcbc',
          'cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd',
        ],
        'journal_lines': [
          '11111111-aaaa-4aaa-8aaa-111111111111',
          '22222222-aaaa-4aaa-8aaa-222222222222',
          '33333333-aaaa-4aaa-8aaa-333333333333',
          '44444444-aaaa-4aaa-8aaa-444444444444',
          '55555555-aaaa-4aaa-8aaa-555555555555',
          '66666666-aaaa-4aaa-8aaa-666666666666',
          '77777777-aaaa-4aaa-8aaa-777777777777',
        ],
        'irrigation_sessions': [sessionGlobalId],
        'queue_entries': [],
        'booking_requests': [],
      },
    };
    final event = {
      'event_id':'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      'entity_type':'irrigations',
      'entity_key':'irrigations:$globalId',
      'operation':'create',
      'base_version':0,
      'payload':payload,
    };
    final sessionCreate = await postEvents(stationOneToken,[{
      'event_id':'eeeeeeee-2222-4222-8222-222222222222',
      'entity_type':'irrigation_sessions',
      'entity_key':'irrigation_sessions:' + sessionGlobalId,
      'operation':'create',
      'base_version':0,
      'payload':{
        '_global_id':sessionGlobalId,
        'beneficiary_id':1,
        'pump_id':1,
        'status':'running',
        'actual_start':'2026-11-08T08:00:00.000',
        'timer_started_at':'2026-11-08T08:00:00.000',
        '_global_refs':{
          'beneficiary_id':{'table':'beneficiaries','global_id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'},
          'pump_id':{'table':'pumps','global_id':'cccccccc-cccc-4ccc-8ccc-cccccccccccc'},
        },
      },
    }]);
    expect((sessionCreate['results'] as List).single['status'],'accepted');
    final sessionReplay = await postEvents(stationOneToken,[{
      'event_id':'eeeeeeee-2222-4222-8222-222222222222',
      'entity_type':'irrigation_sessions',
      'entity_key':'irrigation_sessions:' + sessionGlobalId,
      'operation':'create',
      'base_version':0,
      'payload':{
        '_global_id':sessionGlobalId,
        'beneficiary_id':1,
        'pump_id':1,
        'status':'running',
        'actual_start':'2026-11-08T08:00:00.000',
        'timer_started_at':'2026-11-08T08:00:00.000',
        '_global_refs':{
          'beneficiary_id':{'table':'beneficiaries','global_id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'},
          'pump_id':{'table':'pumps','global_id':'cccccccc-cccc-4ccc-8ccc-cccccccccccc'},
        },
      },
    }]);
    expect((sessionReplay['results'] as List).single['status'],'duplicate');
    final response = await postEvents(stationOneToken,[event]);
    final irrigationResult = (response['results'] as List).single;
    expect(irrigationResult['status'],'accepted', reason: irrigationResult.toString());
    final irrigation = database.select('SELECT * FROM irrigations WHERE station_id=1').single;
    expect(irrigation['minutes'],60);
    expect(irrigation['cloud_minutes'],10);
    expect(irrigation['chargeable_minutes'],60); // Diesel billing is not reduced by cloud periods.
    expect(irrigation['water_amount'],6000);
    expect(irrigation['diesel_amount'],1000);
    expect(irrigation['total_amount'],7000);
    expect(irrigation['session_id'],1);
    expect(database.select('SELECT status,actual_end,diesel_consumed FROM irrigation_sessions WHERE id=1').single['status'],'completed');
    expect((database.select("SELECT COUNT(*) n FROM sync_entity_links WHERE entity_type='irrigation_sessions' AND global_id=?",[sessionGlobalId]).single['n'] as num).toInt(),1);
    final sessionFinish = await postEvents(stationOneToken,[{
      'event_id':'eeeeeeee-3333-4333-8333-333333333333',
      'entity_type':'irrigation_sessions',
      'entity_key':'irrigation_sessions:' + sessionGlobalId,
      'operation':'update',
      'base_version':1,
      'payload':{
        '_global_id':sessionGlobalId,
        'beneficiary_id':1,
        'pump_id':1,
        'status':'completed',
        'actual_start':'2026-11-08T08:00:00.000',
        'actual_end':'2026-11-08T09:00:00.000',
        'timer_started_at':'2026-11-08T08:00:00.000',
        'timer_stopped_at':'2026-11-08T09:00:00.000',
        '_global_refs':{
          'beneficiary_id':{'table':'beneficiaries','global_id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'},
          'pump_id':{'table':'pumps','global_id':'cccccccc-cccc-4ccc-8ccc-cccccccccccc'},
        },
      },
    }]);
    expect((sessionFinish['results'] as List).single['status'],'accepted');
    expect(database.select('SELECT * FROM cloud_periods WHERE irrigation_id=?',[irrigation['id']]),hasLength(1));
    expect(database.select('SELECT kind FROM diesel_movements WHERE station_id=1 ORDER BY id').map((r)=>r['kind']).toList(),['advance','consumption']);
    expect(database.select('SELECT COUNT(*) n FROM journal_entries').single['n'],3);
    expect(database.select("SELECT amount FROM worker_transactions WHERE reference_type='irrigation' AND reference_id=?",[irrigation['id']]).single['amount'],100);
    expect(database.select("SELECT amount FROM partner_transactions WHERE reference_type='irrigation_profit' AND reference_id=?",[irrigation['id']]).single['amount'],6900);
    final ledgerTotals = database.select('SELECT SUM(debit) debit,SUM(credit) credit FROM journal_lines').single;
    expect(ledgerTotals['debit'], ledgerTotals['credit']);

    final originInbox = await getInbox(stationOneToken, device: 'device-a');
    final originTypes = (originInbox['events'] as List)
        .map((item) => (item as Map)['entity_type'])
        .toList();
    expect(originTypes, [
      'cloud_periods', 'worker_transactions', 'partner_transactions',
      'diesel_movements', 'diesel_movements',
      'journal_entries', 'journal_entries', 'journal_entries',
      'journal_lines', 'journal_lines', 'journal_lines', 'journal_lines',
      'journal_lines', 'journal_lines', 'journal_lines', 'irrigation_sessions',
    ]);
    expect(
      (originInbox['events'] as List).every(
        (item) => (item as Map)['source_device'] == '__server_projection__',
      ),
      isTrue,
    );

    final peerInbox = await getInbox(stationOneToken, device: 'device-b');
    final peerTypes = (peerInbox['events'] as List)
        .map((item) => (item as Map)['entity_type'])
        .toList();
    expect(peerTypes.indexOf('irrigations'), greaterThanOrEqualTo(0));
    expect(peerTypes.indexOf('cloud_periods'), greaterThan(peerTypes.indexOf('irrigations')));
    expect(peerTypes.indexOf('worker_transactions'), greaterThan(peerTypes.indexOf('irrigations')));
    expect(peerTypes.indexOf('partner_transactions'), greaterThan(peerTypes.indexOf('worker_transactions')));
    expect(peerTypes.indexOf('diesel_movements'), greaterThan(peerTypes.indexOf('irrigations')));
    expect(peerTypes.indexOf('journal_entries'), greaterThan(peerTypes.indexOf('diesel_movements')));
    expect(peerTypes.indexOf('journal_lines'), greaterThan(peerTypes.indexOf('journal_entries')));
    expect(peerTypes.where((type) => type == 'worker_transactions'), hasLength(1));
    expect(peerTypes.where((type) => type == 'partner_transactions'), hasLength(1));
    expect(peerTypes.where((type) => type == 'journal_entries'), hasLength(3));
    expect(peerTypes.where((type) => type == 'journal_lines'), hasLength(7));
    expect(peerTypes.lastIndexOf('irrigation_sessions'), greaterThan(peerTypes.indexOf('irrigations')));
    final projectionLogCount = database.select('SELECT COUNT(*) n FROM sync_event_log').single['n'];

    const cloudGlobalId = 'ababcdcd-abab-4bab-8bab-ababcdcdabab';
    final cloudEvent = {
      'event_id':'abab1111-abab-4111-8111-abab1111abab',
      'entity_type':'cloud_periods',
      'entity_key':'cloud_periods:$cloudGlobalId',
      'operation':'create',
      'base_version':0,
      'payload':{
        '_global_id':cloudGlobalId,
        '_global_refs':{'irrigation_id':{'table':'irrigations','global_id':globalId}},
        'start_datetime':'2026-11-08T08:20:00.000',
        'end_datetime':'2026-11-08T08:30:00.000',
        'minutes':10,
      },
    };
    final cloudResponse = await postEvents(stationOneToken,[cloudEvent]);
    expect((cloudResponse['results'] as List).single['status'],'accepted');
    expect(database.select('SELECT COUNT(*) n FROM cloud_periods WHERE irrigation_id=?',[irrigation['id']]).single['n'],1);
    final cloudReplay = await postEvents(stationOneToken,[cloudEvent]);
    expect((cloudReplay['results'] as List).single['status'],'accepted');
    expect(database.select('SELECT COUNT(*) n FROM sync_event_log').single['n'],projectionLogCount);
    final replay = await postEvents(stationOneToken,[event]);
    expect((replay['results'] as List).single['status'],'duplicate');
    expect(database.select('SELECT COUNT(*) n FROM sync_event_log').single['n'],projectionLogCount);
    final foreign = await postEvents(stationTwoToken,[{...event,'event_id':'ffffffff-ffff-4fff-8fff-ffffffffffff'}]);
    expect((foreign['results'] as List).single['status'],'rejected');
    const secondSessionGlobalId = '11111111-2222-4222-8222-222222222222';
    final secondSession = await postEvents(stationOneToken,[{
      'event_id':'11111111-3333-4333-8333-333333333333',
      'entity_type':'irrigation_sessions',
      'entity_key':'irrigation_sessions:' + secondSessionGlobalId,
      'operation':'create',
      'base_version':0,
      'payload':{
        '_global_id':secondSessionGlobalId,
        'beneficiary_id':1,
        'pump_id':1,
        'status':'running',
        'actual_start':'2026-11-08T10:00:00.000',
        'timer_started_at':'2026-11-08T10:00:00.000',
        '_global_refs':{
          'beneficiary_id':{'table':'beneficiaries','global_id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'},
          'pump_id':{'table':'pumps','global_id':'cccccccc-cccc-4ccc-8ccc-cccccccccccc'},
        },
      },
    }]);
    expect((secondSession['results'] as List).single['status'],'accepted');
    database.execute("DELETE FROM accounts WHERE code='4010'");
    const failedIrrigationGlobalId = '22222222-3333-4333-8333-333333333333';
    final failedIrrigation = await postEvents(stationOneToken,[{
      'event_id':'22222222-4444-4444-8444-444444444444',
      'entity_type':'irrigations',
      'entity_key':'irrigations:' + failedIrrigationGlobalId,
      'operation':'create',
      'base_version':0,
      'payload':{
        '_global_id':failedIrrigationGlobalId,
        'session_id':2,
        '_global_refs':{
          'pump_id':{'table':'pumps','global_id':'cccccccc-cccc-4ccc-8ccc-cccccccccccc'},
          'beneficiary_id':{'table':'beneficiaries','global_id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'},
          'session_id':{'table':'irrigation_sessions','global_id':secondSessionGlobalId},
        },
        'start_datetime':'2026-11-08T10:00:00.000',
        'end_datetime':'2026-11-08T11:00:00.000',
        'system_type':'diesel',
        'cloud_minutes':0,
        'cloud_periods':[],
        'paid_amount':0,
      },
    }]);
    expect((failedIrrigation['results'] as List).single['status'],'rejected');
    expect(database.select('SELECT COUNT(*) n FROM irrigations').single['n'],1);
    expect(database.select('SELECT status FROM irrigation_sessions WHERE id=2').single['status'],'running');
    expect(database.select('SELECT COUNT(*) n FROM journal_entries').single['n'],2);
    expect(database.select('SELECT COUNT(*) n FROM diesel_movements').single['n'],2);
    expect(database.select('SELECT COUNT(*) n FROM irrigations').single['n'],1);
  });

  test('sync applies independent diesel opening stock once with balanced journal', () async {
    prepareDieselFixture();
    const globalId = 'abababab-abab-4bab-8bab-abababababab';
    final event = {
      'event_id':'abababab-abab-4bab-8bab-abababababac',
      'entity_type':'diesel_movements', 'entity_key':'diesel_movements:' + globalId,
      'operation':'create', 'base_version':0,
      'payload':{
        '_global_id':globalId, '_global_refs':{},
        'kind':'opening_balance', 'liters':20.0, 'unit_price':100,
        'amount':2000, 'date':'2026-11-08T08:00:00.000', 'notes':'opening stock',
      },
    };
    final first = await postEvents(stationOneToken,[event]);
    expect((first['results'] as List).single['status'],'accepted');
    expect(database.select('SELECT SUM(liters) AS stock FROM diesel_movements WHERE station_id=1').single['stock'],20);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_entries').single['n'],1);
    expect(database.select('SELECT SUM(debit) AS debit,SUM(credit) AS credit FROM journal_lines').single['debit'],2000);
    expect(database.select('SELECT SUM(debit) AS debit,SUM(credit) AS credit FROM journal_lines').single['credit'],2000);
    final replay = await postEvents(stationOneToken,[event]);
    expect((replay['results'] as List).single['status'],'duplicate');
    expect(database.select('SELECT COUNT(*) AS n FROM diesel_movements').single['n'],1);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_entries').single['n'],1);
  });

  test('sync debits purchase cashbox and journals diesel receipt exactly once', () async {
    prepareDieselFixture();
    const cashboxGlobalId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeef';
    database.execute("INSERT INTO sync_entity_links(station_id,entity_type,global_id,local_id,created_at) VALUES(1,'cashboxes',?,1,'2026-11-08T00:00:00Z')",[cashboxGlobalId]);
    const globalId = 'abababab-abab-4bab-8bab-abababababac';
    final result = await postEvents(stationOneToken,[{
      'event_id':'abababab-abab-4bab-8bab-abababababad',
      'entity_type':'diesel_movements', 'entity_key':'diesel_movements:' + globalId,
      'operation':'create', 'base_version':0,
      'payload':{
        '_global_id':globalId, 'kind':'receipt', 'liters':10.0, 'unit_price':100,
        'amount':1000, 'cashbox_id':1, 'date':'2026-11-08T09:00:00.000',
        '_global_refs':{'cashbox_id':{'table':'cashboxes','global_id':cashboxGlobalId,'name':'Main','currency':'YER'}},
      },
    }]);
    expect((result['results'] as List).single['status'],'accepted');
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],4000);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_entries WHERE reference_type=\'diesel_receipt\'').single['n'],1);
    expect(database.select('SELECT SUM(debit) AS d,SUM(credit) AS c FROM journal_lines').single['d'],1000);
    expect(database.select('SELECT SUM(debit) AS d,SUM(credit) AS c FROM journal_lines').single['c'],1000);
  });

  test('sync rejects diesel movement references from another station', () async {
    prepareDieselFixture();
    const globalId = 'abababab-abab-4bab-8bab-abababababab';
    final result = await postEvents(stationOneToken,[{
      'event_id':'abababab-abab-4bab-8bab-abababababac',
      'entity_type':'diesel_movements', 'entity_key':'diesel_movements:' + globalId,
      'operation':'create', 'base_version':0,
      'payload':{
        '_global_id':globalId, 'kind':'receipt', 'liters':10.0, 'unit_price':100,
        'amount':1000, 'cashbox_id':2, 'date':'2026-11-08T09:00:00.000',
        '_global_refs':{'cashbox_id':{'table':'cashboxes','global_id':'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'}},
      },
    }]);
    expect((result['results'] as List).single['status'],'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM diesel_movements').single['n'],0);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=2').single['current_balance'],5000);
  });

  test('sync posts expense, reduces its cashbox, and creates one balanced journal', () async {
    prepareExpenseAndTransferFixture();
    const globalId = '55555555-5555-4555-8555-555555555555';
    final event = {
      'event_id':'55555555-5555-4555-8555-555555555556',
      'entity_type':'expenses', 'entity_key':'expenses:' + globalId,
      'operation':'create', 'base_version':0,
      'payload':{
        '_global_id':globalId, 'category':'fuel', 'title':'Diesel generator fuel',
        'amount':750, 'date':'2026-11-08T10:00:00.000', 'status':'posted', 'notes':'test expense',
        'payment_method_id':1, 'cashbox_id':1,
        '_global_refs':{
          'payment_method_id':{'table':'payment_methods','global_id':'11111111-1111-4111-8111-111111111111'},
          'cashbox_id':{'table':'cashboxes','global_id':'22222222-2222-4222-8222-222222222222','name':'Cash','currency':'YER'},
        },
      },
    };
    final first = await postEvents(stationOneToken,[event]);
    expect((first['results'] as List).single['status'],'accepted');
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],4250);
    expect(database.select('SELECT COUNT(*) AS n FROM expenses WHERE station_id=1').single['n'],1);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_entries WHERE reference_type=\'expense\'').single['n'],1);
    expect(database.select('SELECT SUM(debit) AS d,SUM(credit) AS c FROM journal_lines').single['d'],750);
    expect(database.select('SELECT SUM(debit) AS d,SUM(credit) AS c FROM journal_lines').single['c'],750);
    final replay = await postEvents(stationOneToken,[event]);
    expect((replay['results'] as List).single['status'],'duplicate');
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],4250);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_entries').single['n'],1);
  });

  test('sync transfers cash between two cashboxes and supports opening transfer', () async {
    prepareExpenseAndTransferFixture();
    const transferId = '66666666-6666-4666-8666-666666666666';
    final normal = {
      'event_id':'66666666-6666-4666-8666-666666666667',
      'entity_type':'cashbox_transfers', 'entity_key':'cashbox_transfers:' + transferId,
      'operation':'create', 'base_version':0,
      'payload':{
        '_global_id':transferId, 'from_cashbox_id':1, 'to_cashbox_id':2,
        'amount':1200, 'date':'2026-11-08T11:00:00.000', 'is_opening_transfer':false, 'reference':'bank deposit',
        '_global_refs':{
          'from_cashbox_id':{'table':'cashboxes','global_id':'22222222-2222-4222-8222-222222222222','name':'Cash','currency':'YER'},
          'to_cashbox_id':{'table':'cashboxes','global_id':'33333333-3333-4333-8333-333333333333','name':'Bank','currency':'YER'},
        },
      },
    };
    final first = await postEvents(stationOneToken,[normal]);
    expect((first['results'] as List).single['status'],'accepted');
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],3800);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=2').single['current_balance'],3200);
    expect(database.select('SELECT SUM(debit) AS d,SUM(credit) AS c FROM journal_lines').single['d'],1200);
    expect(database.select('SELECT SUM(debit) AS d,SUM(credit) AS c FROM journal_lines').single['c'],1200);
    final replay = await postEvents(stationOneToken,[normal]);
    expect((replay['results'] as List).single['status'],'duplicate');
    expect(database.select('SELECT COUNT(*) AS n FROM cashbox_transfers').single['n'],1);
    const openingId = '77777777-7777-4777-8777-777777777777';
    final opening = await postEvents(stationOneToken,[{
      'event_id':'77777777-7777-4777-8777-777777777778',
      'entity_type':'cashbox_transfers', 'entity_key':'cashbox_transfers:' + openingId,
      'operation':'create', 'base_version':0,
      'payload':{
        '_global_id':openingId, 'from_cashbox_id':null, 'to_cashbox_id':2,
        'amount':500, 'date':'2026-11-08T12:00:00.000', 'is_opening_transfer':true,
        '_global_refs':{'to_cashbox_id':{'table':'cashboxes','global_id':'33333333-3333-4333-8333-333333333333','name':'Bank','currency':'YER'}},
      },
    }]);
    expect((opening['results'] as List).single['status'],'accepted');
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=2').single['current_balance'],3700);
    expect(database.select('SELECT SUM(debit) AS d,SUM(credit) AS c FROM journal_lines').single['d'],1700);
    expect(database.select('SELECT SUM(debit) AS d,SUM(credit) AS c FROM journal_lines').single['c'],1700);
    expect(database.select('SELECT COUNT(*) AS n FROM journal_entries').single['n'],2);
  });

  test('sync rejects expenses and transfers referencing another station', () async {
    prepareExpenseAndTransferFixture();
    const globalId = '88888888-8888-4888-8888-888888888888';
    final expense = await postEvents(stationOneToken,[{
      'event_id':'88888888-8888-4888-8888-888888888889',
      'entity_type':'expenses', 'entity_key':'expenses:' + globalId, 'operation':'create', 'base_version':0,
      'payload':{'_global_id':globalId,'category':'fuel','title':'Fuel','amount':100,'date':'2026-11-08T10:00:00.000','payment_method_id':1,'cashbox_id':3,
        '_global_refs':{'payment_method_id':{'table':'payment_methods','global_id':'11111111-1111-4111-8111-111111111111'},'cashbox_id':{'table':'cashboxes','global_id':'44444444-4444-4444-8444-444444444444'}}},
    }]);
    expect((expense['results'] as List).single['status'],'rejected');
    expect(database.select('SELECT COUNT(*) AS n FROM expenses').single['n'],0);
    const transferGlobal = '99999999-9999-4999-8999-999999999999';
    final transfer = await postEvents(stationOneToken,[{
      'event_id':'99999999-9999-4999-8999-999999999998',
      'entity_type':'cashbox_transfers','entity_key':'cashbox_transfers:' + transferGlobal,'operation':'create','base_version':0,
      'payload':{'_global_id':transferGlobal,'from_cashbox_id':1,'to_cashbox_id':3,'amount':100,'date':'2026-11-08T10:00:00.000','is_opening_transfer':false,
        '_global_refs':{'from_cashbox_id':{'table':'cashboxes','global_id':'22222222-2222-4222-8222-222222222222'},'to_cashbox_id':{'table':'cashboxes','global_id':'44444444-4444-4444-8444-444444444444'}}},
    }]);
    expect((transfer['results'] as List).single['status'],'rejected');
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],5000);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=3').single['current_balance'],7000);
    expect(database.select('SELECT COUNT(*) AS n FROM cashbox_transfers').single['n'],0);
  });


  test('sync cancellation refunds expense cashbox and posts one balanced reversal', () async {
    prepareExpenseAndTransferFixture();
    const globalId = 'aaaaaaaa-1111-4111-8111-111111111111';
    final created = await postEvents(stationOneToken,[{
      'event_id':'aaaaaaaa-1111-4111-8111-111111111112',
      'entity_type':'expenses','entity_key':'expenses:$globalId','operation':'create','base_version':0,
      'payload':{
        '_global_id':globalId,'category':'fuel','title':'Fuel','amount':750,
        'date':'2026-11-08T10:00:00.000','status':'posted','payment_method_id':1,'cashbox_id':1,
        '_global_refs':{
          'payment_method_id':{'table':'payment_methods','global_id':'11111111-1111-4111-8111-111111111111'},
          'cashbox_id':{'table':'cashboxes','global_id':'22222222-2222-4222-8222-222222222222'},
        },
      },
    }]);
    expect((created['results'] as List).single['status'],'accepted');
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],4250);
    final cancelled = await postEvents(stationOneToken,[{
      'event_id':'aaaaaaaa-1111-4111-8111-111111111113',
      'entity_type':'expenses','entity_key':'expenses:$globalId','operation':'update','base_version':1,
      'payload':{
        '_global_id':globalId,'status':'cancelled','cancelled_at':'2026-11-08T12:00:00.000',
        'cancel_reason':'إدخال بالخطأ',
      },
    }]);
    expect((cancelled['results'] as List).single['status'],'accepted');
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],5000);
    expect(database.select('SELECT status FROM expenses').single['status'],'cancelled');
    expect(database.select("SELECT COUNT(*) n FROM journal_entries WHERE reference_type='reversal'").single['n'],1);
    final totals=database.select('SELECT SUM(debit) d,SUM(credit) c FROM journal_lines').single;
    expect(totals['d'],1500);
    expect(totals['c'],1500);
    final repeated=await postEvents(stationOneToken,[{
      'event_id':'aaaaaaaa-1111-4111-8111-111111111114',
      'entity_type':'expenses','entity_key':'expenses:$globalId','operation':'update','base_version':2,
      'payload':{
        '_global_id':globalId,'status':'cancelled','cancelled_at':'2026-11-08T12:01:00.000',
        'cancel_reason':'إلغاء مكرر',
      },
    }]);
    expect((repeated['results'] as List).single['status'],'rejected');
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],5000);
    expect(database.select("SELECT COUNT(*) n FROM journal_entries WHERE reference_type='reversal'").single['n'],1);
  });

  test('sync cancellation reverses normal and opening cashbox transfers exactly once', () async {
    prepareExpenseAndTransferFixture();
    const globalId = 'bbbbbbbb-2222-4222-8222-222222222222';
    final created = await postEvents(stationOneToken,[{
      'event_id':'bbbbbbbb-2222-4222-8222-222222222223',
      'entity_type':'cashbox_transfers','entity_key':'cashbox_transfers:$globalId',
      'operation':'create','base_version':0,
      'payload':{
        '_global_id':globalId,'from_cashbox_id':1,'to_cashbox_id':2,'amount':1200,
        'date':'2026-11-08T11:00:00.000','is_opening_transfer':false,
        '_global_refs':{
          'from_cashbox_id':{'table':'cashboxes','global_id':'22222222-2222-4222-8222-222222222222'},
          'to_cashbox_id':{'table':'cashboxes','global_id':'33333333-3333-4333-8333-333333333333'},
        },
      },
    }]);
    expect((created['results'] as List).single['status'],'accepted');
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],3800);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=2').single['current_balance'],3200);
    final cancelled = await postEvents(stationOneToken,[{
      'event_id':'bbbbbbbb-2222-4222-8222-222222222224',
      'entity_type':'cashbox_transfers','entity_key':'cashbox_transfers:$globalId',
      'operation':'update','base_version':1,
      'payload':{
        '_global_id':globalId,'status':'cancelled','cancelled_at':'2026-11-08T13:00:00.000',
        'cancel_reason':'تحويل غير مقصود',
      },
    }]);
    expect((cancelled['results'] as List).single['status'],'accepted');
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],5000);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=2').single['current_balance'],2000);
    expect(database.select('SELECT status FROM cashbox_transfers').single['status'],'cancelled');
    expect(database.select("SELECT COUNT(*) n FROM journal_entries WHERE reference_type='reversal'").single['n'],1);
    final totals=database.select('SELECT SUM(debit) d,SUM(credit) c FROM journal_lines').single;
    expect(totals['d'],2400);
    expect(totals['c'],2400);
    final repeated=await postEvents(stationOneToken,[{
      'event_id':'bbbbbbbb-2222-4222-8222-222222222225',
      'entity_type':'cashbox_transfers','entity_key':'cashbox_transfers:$globalId',
      'operation':'update','base_version':2,
      'payload':{
        '_global_id':globalId,'status':'cancelled','cancelled_at':'2026-11-08T13:01:00.000',
        'cancel_reason':'إلغاء مكرر',
      },
    }]);
    expect((repeated['results'] as List).single['status'],'rejected');
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=1').single['current_balance'],5000);
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=2').single['current_balance'],2000);
    expect(database.select("SELECT COUNT(*) n FROM journal_entries WHERE reference_type='reversal'").single['n'],1);
  });


  test('sync cancellation reverses an opening cashbox transfer against opening equity', () async {
    prepareExpenseAndTransferFixture();
    const globalId = 'cccccccc-3333-4333-8333-333333333333';
    final created = await postEvents(stationOneToken,[{
      'event_id':'cccccccc-3333-4333-8333-333333333334',
      'entity_type':'cashbox_transfers','entity_key':'cashbox_transfers:$globalId',
      'operation':'create','base_version':0,
      'payload':{
        '_global_id':globalId,'from_cashbox_id':null,'to_cashbox_id':2,'amount':500,
        'date':'2026-11-08T11:00:00.000','is_opening_transfer':true,
        '_global_refs':{
          'to_cashbox_id':{'table':'cashboxes','global_id':'33333333-3333-4333-8333-333333333333'},
        },
      },
    }]);
    expect((created['results'] as List).single['status'],'accepted');
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=2').single['current_balance'],2500);
    final cancelled = await postEvents(stationOneToken,[{
      'event_id':'cccccccc-3333-4333-8333-333333333335',
      'entity_type':'cashbox_transfers','entity_key':'cashbox_transfers:$globalId',
      'operation':'update','base_version':1,
      'payload':{
        '_global_id':globalId,'status':'cancelled','cancelled_at':'2026-11-08T13:00:00.000',
        'cancel_reason':'تصحيح الرصيد الافتتاحي',
      },
    }]);
    expect((cancelled['results'] as List).single['status'],'accepted');
    expect(database.select('SELECT current_balance FROM cashboxes WHERE id=2').single['current_balance'],2000);
    final lines=database.select('SELECT jl.debit,jl.credit,a.code FROM journal_lines jl JOIN accounts a ON a.id=jl.account_id ORDER BY jl.id');
    expect(lines.where((line)=>line['code']=='3000').length,2);
    final totals=database.select('SELECT SUM(debit) d,SUM(credit) c FROM journal_lines').single;
    expect(totals['d'],1000);
    expect(totals['c'],1000);
  });

}
