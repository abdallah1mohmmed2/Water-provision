import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late StationRepository repository;

  Future<int> seedBeneficiary(String suffix, {bool credentialActive = true}) async {
    final now = DateTime.now().toIso8601String();
    final id = await db.insert('beneficiaries', {
      'station_id': 1,
      'name': 'مستفيد اختبار $suffix',
      'status': 'active',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('beneficiary_credentials', {
      'station_id': 1,
      'beneficiary_id': id,
      'username_normalized': 'portal_$suffix',
      'password_phc': 'test-hash-not-used-by-these-tests',
      'active': credentialActive ? 1 : 0,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final path = '${await databaseFactory.getDatabasesPath()}/saqia_station_v2.db';
    await databaseFactory.deleteDatabase(path);
    db = AppDatabase.instance;
    await db.db;
    repository = StationRepository(db);
  });

  test('beneficiary booking list and cancellation are owner-scoped', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch.toString();
    final owner = await seedBeneficiary('owner_$suffix');
    final other = await seedBeneficiary('other_$suffix');
    final bookingId = await repository.createBeneficiaryBooking(owner, 'موعد مناسب صباحًا');

    expect((await repository.beneficiaryBookings(owner)).length, 1);
    expect(await repository.beneficiaryBookings(other), isEmpty);
    await expectLater(
      repository.cancelBeneficiaryBooking(bookingId, other),
      throwsA(isA<StateError>()),
    );
    final before = await db.query(
      'SELECT status FROM booking_requests WHERE id=?',
      args: [bookingId],
    );
    expect(before.single['status'], 'new');

    await repository.cancelBeneficiaryBooking(bookingId, owner);
    final after = await db.query(
      'SELECT status,cancel_reason FROM booking_requests WHERE id=?',
      args: [bookingId],
    );
    expect(after.single['status'], 'cancelled');
    expect(after.single['cancel_reason'], 'إلغاء بطلب المستفيد');
  });

  test('disabled beneficiary credentials cannot create a booking', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch.toString();
    final disabled = await seedBeneficiary('disabled_$suffix', credentialActive: false);
    await expectLater(
      repository.createBeneficiaryBooking(disabled, 'طلب اختبار'),
      throwsA(isA<StateError>()),
    );
    expect(await repository.beneficiaryBookings(disabled), isEmpty);
  });

  test('beneficiary cannot mark another beneficiary notification as read', () async {
    final suffix = DateTime.now().microsecondsSinceEpoch.toString();
    final owner = await seedBeneficiary('notify_owner_$suffix');
    final other = await seedBeneficiary('notify_other_$suffix');
    final notificationId = await db.insert('notifications', {
      'beneficiary_id': owner,
      'type': 'test',
      'title': 'إشعار اختبار',
      'body': 'محتوى اختبار',
      'created_at': DateTime.now().toIso8601String(),
    });

    await expectLater(
      repository.markBeneficiaryNotificationRead(notificationId, other),
      throwsA(isA<StateError>()),
    );
    var rows = await db.query(
      'SELECT read_at FROM notifications WHERE id=?',
      args: [notificationId],
    );
    expect(rows.single['read_at'], isNull);

    await repository.markBeneficiaryNotificationRead(notificationId, owner);
    rows = await db.query(
      'SELECT read_at FROM notifications WHERE id=?',
      args: [notificationId],
    );
    expect(rows.single['read_at'], isNotNull);
  });
}
