import 'dart:convert';

/// Public enrollment configuration only: no account, PIN or operator credential.
class BankSetupCode {
  final String url;
  final String fingerprint;
  const BankSetupCode(this.url, this.fingerprint);

  factory BankSetupCode.parse(String raw) {
    try {
      if (raw.length > 4096) throw const FormatException();
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> ||
          value.length != 4 ||
          value['type'] != 'beyondnet-bank-setup' ||
          value['v'] is! int ||
          value['v'] != 1 ||
          value['bank_url'] is! String ||
          value['fingerprint'] is! String) {
        throw const FormatException();
      }
      final url = value['bank_url'] as String;
      final fingerprint = value['fingerprint'] as String;
      final uri = Uri.tryParse(url);
      if (url.length > 500 ||
          url != url.trim() ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.hasPort && (uri.port < 1 || uri.port > 65535)) ||
          (uri.path.isNotEmpty && uri.path != '/') ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(fingerprint)) {
        throw const FormatException();
      }
      return BankSetupCode(
        url.replaceAll(RegExp(r'/+$'), ''),
        fingerprint.toLowerCase(),
      );
    } catch (_) {
      throw const FormatException(
        'Choose a BeyondNet bank setup QR containing an HTTPS URL and bank fingerprint. A recipient payment QR cannot set up the bank.',
      );
    }
  }
}
