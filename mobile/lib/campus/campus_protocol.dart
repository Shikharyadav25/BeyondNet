import 'dart:collection';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';

typedef CampusJson = Map<String, dynamic>;

class CampusProtocol {
  static const domain = 'beyondnet/campus/v1\n';
  static const serviceUuid = '5cebe240-7de4-43eb-843b-96260d973a10';
  static const characteristicUuid = '5cebe240-7de4-43eb-843b-96260d973a11';
  static dynamic _sorted(dynamic value) {
    if (value is Map<String, dynamic>) {
      return SplayTreeMap<String, dynamic>.from(
        value.map((k, v) => MapEntry(k, _sorted(v))),
      );
    }
    if (value is List) return value.map(_sorted).toList();
    if (value == null || value is String || value is bool || value is int) {
      return value;
    }
    throw const FormatException('Invalid campus value');
  }

  static List<int> canonical(dynamic value) =>
      utf8.encode(jsonEncode(_sorted(value)));
  static String query(String value) {
    if (value.trim().isEmpty || utf8.encode(value).length > 256) {
      throw const FormatException('Enter a query of 1–256 UTF-8 bytes.');
    }
    return value.trim();
  }

  static Future<CampusJson> verify(
    CampusJson envelope,
    String publisherKey, {
    int? now,
  }) async {
    if (envelope.length != 2 ||
        !envelope.containsKey('body') ||
        !envelope.containsKey('signature')) {
      throw const FormatException('Invalid signed campus content');
    }
    final der = base64Decode(publisherKey);
    // Ed25519 SubjectPublicKeyInfo prefix, followed by the raw 32-byte key.
    const prefix = [
      0x30,
      0x2a,
      0x30,
      0x05,
      0x06,
      0x03,
      0x2b,
      0x65,
      0x70,
      0x03,
      0x21,
      0x00,
    ];
    if (der.length != 44 ||
        List.generate(12, (i) => der[i] != prefix[i]).any((x) => x)) {
      throw const FormatException('Invalid campus publisher key');
    }
    final body = Map<String, dynamic>.from(envelope['body'] as Map);
    final ok = await Ed25519().verify(
      [...utf8.encode(domain), ...canonical(body)],
      signature: Signature(
        base64Decode(envelope['signature'] as String),
        publicKey: SimplePublicKey(der.sublist(12), type: KeyPairType.ed25519),
      ),
    );
    if (!ok) {
      throw const FormatException('Campus signature could not be verified');
    }
    final time = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final created = body['created_at'], expiry = body['expires_at'];
    if (body['v'] != 1 ||
        created is! int ||
        expiry is! int ||
        created > time + 30 ||
        expiry <= time ||
        expiry <= created) {
      throw const FormatException(
        'Campus information expired. Connect to refresh it.',
      );
    }
    return body;
  }
}
