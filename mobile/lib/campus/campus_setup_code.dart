import 'dart:convert';
import '../bank_setup_code.dart';

/// Public college trust information; credentials are entered separately.
class CampusSetupCode {
  final String url, code, fingerprint;
  const CampusSetupCode(this.url, this.code, this.fingerprint);
  factory CampusSetupCode.parse(String raw) {
    try {
      if (raw.length > 4096) throw const FormatException();
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> || value.length != 5 ||
          value['type'] != 'beyondnet-campus-setup' || value['v'] is! int ||
          value['v'] != 1 || value['code'] is! String ||
          !RegExp(r'^[A-Z0-9-]{3,32}$').hasMatch(value['code'])) {
        throw const FormatException();
      }
      // Share the bank's strict HTTPS-origin and fingerprint validation.
      final origin = BankSetupCode.parse(jsonEncode({
        'type': 'beyondnet-bank-setup', 'v': 1,
        'bank_url': value['campus_url'], 'fingerprint': value['fingerprint'],
      }));
      return CampusSetupCode(origin.url, value['code'], origin.fingerprint);
    } catch (_) {
      throw const FormatException('Scan a BeyondNet campus setup QR from your college administrator. Bank and payment QRs cannot enroll a campus.');
    }
  }
}
