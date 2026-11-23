import 'dart:io';
import 'package:intl/date_symbol_data_local.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';
import 'package:saqia_station/features/app.dart';
import 'package:saqia_station/features/party_quick_actions.dart';
import 'package:saqia_station/services/manual_message_service.dart';
import 'package:saqia_station/services/report_pdf_preview_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(ManualMessageService.smsComposerChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('SMS URI preserves spaces, Arabic, literal plus, ampersand and newlines', () {
    const text = 'سقاية أحمد + سالم & علي\n5.75 لتر 03:30 م';
    final uri = ManualMessageService.smsUri('771234567', text);
    expect(uri.query, contains('%20'));
    expect(uri.query, contains('%2B'));
    expect(uri.query, isNot(contains('+')));
    expect(uri.queryParameters['body'], text);
  });

  test('native SMS composer receives normalized recipient and exact message once', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(ManualMessageService.smsComposerChannel, (call) async {
      calls.add(call);
      return true;
    });
    const text = 'السلام عليكم\nالمستهلك 4.65 لتر + المتبقي 5.75';
    expect(await ManualMessageService.openNativeSms('٠٧٧١٢٣٤٥٦٧', text), isTrue);
    expect(calls.single.method, 'composeSms');
    expect(calls.single.arguments, {'phone': '967771234567', 'message': text});
  });

  for (final missing in [false, true]) {
    test('native composer failure allows URI fallback (missing=$missing)', () async {
      messenger.setMockMethodCallHandler(ManualMessageService.smsComposerChannel, (call) async {
        if (missing) throw MissingPluginException();
        throw PlatformException(code: 'UNAVAILABLE');
      });
      expect(await ManualMessageService.openNativeSms('771234567', 'نص'), isFalse);
    });
  }

  for (final phone in ['', '771234567']) {
    testWidgets('copy fallback is explicit, including absent phone ($phone)', (tester) async {
      final copied = <String>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () => ManualMessageService.offerChoices(context,
          title: 'رسالة', recipientName: 'سالم', phone: phone, message: 'ديزل 4.65\nرصيد له 5.75'),
        child: const Text('فتح'),
      )))));
      await tester.tap(find.text('فتح'));
      await tester.pumpAndSettle();
      expect(copied, isEmpty);
      await tester.tap(find.text('نسخ نص الرسالة'));
      await tester.pumpAndSettle();
      expect(copied, ['ديزل 4.65\nرصيد له 5.75']);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('لاحقًا'));
      await tester.pumpAndSettle();
    });
  }

  for (final share in [false, true]) {
    for (final report in const ['irrigations', 'statement', 'diesel']) {
      testWidgets('PDF choice report=$report share=$share uses same callback', (tester) async {
        final calls = <(String, bool)>[];
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
          onPressed: () => showPartyPdfChoices(context, name: 'الشخص المحدد', generate: (water) async {
            calls.add((water, ReportPdfPreviewService.sharingFromLongPress));
          }),
          child: const Text('PDF'),
        )))));
        await tester.tap(find.text('PDF'));
        await tester.pumpAndSettle();
        expect(find.text('سقايات هذا الشخص'), findsOneWidget);
        expect(find.text('كشف حساب هذا الشخص'), findsOneWidget);
        expect(find.text('المسلّم والمستهلك والمتبقي من الديزل'), findsOneWidget);
        expect(calls, isEmpty);
        final button = find.text(switch (report) {
          'irrigations' => 'سقايات هذا الشخص',
          'diesel' => 'المسلّم والمستهلك والمتبقي من الديزل',
          _ => 'كشف حساب هذا الشخص',
        });
        if (share) {
          await tester.longPress(button);
        } else {
          await tester.tap(button);
        }
        await tester.pumpAndSettle();
        expect(calls, [(report, share)]);
        expect(find.text('الشخص المحدد'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('party action buttons wrap at 320 pixels and new irrigation invokes once', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var opens = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PartyQuickActions(
      repository: StationRepository(), partyType: 'partner', partyId: 7, name: 'سالم',
      onNewIrrigation: () { opens++; },
    ))));
    await tester.tap(find.text('سقاية جديدة'));
    expect(opens, 1);
    expect(find.text('PDF'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('party card navigation uses existing irrigation form without writing', () {
    final app = AppDatabase.instance;
    late Directory folder;
    late StationRepository repo;
    late Map<String, int> targets;
    setUpAll(() async {
      await initializeDateFormatting('ar');
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      folder = await Directory.systemTemp.createTemp('party-shortcuts-');
      await databaseFactory.setDatabasesPath(folder.path);
    });
    setUp(() async {
      await app.close();
      await databaseFactory.deleteDatabase('${folder.path}/saqia_station_v2.db');
      await app.db;
      repo = StationRepository(app);
      targets = {};
      for (final name in ['أول شخص', 'الشخص المستهدف']) {
        targets['beneficiary'] = await app.insert('beneficiaries', {
          'station_id': 1, 'name': name, 'created_at': '2026-01-01', 'updated_at': '2026-01-01',
        });
        targets['worker'] = await repo.createWorker(name: name, payType: 'fixed');
        targets['partner'] = await repo.createPartner(name: name, mode: 'shares', shares: 1);
      }
    });
    tearDownAll(() async {
      await app.close();
      await folder.delete(recursive: true);
    });

    Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
      for (var n = 0; n < 160 && !ready(); n++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(ready(), isTrue);
    }
    Future<List<Map<String, Object?>>> counts() => app.query('''
      SELECT (SELECT COUNT(*) FROM irrigations) AS irrigations,
             (SELECT COUNT(*) FROM journal_entries) AS journals,
             (SELECT COUNT(*) FROM sync_queue) AS outbox
    ''');

    for (final system in ['diesel', 'solar', 'third']) {
      for (final kind in ['beneficiary', 'worker', 'partner']) {
        testWidgets('$system $kind shortcut selects exact second party without accounting writes', (tester) async {
          tester.view.physicalSize = const Size(1200, 2000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.runAsync(() => repo.setSetting('system_type', system));
          final before = await tester.runAsync(counts);
          final page = switch (kind) {
            'worker' => WorkersPage(repo, userId: 1, manager: true),
            'partner' => PartnersPage(repo, userId: 1, manager: true),
            _ => BeneficiariesPage(repo, userId: 1, manager: true),
          };
          await tester.pumpWidget(MaterialApp(home: Scaffold(body: page)));
          final action = find.byWidgetPredicate((w) => w is PartyQuickActions && w.partyId == targets[kind] && w.partyType == kind);
          await waitFor(tester, () => action.evaluate().isNotEmpty);
          final button = find.descendant(of: action, matching: find.text('سقاية جديدة'));
          final name = find.text('الشخص المستهدف');
          expect(tester.getTopLeft(button).dy, lessThan(tester.getTopLeft(name).dy));
          await tester.ensureVisible(button);
          await tester.tap(button);
          await tester.pump();
          await waitFor(tester, () {
            final forms = find.byType(NewIrrigationPage);
            if (forms.evaluate().isEmpty) return false;
            final dynamic state = tester.state(forms);
            return state.partyType == kind && switch (kind) {
              'worker' => state.workerId == targets[kind],
              'partner' => state.partnerId == targets[kind],
              _ => state.bid == targets[kind],
            };
          });
          final form = tester.widget<NewIrrigationPage>(find.byType(NewIrrigationPage));
          expect(form.initialPartyType, kind);
          expect(form.initialPartyId, targets[kind]);
          expect(form.compactOnly, isTrue);
          {
            await waitFor(tester, () => find.text('بطاقة وقت التشغيل').evaluate().isNotEmpty);
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(find.text('حفظ سقاية'), findsOneWidget);
            expect(find.text('حفظ سقاية جديدة'), findsNothing);
            await tester.tap(find.text('إغلاق'));
            await waitFor(tester, () => find.byType(NewIrrigationPage).evaluate().isEmpty &&
                find.byType(CircularProgressIndicator).evaluate().isEmpty);
            await tester.pumpAndSettle();
            expect(find.byType(NewIrrigationPage), findsNothing);
          }
          expect(await tester.runAsync(counts), before);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        });
      }
    }

    for (final system in ['diesel', 'solar', 'equivalent_hybrid']) {
      testWidgets('quick time picker chains start to end and guards cloud in $system',
          (tester) async {
        tester.view.physicalSize = const Size(1200, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() => repo.setSetting('system_type', system));
        final before = await tester.runAsync(counts);
        await tester.pumpWidget(MaterialApp(home: Scaffold(
          body: Builder(builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => NewIrrigationPage(
                repo, manager: true, compactOnly: true))),
            child: const Text('فتح السقاية السريعة'),
          )),
        )));
        await tester.tap(find.text('فتح السقاية السريعة'));
        await tester.pump();
        await waitFor(tester, () =>
            find.text('بطاقة وقت التشغيل').evaluate().isNotEmpty);
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('بداية التشغيل:'));
        await tester.pumpAndSettle();
        final startPicker = find.byKey(const ValueKey('quick-time-picker-start'));
        expect(startPicker, findsOneWidget);
        expect(
          tester.widget<AlertDialog>(startPicker).backgroundColor,
          Theme.of(tester.element(startPicker)).colorScheme.primaryContainer,
        );
        await tester.tap(find.descendant(
          of: startPicker, matching: find.text('تأكيد الوقت')));
        await tester.pumpAndSettle();

        final endPicker = find.byKey(const ValueKey('quick-time-picker-end'));
        expect(endPicker, findsOneWidget);
        expect(
          tester.widget<AlertDialog>(endPicker).backgroundColor,
          Theme.of(tester.element(endPicker)).colorScheme.secondaryContainer,
        );
        final cloudShortcut = find.byKey(const ValueKey('quick-end-cloud-button'));
        if (system == 'diesel') {
          expect(cloudShortcut, findsNothing);
          await tester.tap(find.descendant(
            of: endPicker, matching: find.text('تأكيد الوقت')));
          await tester.pumpAndSettle();
        } else {
          expect(cloudShortcut, findsOneWidget);
          await tester.tap(cloudShortcut);
          await tester.pumpAndSettle();
          expect(find.text('إضافة غيم / حساب وقت التوقف'), findsOneWidget);
          final dialogs = tester.widgetList<AlertDialog>(find.byType(AlertDialog));
          expect(dialogs.last.backgroundColor, const Color(0xFFF2EAFB));
          await tester.tap(find.text('إلغاء'));
          await tester.pumpAndSettle();
        }
        expect(find.text('بطاقة وقت التشغيل'), findsOneWidget);
        expect(find.text('حفظ سقاية'), findsOneWidget);
        await tester.tap(find.text('إغلاق'));
        await tester.pumpAndSettle();
        expect(await tester.runAsync(counts), before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }

    for (final kind in ['beneficiary', 'worker', 'partner']) {
      testWidgets('missing $kind fails closed without selecting another party', (tester) async {
        final before = await tester.runAsync(counts);
        await tester.pumpWidget(MaterialApp(home: NewIrrigationPage(repo,
          manager: true, initialPartyType: kind, initialPartyId: 999999,
          compactOnly: true)));
        await waitFor(tester, () => find.textContaining('هذا الشخص غير متاح').evaluate().isNotEmpty);
        expect(find.text('حفظ السقاية'), findsNothing);
        expect(await tester.runAsync(counts), before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  });
}
