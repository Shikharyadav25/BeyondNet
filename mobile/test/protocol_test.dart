import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:beyondnet/protocol.dart';
import 'package:beyondnet/ble_transport.dart';

void main() {
  final fixture = Map<String, dynamic>.from(
    jsonDecode(File('test/fixtures/python-wire.json').readAsStringSync()),
  );
  test('Python and Dart canonical JSON and Ed25519 signatures agree', () async {
    expect(utf8.decode(canonical(fixture['body'])), fixture['canonical']);
    final key = await ed.newKeyPairFromSeed(base64Decode(fixture['sign_seed']));
    expect(
      base64Encode((await key.extractPublicKey()).bytes),
      fixture['sign_public'],
    );
    expect(
      await sign(key, Map<String, dynamic>.from(fixture['body'])),
      fixture['signed'],
    );
    expect(
      await verify(
        fixture['sign_public'],
        Map<String, dynamic>.from(fixture['signed']),
      ),
      fixture['body'],
    );
  });
  test('Dart decrypts Python X25519 HKDF AES-GCM envelope', () async {
    final key = await x.newKeyPairFromSeed(base64Decode(fixture['box_seed']));
    expect(
      base64Encode((await key.extractPublicKey()).bytes),
      fixture['box_public'],
    );
    expect(
      await openBox(key, Map<String, dynamic>.from(fixture['box'])),
      fixture['signed'],
    );
    await checkPacket(Map<String, dynamic>.from(fixture['packet']));
  });
  test('Dart emits envelope for independent Python validation', () async {
    final key = await ed.newKeyPairFromSeed(base64Decode(fixture['sign_seed']));
    final signed = await sign(key, Map<String, dynamic>.from(fixture['body']));
    final box = await seal(fixture['box_public'], signed);
    final p = await makePacket('payment', box, 'b' * 48, 2000000000);
    await File('build/dart-wire.json').create(recursive: true);
    await File('build/dart-wire.json').writeAsString(jsonEncode(p));
  });
  test('Tampering fails signature, AEAD and packet checks', () async {
    final signed = Map<String, dynamic>.from(fixture['signed']);
    signed['body'] = {
      ...Map<String, dynamic>.from(signed['body']),
      'amount': 1,
    };
    await expectLater(
      verify(fixture['sign_public'], signed),
      throwsA(isA<FormatException>()),
    );
    final box = Map<String, dynamic>.from(fixture['box']);
    final ct = base64Decode(box['ciphertext']);
    ct[0] ^= 1;
    box['ciphertext'] = base64Encode(ct);
    final key = await x.newKeyPairFromSeed(base64Decode(fixture['box_seed']));
    await expectLater(openBox(key, box), throwsA(anything));
    final p = Map<String, dynamic>.from(fixture['packet'])
      ..['mailbox'] = 'c' * 48;
    await expectLater(checkPacket(p), throwsA(isA<FormatException>()));
  });
  test('BLE frames reassemble an 8KB packet at minimum ATT payload', () {
    final data = List.generate(8192, (i) => i % 256);
    final f = frames(data);
    final receiver = Assembly();
    expect(f.every((x) => x.length <= 20), isTrue);
    for (final part in f.take(f.length - 1)) {
      expect(receiver.add(part), isNull);
    }
    expect(receiver.add(f.last), data);
  });
  test(
    'Interrupted transfer restarts cleanly and oversized input is refused',
    () {
      final receiver = Assembly();
      receiver.add([1, 1, 2, 3]);
      expect(receiver.add([3, 4, 5]), [4, 5]);
      expect(() => receiver.add([0, 1]), throwsFormatException);
      expect(() => receiver.add(List.filled(21, 0)), throwsFormatException);
      final huge = frames(List.filled(maxRpcBytes + 1, 1));
      expect(() => huge.forEach(receiver.add), throwsFormatException);
    },
  );
  test('Hop overflow is rejected', () async {
    final p = Map<String, dynamic>.from(fixture['packet'])..['hops'] = 5;
    await expectLater(checkPacket(p), throwsFormatException);
  });
}
