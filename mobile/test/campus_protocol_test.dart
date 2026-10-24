import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:beyondnet/campus/campus_protocol.dart';
import 'package:beyondnet/ble_frames.dart';

void main() {
  test('Gateway Java and Android use identical indexed frames', () {
    final vector = jsonDecode(
      File('../contracts/vectors/indexed-frames.json').readAsStringSync(),
    );
    expect(
      BleFrames.encode(
        base64Decode(vector['message']),
        vector['tag'],
        frameBytes: vector['frame_bytes'],
      ).map(base64Encode).toList(),
      vector['frames'],
    );
    expect(base64Encode(BleFrames.select(vector['tag'], 2)), vector['cursor']);
  });
  final f =
      jsonDecode(File('../contracts/vectors/campus-v1.json').readAsStringSync())
          as Map<String, dynamic>;
  test('Campus Java/Python/Dart canonical and signature vector', () async {
    expect(utf8.decode(CampusProtocol.canonical(f['body'])), f['canonical']);
    expect(
      await CampusProtocol.verify(
        Map<String, dynamic>.from(f['signed']),
        f['public_key'],
        now: 100,
      ),
      f['body'],
    );
  });
  test('Altered response, wrong key and expiry fail closed', () async {
    final signed = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(f['signed'])),
    );
    signed['body']['query'] = 'altered';
    await expectLater(
      CampusProtocol.verify(signed, f['public_key'], now: 100),
      throwsFormatException,
    );
    await expectLater(
      CampusProtocol.verify(
        Map<String, dynamic>.from(f['signed']),
        f['public_key'],
        now: 160,
      ),
      throwsFormatException,
    );
    await expectLater(
      CampusProtocol.verify(
        Map<String, dynamic>.from(f['signed']),
        base64Encode(List.filled(44, 0)),
        now: 100,
      ),
      throwsFormatException,
    );
  });
  test('Query limit counts UTF-8 bytes', () {
    expect(CampusProtocol.query(' library '), 'library');
    expect(
      () => CampusProtocol.query(List.filled(129, 'é').join()),
      throwsFormatException,
    );
    expect(() => CampusProtocol.query(' '), throwsFormatException);
    expect(
      () => CampusProtocol.canonical({'float': 1.5}),
      throwsFormatException,
    );
  });
}
