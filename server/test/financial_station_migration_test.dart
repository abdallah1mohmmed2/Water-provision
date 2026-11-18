import 'package:saqia_server/server.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('financial station migration backfills only fully matching trusted references', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);

    db.execute('CREATE TABLE stations(id INTEGER PRIMARY KEY)');
    db.execute('CREATE TABLE cashboxes(id INTEGER PRIMARY KEY, station_id INTEGER)');
    db.execute('CREATE TABLE payment_methods(id INTEGER PRIMARY KEY, station_id INTEGER)');
    db.execute('CREATE TABLE beneficiaries(id INTEGER PRIMARY KEY, station_id INTEGER)');
    db.execute('CREATE TABLE workers(id INTEGER PRIMARY KEY, station_id INTEGER)');
    db.execute('CREATE TABLE partners(id INTEGER PRIMARY KEY, station_id INTEGER)');
    db.execute('CREATE TABLE irrigations(id INTEGER PRIMARY KEY, station_id INTEGER)');
    db.execute('CREATE TABLE payments(id INTEGER PRIMARY KEY, beneficiary_id INTEGER, worker_id INTEGER, partner_id INTEGER, cashbox_id INTEGER, payment_method_id INTEGER, amount INTEGER, date TEXT)');
    db.execute('CREATE TABLE expenses(id INTEGER PRIMARY KEY, beneficiary_id INTEGER, worker_id INTEGER, partner_id INTEGER, cashbox_id INTEGER, payment_method_id INTEGER, amount INTEGER, date TEXT)');
    db.execute('CREATE TABLE diesel_movements(id INTEGER PRIMARY KEY, beneficiary_id INTEGER, irrigation_id INTEGER, cashbox_id INTEGER, liters REAL, date TEXT)');
    db.execute('CREATE TABLE cashbox_transfers(id INTEGER PRIMARY KEY, from_cashbox_id INTEGER, to_cashbox_id INTEGER, amount INTEGER, date TEXT)');
    db.execute('CREATE TABLE worker_transactions(id INTEGER PRIMARY KEY, worker_id INTEGER, cashbox_id INTEGER, amount INTEGER, date TEXT)');
    db.execute('CREATE TABLE partner_transactions(id INTEGER PRIMARY KEY, partner_id INTEGER, amount INTEGER, date TEXT)');

    db.execute('INSERT INTO stations(id) VALUES(7),(8)');
    db.execute('INSERT INTO cashboxes(id,station_id) VALUES(70,7),(80,8)');
    db.execute('INSERT INTO payment_methods(id,station_id) VALUES(71,7),(81,8)');
    db.execute('INSERT INTO beneficiaries(id,station_id) VALUES(10,7),(20,8)');
    db.execute('INSERT INTO workers(id,station_id) VALUES(30,7),(40,8)');
    db.execute('INSERT INTO partners(id,station_id) VALUES(50,7),(60,8)');
    db.execute('INSERT INTO irrigations(id,station_id) VALUES(90,7),(91,8)');

    db.execute("""
      INSERT INTO payments(id,beneficiary_id,cashbox_id,payment_method_id,amount,date)
      VALUES(1,10,70,71,100,'2026-11-01'),(2,10,80,81,200,'2026-11-02')
    """);
    db.execute("""
      INSERT INTO expenses(id,beneficiary_id,cashbox_id,payment_method_id,amount,date)
      VALUES(1,10,70,71,50,'2026-11-01'),(2,10,80,71,60,'2026-11-02'),(3,10,NULL,71,70,'2026-11-03')
    """);
    db.execute("""
      INSERT INTO diesel_movements(id,beneficiary_id,irrigation_id,cashbox_id,liters,date)
      VALUES(1,10,90,NULL,5,'2026-11-01'),(2,10,91,NULL,6,'2026-11-02'),(3,NULL,NULL,NULL,7,'2026-11-03')
    """);
    db.execute("""
      INSERT INTO cashbox_transfers(id,from_cashbox_id,to_cashbox_id,amount,date)
      VALUES(1,70,70,10,'2026-11-01'),(2,70,80,20,'2026-11-02')
    """);
    db.execute("""
      INSERT INTO worker_transactions(id,worker_id,cashbox_id,amount,date)
      VALUES(1,30,70,10,'2026-11-01'),(2,30,80,20,'2026-11-02')
    """);
    db.execute("INSERT INTO partner_transactions(id,partner_id,amount,date) VALUES(1,50,10,'2026-11-01')");

    SaqiaServer(db, jwtSecret: 'migration-test-secret-with-at-least-32-bytes');

    expect(db.select('SELECT station_id FROM payments WHERE id=1').first['station_id'], 7);
    expect(db.select('SELECT station_id FROM payments WHERE id=2').first['station_id'], isNull);
    expect(db.select('SELECT station_id FROM expenses WHERE id=1').first['station_id'], 7);
    expect(db.select('SELECT station_id FROM expenses WHERE id=2').first['station_id'], isNull);
    expect(db.select('SELECT station_id FROM expenses WHERE id=3').first['station_id'], isNull);
    expect(db.select('SELECT station_id FROM diesel_movements WHERE id=1').first['station_id'], 7);
    expect(db.select('SELECT station_id FROM diesel_movements WHERE id=2').first['station_id'], isNull);
    expect(db.select('SELECT station_id FROM diesel_movements WHERE id=3').first['station_id'], isNull);
    expect(db.select('SELECT station_id FROM cashbox_transfers WHERE id=1').first['station_id'], 7);
    expect(db.select('SELECT station_id FROM cashbox_transfers WHERE id=2').first['station_id'], isNull);
    expect(db.select('SELECT station_id FROM worker_transactions WHERE id=1').first['station_id'], 7);
    expect(db.select('SELECT station_id FROM worker_transactions WHERE id=2').first['station_id'], isNull);
    expect(db.select('SELECT station_id FROM partner_transactions WHERE id=1').first['station_id'], 7);
  });
}
