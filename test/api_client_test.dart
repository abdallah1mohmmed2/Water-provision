import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../lib/api/api_client.dart';

void main() {
  test('transport failures are distinguishable for offline-cache fallback', () async {
    final api = ApiClient(
      'https://station.example',
      client: MockClient((_) async {
        throw http.ClientException('connection refused');
      }),
    );
    expect(api.get('/beneficiaries'), throwsA(isA<ApiConnectionException>()));
  });

  test('HTTP errors are not classified as offline transport failures', () async {
    final api = ApiClient(
      'https://station.example',
      client: MockClient((_) async => http.Response('unauthorized', 401)),
    );
    expect(api.get('/beneficiaries'), throwsA(isA<ApiResponseException>()));
  });

  test('successful API responses decode JSON', () async {
    final api = ApiClient(
      'https://station.example',
      client: MockClient((_) async => http.Response('[{"name":"A"}]', 200)),
    );
    final response = await api.get('/beneficiaries');
    expect(response, isA<List<dynamic>>());
    expect((response as List).single['name'], 'A');
  });
}
