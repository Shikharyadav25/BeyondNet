import 'dart:typed_data';
import 'package:beyondnet/ble_frames.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('minimum and negotiated MTUs preserve an entire maximum-sized RPC', () {
    final data = List.generate(BleFrames.limit, (i) => i % 251);
    for (final size in [20, 180, 512]) {
      final frames = BleFrames.encode(data, 0x12345678, frameBytes: size);
      final assembly = IndexedBleAssembly();
      Uint8List? result;
      for (final frame in frames) {
        expect(frame.length, lessThanOrEqualTo(size));
        result = assembly.add(frame);
      }
      expect(result, data);
    }
  });

  test(
    'duplicate ATT writes never duplicate bytes or execute final RPC twice',
    () {
      final data = List.generate(500, (i) => i % 251);
      final assembly = IndexedBleAssembly();
      var executions = 0;
      for (final frame in BleFrames.encode(data, 42)) {
        final result = assembly.add(frame);
        if (result != null) {
          executions++;
          expect(result, data);
        }
        expect(assembly.add(frame), isNull);
      }
      expect(executions, 1);
    },
  );

  test(
    'lost/repeated response reads return the selected bytes without advancing',
    () {
      final session = IndexedBleSession();
      session.assembly.add(BleFrames.encode([1, 2, 3], 42).single);
      session.select(BleFrames.select(42, 0));
      expect(session.read(), [
        0,
      ]); // Handler still computing its signed response.
      final response = BleFrames.encode(List.filled(100, 9), 42);
      session.response = response;
      final receiver = IndexedBleAssembly();
      for (var index = 0; index < response.length; index++) {
        session.select(BleFrames.select(42, index));
        final first = session.read();
        expect(session.read(), first);
        expect(BleFrames.index(first), index);
        receiver.add(first);
      }
      expect(receiver.nextIndex, response.length);
      expect(
        () => session.select(BleFrames.select(43, 0)),
        throwsFormatException,
      );
      session.select(BleFrames.select(42, response.length));
      expect(session.read, throwsFormatException);
    },
  );

  test('missing, conflicting and cross-transfer fragments fail closed', () {
    final frames = BleFrames.encode(List.filled(60, 3), 1);
    final assembly = IndexedBleAssembly();
    expect(() => assembly.add(frames[1]), throwsFormatException);
    assembly.add(frames[0]);
    expect(() => assembly.add(frames[2]), throwsFormatException);
    final conflicting = Uint8List.fromList(frames[0])..[7] = 4;
    expect(() => assembly.add(conflicting), throwsFormatException);
    final next = BleFrames.encode([8, 9], 2).single;
    expect(assembly.add(next), [8, 9]);
    expect(() => assembly.add(frames[1]), throwsFormatException);
  });

  test('oversized messages and malformed frames are rejected', () {
    expect(
      () => BleFrames.encode(List.filled(BleFrames.limit + 1, 0), 1),
      throwsFormatException,
    );
    expect(() => IndexedBleAssembly().add([0]), throwsFormatException);
    expect(
      () => BleFrames.encode([1], 1, frameBytes: 19),
      throwsFormatException,
    );
  });
}
