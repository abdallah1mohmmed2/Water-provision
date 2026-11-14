import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saqia_station/features/contact_phone_field.dart';
import 'package:saqia_station/services/android_contact_picker.dart';

void main() {
  // Flutter's test message binding must exist before reading its instance.
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(AndroidContactPicker.channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android contact icon imports selected number without saving', (tester) async {
    final controller = TextEditingController(text: 'old number');
    addTearDown(controller.dispose);
    var pickerCalls = 0;
    messenger.setMockMethodCallHandler(AndroidContactPicker.channel, (call) async {
      expect(call.method, 'pickPhoneNumber');
      pickerCalls++;
      return '+967 777 123 456';
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ContactPhoneField(controller: controller, labelText: 'الهاتف')),
    ));
    await tester.tap(find.byTooltip('اختيار رقم من جهات الاتصال'));
    await tester.pumpAndSettle();
    expect(pickerCalls, 1);
    expect(controller.text, '+967 777 123 456');
  });

  testWidgets('cancelling native picker retains previously entered number', (tester) async {
    final controller = TextEditingController(text: '0123456');
    addTearDown(controller.dispose);
    messenger.setMockMethodCallHandler(AndroidContactPicker.channel, (_) async => null);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ContactPhoneField(controller: controller, labelText: 'الهاتف')),
    ));
    await tester.tap(find.byTooltip('اختيار رقم من جهات الاتصال'));
    await tester.pumpAndSettle();
    expect(controller.text, '0123456');
  });

  testWidgets('native error preserves existing phone value', (tester) async {
    final controller = TextEditingController(text: '778899');
    addTearDown(controller.dispose);
    messenger.setMockMethodCallHandler(AndroidContactPicker.channel, (_) async {
      throw PlatformException(code: 'NO_CONTACTS_APP', message: 'لا يوجد تطبيق جهات اتصال');
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ContactPhoneField(controller: controller, labelText: 'الهاتف')),
    ));
    await tester.tap(find.byTooltip('اختيار رقم من جهات الاتصال'));
    await tester.pumpAndSettle();
    expect(controller.text, '778899');
    expect(find.text('لا يوجد تطبيق جهات اتصال'), findsOneWidget);
  });

  testWidgets('non-Android platforms retain manual phone entry without picker', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ContactPhoneField(controller: controller, labelText: 'الهاتف')),
    ));
    expect(find.byTooltip('اختيار رقم من جهات الاتصال'), findsNothing);
    await tester.enterText(find.byType(TextField), '123456');
    expect(controller.text, '123456');
  });
}
