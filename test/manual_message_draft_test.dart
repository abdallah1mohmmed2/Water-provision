import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/services/manual_message_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> calls;
  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      ManualMessageService.smsComposerChannel, (call) async { calls.add(call); return true; });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      ManualMessageService.smsComposerChannel, null);
  });
  Widget page({bool twice = false}) => MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
    onPressed: () {
      ManualMessageService.offerChoices(context, title: 'تجهيز', recipientName: 'سالم',
        phone: '771234567', message: 'رسالة أصلية 5.75 لتر');
      if (twice) {
        ManualMessageService.offerChoices(context, title: 'تجهيز', recipientName: 'سالم',
          phone: '771234567', message: 'رسالة أصلية 5.75 لتر');
      }
    },
    child: const Text('تجهيز الرسالة'),
  ))));
  final draft = find.byKey(const ValueKey('manual-message-draft'));

  testWidgets('deletion survives rebuild and resume until an explicit restore', (tester) async {
    await tester.pumpWidget(page());
    await tester.tap(find.text('تجهيز الرسالة'));
    await tester.pumpAndSettle();
    await tester.enterText(draft, '');
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(320, 480);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(draft).controller!.text, isEmpty);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'فتح SMS')).onPressed, isNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'فتح WhatsApp')).onPressed, isNull);
    expect(calls, isEmpty);
    await tester.ensureVisible(find.text('إعادة تجهيز النص'));
    await tester.tap(find.text('إعادة تجهيز النص'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(draft).controller!.text, 'رسالة أصلية 5.75 لتر');
    expect(calls, isEmpty);
    await tester.tap(find.text('لاحقًا'));
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('only edited text opens once and resume cannot repopulate or relaunch', (tester) async {
    await tester.pumpWidget(page());
    await tester.tap(find.text('تجهيز الرسالة'));
    await tester.pumpAndSettle();
    const replacement = 'تعديل يدوي\n4.65 + 5.75';
    await tester.enterText(draft, replacement);
    await tester.pumpAndSettle();
    await tester.tap(find.text('فتح SMS'));
    await tester.pumpAndSettle();
    expect(calls.length, 1);
    expect(calls.single.arguments, {'phone': '967771234567', 'message': replacement});
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls.length, 1);
    expect(draft, findsNothing);
    // A new explicit request may intentionally prepare the same message again.
    await tester.tap(find.text('تجهيز الرسالة'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(draft).controller!.text, 'رسالة أصلية 5.75 لتر');
    await tester.tap(find.text('لاحقًا'));
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('concurrent requests do not stack original message composers', (tester) async {
    await tester.pumpWidget(page(twice: true));
    await tester.tap(find.text('تجهيز الرسالة'));
    await tester.pumpAndSettle();
    expect(draft, findsOneWidget);
    await tester.enterText(draft, 'المسودة المعدلة');
    await tester.pump();
    await tester.tap(find.text('فتح SMS'));
    await tester.pumpAndSettle();
    expect(calls.length, 1);
    expect((calls.single.arguments as Map)['message'], 'المسودة المعدلة');
    expect(draft, findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
