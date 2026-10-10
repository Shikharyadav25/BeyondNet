import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

typedef Json = Map<String, dynamic>;
Object? _sorted(Object? v) {
  if (v is Map) {
    final keys = v.keys.cast<String>().toList()..sort();
    return {for (final k in keys) k: _sorted(v[k])};
  }
  if (v is List) return v.map(_sorted).toList();
  if (v is double) throw ArgumentError('Wire values must not contain floats');
  return v;
}

List<int> canonical(Object? v) => utf8.encode(jsonEncode(_sorted(v)));
String hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
Future<String> digest(Object? v) async =>
    hex((await Sha256().hash(canonical(v))).bytes);
String randomCapability() =>
    hex(List.generate(24, (_) => Random.secure().nextInt(256)));
int get nowSeconds => DateTime.now().millisecondsSinceEpoch ~/ 1000;
final boxDomain = utf8.encode('offline-karo/box/v1');
final ed = Ed25519();
final x = X25519();
Future<Json> sign(SimpleKeyPair key, Json body) async => {
  'body': body,
  'signature': base64Encode(
    (await ed.sign(canonical(body), keyPair: key)).bytes,
  ),
};
Future<Json> verify(String key, Json signed) async {
  final valid = await ed.verify(
    canonical(signed['body']),
    signature: Signature(
      base64Decode(signed['signature']),
      publicKey: SimplePublicKey(base64Decode(key), type: KeyPairType.ed25519),
    ),
  );
  if (!valid) throw const FormatException('Signature verification failed');
  return Map<String, dynamic>.from(signed['body']);
}

Future<Json> seal(String recipient, Object value) async {
  final ephemeral = await x.newKeyPair();
  final ep = (await ephemeral.extractPublicKey()).bytes;
  final pub = base64Decode(recipient);
  final shared = await x.sharedSecretKey(
    keyPair: ephemeral,
    remotePublicKey: SimplePublicKey(pub, type: KeyPairType.x25519),
  );
  final key = await Hkdf(
    hmac: Hmac.sha256(),
    outputLength: 32,
  ).deriveKey(secretKey: shared, nonce: [...ep, ...pub], info: boxDomain);
  final box = await AesGcm.with256bits().encrypt(
    canonical(value),
    secretKey: key,
    aad: boxDomain,
  );
  return {
    'ephemeral': base64Encode(ep),
    'nonce': base64Encode(box.nonce),
    'ciphertext': base64Encode([...box.cipherText, ...box.mac.bytes]),
  };
}

Future<Json> openBox(SimpleKeyPair key, Json box) async {
  final ep = base64Decode(box['ephemeral']);
  final pub = (await key.extractPublicKey()).bytes;
  final shared = await x.sharedSecretKey(
    keyPair: key,
    remotePublicKey: SimplePublicKey(ep, type: KeyPairType.x25519),
  );
  final secret = await Hkdf(
    hmac: Hmac.sha256(),
    outputLength: 32,
  ).deriveKey(secretKey: shared, nonce: [...ep, ...pub], info: boxDomain);
  final ct = base64Decode(box['ciphertext']);
  if (ct.length < 16) throw const FormatException('Truncated encrypted box');
  final plain = await AesGcm.with256bits().decrypt(
    SecretBox(
      ct.sublist(0, ct.length - 16),
      nonce: base64Decode(box['nonce']),
      mac: Mac(ct.sublist(ct.length - 16)),
    ),
    secretKey: secret,
    aad: boxDomain,
  );
  return Map<String, dynamic>.from(jsonDecode(utf8.decode(plain)));
}

Future<Json> makePacket(
  String kind,
  Json box,
  String mailbox,
  int expiry, {
  List<String> path = const [],
}) async {
  final core = {
    'v': 1,
    'kind': kind,
    'mailbox': mailbox,
    'box': box,
    'expires_at': expiry,
  };
  return {...core, 'id': await digest(core), 'hops': 0, 'path': path};
}

Future<void> checkPacket(Json p) async {
  if (canonical(p).length > 8192 ||
      p['v'] != 1 ||
      !['payment', 'receipt'].contains(p['kind'])) {
    throw const FormatException('Invalid packet');
  }
  final core = {
    for (final k in ['v', 'kind', 'mailbox', 'box', 'expires_at']) k: p[k],
  };
  if (p['id'] != await digest(core)) {
    throw const FormatException('Packet integrity failed');
  }
  if (p['hops'] is! int ||
      p['hops'] < 0 ||
      p['hops'] > 4 ||
      p['path'] is! List ||
      p['path'].length > 8) {
    throw const FormatException('Invalid routing metadata');
  }
  for (final name in ['path', 'trail']) {
    final value = p[name];
    if (name == 'trail' && value == null) {
      continue; // v1 peers remain compatible.
    }
    if (value is! List ||
        value.length > (name == 'trail' ? 4 : 8) ||
        (name == 'trail' && value.length > p['hops']) ||
        value.any((id) => id is! String || id.isEmpty || id.length > 80) ||
        value.toSet().length != value.length) {
      throw const FormatException('Invalid routing history');
    }
  }
  if (p['expires_at'] is! int ||
      p['mailbox'] is! String ||
      p['mailbox'].length < 32 ||
      p['mailbox'].length > 100) {
    throw const FormatException('Invalid routing fields');
  }
}

Uint8List bytes(Object o) => Uint8List.fromList(canonical(o));
