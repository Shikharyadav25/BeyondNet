import 'dart:convert';
import 'package:beyondnet/campus/campus_setup_code.dart';
import 'package:beyondnet/campus/campus_setup_scan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> setup() => {
    'type': 'beyondnet-campus-setup', 'v': 1,
    'campus_url': 'https://psit.example/', 'code': 'PSIT-KANPUR',
    'fingerprint': 'ab' * 32,
  };
  test('PSIT setup imports code, HTTPS origin and fingerprint together', () {
    final code = CampusSetupCode.parse(jsonEncode(setup()));
    expect(code.code, 'PSIT-KANPUR');
    expect(code.url, 'https://psit.example');
    expect(code.fingerprint, 'ab' * 32);
  });
  test('rejects payment/bank QR, insecure origin and credentials in QR', () {
    for (final value in [
      {...setup(), 'type': 'beyondnet-bank-setup'},
      {...setup(), 'campus_url': 'http://psit.example'},
      {...setup(), 'campus_url': 'https://user:password@psit.example'},
      {...setup(), 'campus_url': 'https://psit.example/path'},
      {...setup(), 'fingerprint': 'invalid'},
      {...setup(), 'code': '../campus'},
      {...setup(), 'password': 'not-public'},
      {...setup(), 'v': 2},
    ]) {
      expect(() => CampusSetupCode.parse(jsonEncode(value)), throwsFormatException);
    }
  });
  test('gallery ignores unrelated QRs and refuses ambiguous campus images', () {
    final raw = jsonEncode(setup());
    expect(campusSetupFromValues([null, 'unrelated QR', raw, raw]), raw);
    expect(() => campusSetupFromValues([
      raw, jsonEncode({...setup(), 'campus_url': 'https://other.example'}),
    ]), throwsFormatException);
  });
}
