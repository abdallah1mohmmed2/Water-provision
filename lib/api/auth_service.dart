import 'dart:math';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'api_client.dart';

class AuthService {
  final ApiClient api;
  AuthService(this.api);
  String hash(String value) => sha256.convert(utf8.encode(value)).toString();
  String generateSixDigitCode() =>
      (100000 + Random.secure().nextInt(900000)).toString();
  Future<dynamic> loginByPhone(String phone, String code) =>
      api.post('/beneficiary/session', {'phone': phone, 'code': code});
  Future<dynamic> requestCode(String phone) =>
      api.post('/beneficiary/request-code', {'phone': phone});
}
