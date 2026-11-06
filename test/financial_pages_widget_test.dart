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

  // لا نستخدم pumpAndSettle أثناء التحميل؛ مؤشر التحميل المتحرك
  // يبقي إطاراً مجدولاً باستمرار. نمنح SQLite FFI وقت I/O حقيقياً عبر
  // runAsync، ثم نضخ إطاراً بمدة محددة لتقديم ساعة fake-async في الاختبار.
  Future<void> pumpUntilReady(WidgetTester tester) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        await tester.pump(const Duration(milliseconds: 300));
        return;
      }
    }
    throw TestFailure('انتهت مهلة انتظار تحميل الصفحة (10 ثوانٍ).');
  }

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    // شاشة الاختبار الافتراضية قصيرة؛ نستخدم مساحة طولية كافية حتى لا
    // ينتهي تمرير زر أسفل الصفحة بمحاذاته خلف AppBar.
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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

  testWidgets(
    'الحسابات العامة: إنشاء حساب وقبض وصرف وتحديث الرصيد',
    (tester) async {
      // نقاط تشخيص مؤقتة لتحديد أول await يتوقف في CI. لا تغيّر سلوك التطبيق.
      print('[GENERAL-ACCOUNT-DIAG] 01 before initial page');
      await pumpPage(
        tester,
        GeneralAccountsPage(repository, userId: 1),
      );
      print('[GENERAL-ACCOUNT-DIAG] 02 initial page ready');
      expect(find.text('لا توجد حسابات عامة. أضف حسابًا للبدء.'), findsOneWidget);

      print('[GENERAL-ACCOUNT-DIAG] 03 before open create account');
      await tester.tap(find.text('حساب جديد'));
      print('[GENERAL-ACCOUNT-DIAG] 04 create account tapped');
      await pumpUntilReady(tester);
      print('[GENERAL-ACCOUNT-DIAG] 05 create form ready');

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'حساب اختبار الواجهة');
      print('[GENERAL-ACCOUNT-DIAG] 06 account name entered');
      await tester.enterText(fields.at(1), '777123456');
      print('[GENERAL-ACCOUNT-DIAG] 07 phone entered');
      await tester.enterText(fields.at(3), '1000');
      print('[GENERAL-ACCOUNT-DIAG] 08 opening balance entered');
      await tester.tap(find.text('حفظ').last);
      print('[GENERAL-ACCOUNT-DIAG] 09 save account tapped');
      await pumpUntilReady(tester);
      print('[GENERAL-ACCOUNT-DIAG] 10 account save flow ready');

      print('[GENERAL-ACCOUNT-DIAG] 11 before account database query');
      final accounts = await database.query(
        'general_accounts',
        where: 'name=?',
        whereArgs: const ['حساب اختبار الواجهة'],
      );
      print('[GENERAL-ACCOUNT-DIAG] 12 account database query completed');
      expect(accounts, hasLength(1));
      expect(accounts.single['opening_balance'], 1000);
      expect(find.text('حساب اختبار الواجهة'), findsOneWidget);

      await tester.tap(find.byType(ExpansionTile).first);
      print('[GENERAL-ACCOUNT-DIAG] 13 account expanded');
      await pumpUntilReady(tester);
      print('[GENERAL-ACCOUNT-DIAG] 14 account details ready');
      await tester.tap(find.text('قبض من الحساب'));
      print('[GENERAL-ACCOUNT-DIAG] 15 receipt action tapped');
      await pumpUntilReady(tester);
      print('[GENERAL-ACCOUNT-DIAG] 16 receipt form ready');
      var dialogFields = find.byType(TextFormField);
      await tester.enterText(dialogFields.at(0), '250');
      await tester.enterText(dialogFields.at(1), 'REC-01');
      await tester.enterText(dialogFields.at(2), 'قبض تجريبي');
      print('[GENERAL-ACCOUNT-DIAG] 17 receipt fields entered');
      await tester.tap(find.text('حفظ الحركة'));
      print('[GENERAL-ACCOUNT-DIAG] 18 receipt save tapped');
      await pumpUntilReady(tester);
      print('[GENERAL-ACCOUNT-DIAG] 19 receipt save flow ready');

      await tester.tap(find.text('صرف للحساب'));
      print('[GENERAL-ACCOUNT-DIAG] 20 payment action tapped');
      await pumpUntilReady(tester);
      print('[GENERAL-ACCOUNT-DIAG] 21 payment form ready');
      dialogFields = find.byType(TextFormField);
      await tester.enterText(dialogFields.at(0), '100');
      await tester.enterText(dialogFields.at(1), 'PAY-01');
      await tester.enterText(dialogFields.at(2), 'صرف تجريبي');
      print('[GENERAL-ACCOUNT-DIAG] 22 payment fields entered');
      await tester.tap(find.text('حفظ الحركة'));
      print('[GENERAL-ACCOUNT-DIAG] 23 payment save tapped');
      await pumpUntilReady(tester);
      print('[GENERAL-ACCOUNT-DIAG] 24 payment save flow ready');

      print('[GENERAL-ACCOUNT-DIAG] 25 before transactions database query');
      final transactions = await database.query(
        'general_account_transactions',
        orderBy: 'id ASC',
      );
      print('[GENERAL-ACCOUNT-DIAG] 26 transactions database query completed');
      expect(transactions, hasLength(2));
      expect(transactions[0]['type'], 'receipt');
      expect(transactions[1]['type'], 'payment');
      expect(find.textContaining('لنا عليه: 850 ريال'), findsOneWidget);
      expect(find.textContaining('قبض تجريبي'), findsOneWidget);
      expect(find.textContaining('صرف تجريبي'), findsOneWidget);
      print('[GENERAL-ACCOUNT-DIAG] 27 test assertions completed');
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );;

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
    await tester.ensureVisible(saveButton);
    await tester.pump(const Duration(milliseconds: 300));
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
    await tester.ensureVisible(saveButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(saveButton);
    await pumpUntilReady(tester);
    final validationMessage = find.text('أدخل مبالغ صحيحة من دون قيم سالبة.');
    await tester.ensureVisible(validationMessage);
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
