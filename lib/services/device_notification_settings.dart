import 'package:flutter/services.dart';

class DeviceNotificationSettings {
  static const MethodChannel _channel = MethodChannel('saqia/device_settings');
  static Future<bool> open() async {
    try {
      return await _channel.invokeMethod<bool>('openNotificationSettings') ?? false;
    } on PlatformException {
      return false;
    }
  }
}
