import 'dart:io';
import 'package:test/test.dart';
import '../lib/party_diesel_rate.dart';

void main() {
  test('personal rate overrides station rate with validation and nullable reset', () {
    expect(PartyDieselRate.resolve(4.65, 10), 4.65);
    expect(PartyDieselRate.resolve(null, 10), 10);
    for (final value in [-1, 0, double.nan, double.infinity, 4.655, '4.65']) {
      expect(() => PartyDieselRate.validate(value), throwsArgumentError);
    }
    expect(File('lib/party_diesel_rate.dart').readAsStringSync(),
      File('../lib/core/party_diesel_rate.dart').readAsStringSync());
  });
}
