import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';
import 'package:saqia_station/features/general_accounts_page.dart';
import 'package:saqia_station/features/reconciliation_page.dart';
import 'package:saqia_station/domain/accounting/reconciliation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late StationRepository repository;
  late Directory testDatabaseDirectory;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    testDatabaseDirectory = await Directory.systemTemp.createTemp(
      'saqia_financial_widget_test_',
    );
    await databaseFactory.setDatabasesPath(testDatabaseDirectory.path);
    // افتح اتصال FFI مرة واحدة خارج fake-async الخاص باختبارات الواجهات.
    // إبقاء الاتصال مفتوحاً يمنع إعادة فتح SQLite بعد كل اختبار داخل fake-async.
    database = AppDatabase.instance;
    await database.db;
    repository = StationRepository(database);
  });

  tearDownAll(() async {
    await database.close();
    await testDatabaseDirectory.delete(recursive: true);
  });

  Future<void> resetDatabase(WidgetTester tester) async {
    await tester.runAsync(() async {
      await database.delete('general_account_transactions', '1=1', const []);
      await database.delete('general_accounts', '1=1', const []);
      await database.delete('accountant_reconciliation_months', '1=1', const []);
    });
  }

  Future<T> runDatabase<T>(
    WidgetTester tester,
    Future<T> Function() action,
  ) async {
    final result = await tester.runAsync(action);
    if (result == null) {
      throw TestFailure('تعذر إكمال عملية SQLite في اختبار الواجهة.');
    }
    return result;
  }

  Future<void> runDatabaseVoid(
    WidgetTester tester,
    Future<void> Function() action,
  ) async {
    // Future<void> تُرجع null بطبيعتها؛ لا يجوز تفسير ذلك على أنه فشل.
    await tester.runAsync(action);
  }

  Future<void> pumpUntilReady(WidgetTester tester) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      // SQLite FFI يعتمد على I/O حقيقي؛ runAsync يسمح باكتمال Future
      // خارج fake-async zone الخاصة بـ WidgetTester، ثم نحدّث إطار الواجهة.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        await tester.pump(const Duration(milliseconds: 300));
        return;
      }
    }
    throw TestFailure('انتهت مهلة انتظار تحميل الصفحة (10 ثوانٍ).');
  }

  Future<void> settleAfterDialogSave(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    await pumpUntilReady(tester);
  }

  // لا نستخدم pumpAndSettle أثناء تحميل الصفحات؛ مؤشر التحميل المتحرك
  // يبقي إطاراً مجدولاً باستمرار حتى اكتمال استعلام SQLite غير المتزامن.
  // ننتظر خارج fake-async حتى تنتهي عمليات FFI الفعلية ثم نحدّث الواجهة.
  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(MaterialApp(home: page));
    await pumpUntilReady(tester);
  }

  test('رصيد الحساب العام يخصم القبض ويضيف الصرف', () {
    expect(
      calculateGeneralAccountBalance(1000, [
        {'type': 'receipt', 'amount': 250},
        {'type': 'payment', 'amount': 100},
        {'type': 'unknown', 'amount': 900},
      ]),
      850,
    );
    expect(calculateGeneralAccountBalance(0, const []), 0);
  });

  testWidgets('الحسابات العامة: إنشاء حساب وقبض وصرف وتحديث الرصيد', (tester) async {
    await resetDatabase(tester);
    await pumpPage(
      tester,
      GeneralAccountsPage(repository, userId: 1),
    );
    expect(find.text('لا توجد حسابات عامة. أضف حسابًا للبدء.'), findsOneWidget);

    await tester.tap(find.text('حساب جديد'));
    await pumpUntilReady(tester);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'حساب اختبار الواجهة');
    await tester.enterText(fields.at(1), '777123456');
    await tester.enterText(fields.at(3), '1000');
    await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
    await settleAfterDialogSave(tester);

    final accounts = await runDatabase(tester, () => database.query(
      'general_accounts',
      where: 'name=?',
      whereArgs: const ['حساب اختبار الواجهة'],
    ));
    expect(accounts, hasLength(1));
    expect(accounts.single['opening_balance'], 1000);
    expect(find.text('حساب اختبار الواجهة'), findsOneWidget);

    await tester.tap(find.byType(ExpansionTile).first);
    await pumpUntilReady(tester);
    await tester.tap(find.text('قبض من الحساب'));
    await pumpUntilReady(tester);
    var dialogFields = find.byType(TextFormField);
    await tester.enterText(dialogFields.at(0), '250');
    await tester.enterText(dialogFields.at(1), 'REC-01');
    await tester.enterText(dialogFields.at(2), 'قبض تجريبي');
    await tester.tap(find.widgetWithText(FilledButton, 'حفظ الحركة'));
    await settleAfterDialogSave(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'صرف للحساب'));
    await pumpUntilReady(tester);
    dialogFields = find.byType(TextFormField);
    await tester.enterText(dialogFields.at(0), '100');
    await tester.enterText(dialogFields.at(1), 'PAY-01');
    await tester.enterText(dialogFields.at(2), 'صرف تجريبي');
    await tester.tap(find.widgetWithText(FilledButton, 'حفظ الحركة'));
    await settleAfterDialogSave(tester);

    final transactions = await runDatabase(tester, () => database.query(
      'general_account_transactions',
      orderBy: 'id ASC',
    ));
    expect(transactions, hasLength(2));
    expect(transactions[0]['type'], 'receipt');
    expect(transactions[1]['type'], 'payment');
    expect(find.textContaining('لنا عليه: 850 ريال'), findsOneWidget);
    expect(find.textContaining('قبض تجريبي'), findsOneWidget);
    expect(find.textContaining('صرف تجريبي'), findsOneWidget);
  });

  testWidgets('شاشة التسوية تعرض الملخص والتاريخ وتحفظ تسوية الشهر', (tester) async {
    await resetDatabase(tester);
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month, 1);
    final previousMonth = DateTime(now.year, now.month - 1, 1);
    final service = ReconciliationService(database);
    await runDatabaseVoid(tester, () => service.saveMonth(
      month: previousMonth,
      openingBalance: 2000,
      manualPaid: 500,
      openingDetails: 'رصيد الشهر السابق',
      userId: 1,
    ));

    await pumpPage(
      tester,
      ReconciliationPage(repository, userId: 1),
    );

    expect(find.text('أولاً: حساب الشركاء'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('ثانياً: حساب المستفيدين (الرعية)'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('ثانياً: حساب المستفيدين (الرعية)'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('ثالثاً: حساب العمال'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('ثالثاً: حساب العمال'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('رابعاً: المصروفات'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('رابعاً: المصروفات'), findsOneWidget);
    expect(find.text('التسويات المحفوظة للأشهر السابقة'), findsOneWidget);
    expect(find.textContaining('رصيد الشهر السابق'), findsOneWidget);

    // يوجد شهر سابق محفوظ؛ الرصيد الافتتاحي يُرحّل تلقائيًا ولا يظهر كحقل قابل للتحرير.
    expect(find.text('قيمة الرصيد الافتتاحي'), findsNothing);
    final manualField = find.widgetWithText(TextField, 'المبلغ المسلّم خلال هذا الشهر');
    await tester.enterText(manualField, '300');
    final saveButton = find.widgetWithText(FilledButton, 'حفظ تسوية الشهر');
    await tester.scrollUntilVisible(saveButton, 240, scrollable: find.byType(Scrollable).first);
    await tester.tap(saveButton);
    await settleAfterDialogSave(tester);

    final currentRows = await runDatabase(tester, () => database.query(
      'accountant_reconciliation_months',
      where: 'month_key=?',
      whereArgs: [service.monthKey(currentMonth)],
    ));
    expect(currentRows, hasLength(1));
    expect(currentRows.single['manual_paid'], 300);
    expect(find.text('تم حفظ تسوية الشهر في دفتر التسويات المستقل.'), findsOneWidget);
  });

  testWidgets('شاشة التسوية ترفض المبلغ اليدوي السالب وتدعم التنقل بين الشهور', (tester) async {
    await resetDatabase(tester);
    await pumpPage(
      tester,
      ReconciliationPage(repository, userId: 1),
    );
    final now = DateTime.now();
    final currentLabel = '${now.year}/${now.month.toString().padLeft(2, '0')}';
    expect(find.text(currentLabel), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await pumpUntilReady(tester);
    final previous = DateTime(now.year, now.month - 1, 1);
    expect(
      find.text('${previous.year}/${previous.month.toString().padLeft(2, '0')}'),
      findsOneWidget,
    );

    final manualField = find.widgetWithText(TextField, 'المبلغ المسلّم خلال هذا الشهر');
    await tester.enterText(manualField, '-10');
    final saveButton = find.widgetWithText(FilledButton, 'حفظ تسوية الشهر');
    await tester.ensureVisible(saveButton);
    await tester.pump();
    expect(tester.getCenter(saveButton).dy, lessThan(600));
    await tester.tap(saveButton);
    await tester.pump();
    expect(find.text('أدخل مبالغ صحيحة من دون قيم سالبة.'), findsOneWidget);
    expect(
      await runDatabase(tester, () => database.query(
        'accountant_reconciliation_months',
        where: 'month_key=?',
        whereArgs: [ReconciliationService(database).monthKey(previous)],
      )),
      isEmpty,
    );
  });
}
