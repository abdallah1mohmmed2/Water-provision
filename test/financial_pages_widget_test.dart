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
    // لكل ملف اختبار مجلد SQLite مستقل؛ يمنع تداخل عمليات الاختبارات
    // المتوازية التي تستخدم الاسم نفسه لقاعدة البيانات في مسار FFI الافتراضي.
    testDatabaseDirectory = await Directory.systemTemp.createTemp(
      'saqia_financial_widget_test_',
    );
    // لا نستخدم المسار الافتراضي المشترك ولا نحذف قاعدة ملفات اختبارات أخرى.
    await databaseFactory.setDatabasesPath(testDatabaseDirectory.path);
  });

  tearDownAll(() async {
    await testDatabaseDirectory.delete(recursive: true);
  });

  setUp(() async {
    // كل اختبار يحصل على اتصال جديد من الـ singleton نفسه بعد إغلاق اتصال
    // الاختبار السابق؛ لا نشارك اتصال SQLite FFI بين اختبارات الواجهة.
    database = AppDatabase.instance;
    await database.db;
    repository = StationRepository(database);
    await database.delete('general_account_transactions', '1=1', const []);
    await database.delete('general_accounts', '1=1', const []);
    await database.delete('accountant_reconciliation_months', '1=1', const []);
  });

  tearDown(() async {
    // إغلاق الاتصال وإعادة ضبط AppDatabase._db يمنع تسرب حالة/اتصال اختبار
    // إلى الاختبار التالي، خصوصاً إذا انتهى اختبار واجهة بمهلة.
    await database.close();
  });

  // لا نستخدم pumpAndSettle أثناء تحميل الصفحات؛ مؤشر التحميل المتحرك
  // يبقي إطاراً مجدولاً باستمرار حتى اكتمال استعلام SQLite غير المتزامن.
  // ننتظر اختفاء مؤشر التحميل بمهلة محددة ثم نمنح انتقالات الواجهة وقتها.
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
    await tester.tap(find.text('حفظ').last);
    await pumpUntilReady(tester);

    final accounts = await database.query(
      'general_accounts',
      where: 'name=?',
      whereArgs: const ['حساب اختبار الواجهة'],
    );
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
    await tester.tap(find.text('حفظ الحركة'));
    await pumpUntilReady(tester);

    await tester.tap(find.text('صرف للحساب'));
    await pumpUntilReady(tester);
    dialogFields = find.byType(TextFormField);
    await tester.enterText(dialogFields.at(0), '100');
    await tester.enterText(dialogFields.at(1), 'PAY-01');
    await tester.enterText(dialogFields.at(2), 'صرف تجريبي');
    await tester.tap(find.text('حفظ الحركة'));
    await pumpUntilReady(tester);

    final transactions = await database.query(
      'general_account_transactions',
      orderBy: 'id ASC',
    );
    expect(transactions, hasLength(2));
    expect(transactions[0]['type'], 'receipt');
    expect(transactions[1]['type'], 'payment');
    expect(find.textContaining('لنا عليه: 850 ريال'), findsOneWidget);
    expect(find.textContaining('قبض تجريبي'), findsOneWidget);
    expect(find.textContaining('صرف تجريبي'), findsOneWidget);
  });

  testWidgets('شاشة التسوية تعرض الملخص والتاريخ وتحفظ تسوية الشهر', (tester) async {
    final now = DateTime.now();
    final currentMonth = DateTime(now.year, now.month, 1);
    final previousMonth = DateTime(now.year, now.month - 1, 1);
    final service = ReconciliationService(database);
    await service.saveMonth(
      month: previousMonth,
      openingBalance: 2000,
      manualPaid: 500,
      openingDetails: 'رصيد الشهر السابق',
      userId: 1,
    );

    await pumpPage(
      tester,
      ReconciliationPage(repository, userId: 1),
    );

    expect(find.text('أولاً: حساب الشركاء'), findsOneWidget);
    expect(find.text('ثانياً: حساب المستفيدين (الرعية)'), findsOneWidget);
    expect(find.text('ثالثاً: حساب العمال'), findsOneWidget);
    expect(find.text('رابعاً: المصروفات'), findsOneWidget);
    expect(find.text('التسويات المحفوظة للأشهر السابقة'), findsOneWidget);
    expect(find.textContaining('رصيد الشهر السابق'), findsOneWidget);

    // يوجد شهر سابق محفوظ؛ الرصيد الافتتاحي يُرحّل تلقائيًا ولا يظهر كحقل قابل للتحرير.
    expect(find.text('قيمة الرصيد الافتتاحي'), findsNothing);
    final manualField = find.widgetWithText(TextField, 'المبلغ المسلّم خلال هذا الشهر');
    await tester.enterText(manualField, '300');
    final saveButton = find.text('حفظ تسوية الشهر');
    await tester.scrollUntilVisible(
      saveButton,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await pumpUntilReady(tester);

    final currentRows = await database.query(
      'accountant_reconciliation_months',
      where: 'month_key=?',
      whereArgs: [service.monthKey(currentMonth)],
    );
    expect(currentRows, hasLength(1));
    expect(currentRows.single['manual_paid'], 300);
    expect(find.text('تم حفظ تسوية الشهر في دفتر التسويات المستقل.'), findsOneWidget);
  });

  testWidgets('شاشة التسوية ترفض المبلغ اليدوي السالب وتدعم التنقل بين الشهور', (tester) async {
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
    final saveButton = find.text('حفظ تسوية الشهر');
    await tester.scrollUntilVisible(
      saveButton,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await pumpUntilReady(tester);
    final validationMessage = find.text('أدخل مبالغ صحيحة من دون قيم سالبة.');
    await tester.scrollUntilVisible(
      validationMessage,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(validationMessage, findsOneWidget);
    expect(
      await database.query(
        'accountant_reconciliation_months',
        where: 'month_key=?',
        whereArgs: [ReconciliationService(database).monthKey(previous)],
      ),
      isEmpty,
    );
  });
}
