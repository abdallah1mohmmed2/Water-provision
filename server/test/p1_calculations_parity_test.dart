import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('P1 server uses the unchanged local accounting calculation rules', () {
    expect(
      File('lib/irrigation_calculations.dart').readAsStringSync(),
      File('../lib/domain/accounting/calculations.dart').readAsStringSync(),
    );
  });
}
