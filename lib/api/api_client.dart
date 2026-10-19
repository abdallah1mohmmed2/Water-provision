import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiClient {
  final String baseUrl;
  String? token;
  final http.Client client;
  ApiClient(this.baseUrl, {this.token, http.Client? client})
    : client = client ?? http.Client();
  void setToken(String? value) => token = value;
  Future<dynamic> get(String path) async => _request('GET', path);
  Future<dynamic> post(String path, Map<String, dynamic> body) async =>
      _request('POST', path, body);
  Future<dynamic> put(String path, Map<String, dynamic> body) async =>
      _request('PUT', path, body);
  Future<dynamic> _request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-Station-Id': '1',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    final uri = Uri.parse('$baseUrl/api/v1$path');
    final r = switch (method) {
      'GET' => await client.get(uri, headers: headers),
      'PUT' => await client.put(
        uri,
        headers: headers,
        body: jsonEncode(body ?? {}),
      ),
      _ => await client.post(
        uri,
        headers: headers,
        body: jsonEncode(body ?? {}),
      ),
    };
    if (r.statusCode < 200 || r.statusCode >= 300)
      throw StateError('فشل الاتصال بالخادم: ${r.body}');
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }
}

class BeneficiaryApi {
  final ApiClient api;
  BeneficiaryApi(this.api);
  Future<dynamic> me() => api.get('/beneficiary/me');
  Future<dynamic> requests() => api.get('/beneficiary/requests');
  Future<dynamic> createRequest(String notes) =>
      api.post('/beneficiary/requests', {'notes': notes});
  Future<dynamic> cancelRequest(int id, String reason) =>
      api.post('/beneficiary/requests/$id/cancel', {'reason': reason});
  Future<dynamic> account() => api.get('/beneficiary/account');
  Future<dynamic> notifications() => api.get('/beneficiary/notifications');
  Future<dynamic> readNotification(int id) =>
      api.post('/beneficiary/notifications/$id/read', {});
}
