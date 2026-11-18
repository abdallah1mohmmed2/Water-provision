import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Opens Android's contact *phone-number* picker.
///
/// Only the selected phone data URI is read on the native side. No full
/// address-book permission or contact synchronization is required.
class AndroidContactPicker {
  static const MethodChannel channel = MethodChannel('saqia/contacts');

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Returns the phone number, or null when the user cancels.
  static Future<String?> pickPhoneNumber() async {
    if (!supported) return null;
    final value = await channel.invokeMethod<String>('pickPhoneNumber');
    final number = value?.trim();
    return number == null || number.isEmpty ? null : number;
  }
}
