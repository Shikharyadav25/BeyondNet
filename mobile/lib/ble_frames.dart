import 'dart:typed_data';

/// Indexed GATT messages. Reads select a frame explicitly and never consume it.
/// A transfer tag separates successive signed RPCs on the same connection.
class BleFrames {
  static const header = 7;
  static const limit = 12288;
  static int tag(List<int> frame) =>
      ByteData.sublistView(Uint8List.fromList(frame)).getUint32(1);
  static int index(List<int> frame) => (frame[5] << 8) | frame[6];

  static Uint8List _header(int flags, int transfer, int index) {
    final bytes = Uint8List(header);
    final data = ByteData.sublistView(bytes);
    bytes[0] = flags;
    data.setUint32(1, transfer);
    data.setUint16(5, index);
    return bytes;
  }

  static Uint8List select(int transfer, int index) =>
      _header(4, transfer, index);

  static List<Uint8List> encode(
    List<int> message,
    int transfer, {
    int frameBytes = 20,
  }) {
    if (message.isEmpty ||
        message.length > limit ||
        frameBytes < 20 ||
        frameBytes > 512) {
      throw const FormatException('Invalid indexed BLE message');
    }
    final payload = frameBytes - header;
    return [
      for (
        var offset = 0, index = 0;
        offset < message.length;
        offset += payload, index++
      )
        Uint8List.fromList([
          ..._header(
            (offset == 0 ? 1 : 0) |
                (offset + payload >= message.length ? 2 : 0),
            transfer,
            index,
          ),
          ...message.sublist(
            offset,
            (offset + payload).clamp(0, message.length),
          ),
        ]),
    ];
  }
}

class IndexedBleAssembly {
  int? transfer;
  final List<Uint8List> _parts = [];
  final List<int> _data = [];
  bool _complete = false;
  int get nextIndex => _parts.length;

  Uint8List? add(List<int> frame) {
    if (frame.length <= BleFrames.header ||
        frame.length > 512 ||
        frame[0] > 3) {
      throw const FormatException('Invalid indexed BLE frame');
    }
    final tag = BleFrames.tag(frame), index = BleFrames.index(frame);
    final start = frame[0] & 1 != 0;
    if (transfer != tag) {
      if (!start || index != 0) {
        throw const FormatException('BLE transfer did not start');
      }
      transfer = tag;
      _parts.clear();
      _data.clear();
      _complete = false;
    }
    if (start != (index == 0)) {
      throw const FormatException('Invalid BLE start frame');
    }
    if (index < _parts.length) {
      final previous = _parts[index];
      if (previous.length != frame.length ||
          List.generate(
            frame.length,
            (i) => i,
          ).any((i) => previous[i] != frame[i])) {
        throw const FormatException('Conflicting BLE retransmission');
      }
      return null; // An ATT retry must not append bytes or execute an RPC twice.
    }
    if (_complete || index != _parts.length) {
      throw const FormatException('Missing or reordered BLE frame');
    }
    if (_data.length + frame.length - BleFrames.header > BleFrames.limit) {
      throw const FormatException('BLE message exceeds limit');
    }
    _parts.add(Uint8List.fromList(frame));
    _data.addAll(frame.skip(BleFrames.header));
    if (frame[0] & 2 != 0) {
      _complete = true;
      return Uint8List.fromList(_data);
    }
    return null;
  }
}

class IndexedBleSession {
  final assembly = IndexedBleAssembly();
  List<Uint8List>? response;
  int selected = 0;

  void select(List<int> control) {
    if (control.length != BleFrames.header ||
        control[0] != 4 ||
        BleFrames.tag(control) != assembly.transfer) {
      throw const FormatException('Invalid BLE response cursor');
    }
    selected = BleFrames.index(control);
  }

  Uint8List read() {
    final frames = response;
    if (frames == null) return Uint8List.fromList([0]);
    if (selected >= frames.length) {
      throw const FormatException('BLE response cursor out of range');
    }
    return frames[selected];
  }
}
