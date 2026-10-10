import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'protocol.dart';

// Small ATT-safe frames: one flag byte + <=19 bytes, never a long GATT read.
// Bit 0 starts a message; bit 1 ends it. Empty [0] means response pending.
const frameSize = 19;
const maxRpcBytes = 12288;
final serviceId = UUID.fromString('f953c610-4f9e-4ac8-a6d6-6f666b61726f');
final rpcId = UUID.fromString('f953c611-4f9e-4ac8-a6d6-6f666b61726f');
List<Uint8List> frames(List<int> data) => [
  for (var i = 0; i < data.length; i += frameSize)
    Uint8List.fromList([
      (i == 0 ? 1 : 0) | (i + frameSize >= data.length ? 2 : 0),
      ...data.sublist(i, (i + frameSize).clamp(0, data.length)),
    ]),
];

class Assembly {
  final List<int> data = [];
  DateTime touched = DateTime.now();
  bool begun = false;
  Uint8List? add(List<int> frame) {
    touched = DateTime.now();
    if (frame.isEmpty || frame.length > 20) {
      throw const FormatException('Bad BLE frame');
    }
    final flags = frame[0];
    if (flags & 1 != 0) {
      data.clear();
      begun = true;
    }
    if (!begun || flags > 3) {
      throw const FormatException('Unexpected BLE continuation');
    }
    data.addAll(frame.skip(1));
    if (data.length > maxRpcBytes) {
      data.clear();
      begun = false;
      throw const FormatException('BLE message exceeds limit');
    }
    if (flags & 2 != 0) {
      begun = false;
      return Uint8List.fromList(data);
    }
    return null;
  }
}

class PeerRadio {
  final Peripheral peripheral;
  int rssi;
  DateTime seen;
  PeerRadio(this.peripheral, this.rssi) : seen = DateTime.now();
}

abstract interface class PeerTransport {
  Map<String, PeerRadio> get discovered;
  bool get running;
  Future<void> start();
  Future<void> stop();
  Future<T> connect<T>(
    PeerRadio peer,
    Future<T> Function(Future<Json> Function(Json)) run,
  );
}

class BleTransport implements PeerTransport {
  final CentralManager central = CentralManager();
  final PeripheralManager peripheral = PeripheralManager();
  @override
  final Map<String, PeerRadio> discovered = {};
  final Map<String, Assembly> incoming = {};
  final Map<String, List<Uint8List>> outgoing = {};
  final Map<String, DateTime> touched = {};
  final Set<String> processing = {};
  final List<StreamSubscription> subscriptions = [];
  final Future<Json> Function(Json) handler;
  final void Function(String) onEvent;
  @override
  bool running = false;
  Timer? cleanup;
  BleTransport(this.handler, this.onEvent);
  @override
  Future<void> start() async {
    if (running) return;
    // Managers resolve initial poweredOn asynchronously after construction.
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while ((central.state != BluetoothLowEnergyState.poweredOn ||
            peripheral.state != BluetoothLowEnergyState.poweredOn) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (central.state != BluetoothLowEnergyState.poweredOn ||
        peripheral.state != BluetoothLowEnergyState.poweredOn) {
      throw StateError(
        'Turn Bluetooth on and allow Nearby devices (Android 12+) or Location access with Location on (Android 10–11).',
      );
    }
    subscriptions.add(
      central.discovered.listen((e) {
        final id = e.peripheral.uuid.toString();
        discovered[id] = PeerRadio(e.peripheral, e.rssi);
      }),
    );
    subscriptions.add(
      peripheral.characteristicWriteRequested.listen((e) async {
        final id = e.central.uuid.toString();
        try {
          if (e.characteristic.uuid != rpcId ||
              e.request.offset != 0 ||
              processing.contains(id)) {
            throw const FormatException('Invalid write');
          }
          if (!incoming.containsKey(id) && incoming.length >= 8) {
            throw StateError('Peer session limit');
          }
          touched[id] = DateTime.now();
          final value = (incoming[id] ??= Assembly()).add(e.request.value);
          await peripheral.respondWriteRequest(e.request);
          if (value != null) {
            processing.add(id);
            outgoing.remove(id);
            try {
              final request = Map<String, dynamic>.from(
                jsonDecode(utf8.decode(value)),
              );
              final result = await handler(
                request,
              ).timeout(const Duration(seconds: 20));
              outgoing[id] = frames(canonical(result));
            } catch (_) {
              outgoing[id] = frames(
                utf8.encode('{"error":"Peer exchange rejected"}'),
              );
            } finally {
              processing.remove(id);
            }
          }
        } catch (_) {
          // A protocol failure produces no storage ACK; the sender keeps its original.
          outgoing[id] = frames(utf8.encode('{"error":"Invalid BLE frame"}'));
          try {
            await peripheral.respondWriteRequest(e.request);
          } catch (_) {}
        }
      }),
    );
    subscriptions.add(
      peripheral.characteristicReadRequested.listen((e) async {
        final id = e.central.uuid.toString();
        touched[id] = DateTime.now();
        final q = outgoing[id];
        final value = (q != null && q.isNotEmpty)
            ? q.removeAt(0)
            : Uint8List.fromList([0]);
        final offset = e.request.offset;
        await peripheral.respondReadRequestWithValue(
          e.request,
          value: offset <= value.length ? value.sublist(offset) : Uint8List(0),
        );
      }),
    );
    final characteristic = GATTCharacteristic.mutable(
      uuid: rpcId,
      properties: [
        GATTCharacteristicProperty.read,
        GATTCharacteristicProperty.write,
      ],
      permissions: [
        GATTCharacteristicPermission.read,
        GATTCharacteristicPermission.write,
      ],
      descriptors: [],
    );
    await peripheral.removeAllServices();
    await peripheral.addService(
      GATTService(
        uuid: serviceId,
        isPrimary: true,
        includedServices: [],
        characteristics: [characteristic],
      ),
    );
    try {
      await peripheral.startAdvertising(
        Advertisement(name: 'BeyondNet', serviceUUIDs: [serviceId]),
      );
      await central.startDiscovery(serviceUUIDs: [serviceId]);
      running = true;
      cleanup = Timer.periodic(const Duration(seconds: 20), (_) {
        for (final id in touched.keys.toList()) {
          if (DateTime.now().difference(touched[id]!).inSeconds > 40 &&
              !processing.contains(id)) {
            incoming.remove(id);
            outgoing.remove(id);
            touched.remove(id);
          }
        }
        discovered.removeWhere(
          (_, p) => DateTime.now().difference(p.seen).inSeconds > 90,
        );
      });
      onEvent('Nearby Bluetooth relay started.');
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  @override
  Future<T> connect<T>(
    PeerRadio peer,
    Future<T> Function(Future<Json> Function(Json)) run,
  ) async {
    final p = peer.peripheral;
    try {
      await central.connect(p).timeout(const Duration(seconds: 10));
      final services = await central
          .discoverGATT(p)
          .timeout(const Duration(seconds: 10));
      final characteristic = services
          .firstWhere((s) => s.uuid == serviceId)
          .characteristics
          .firstWhere((c) => c.uuid == rpcId);
      Future<Json> rpc(Json request) async {
        final wire = canonical(request);
        if (wire.length > maxRpcBytes) {
          throw const FormatException('RPC exceeds limit');
        }
        for (final f in frames(wire)) {
          await central
              .writeCharacteristic(
                p,
                characteristic,
                value: f,
                type: GATTCharacteristicWriteType.withResponse,
              )
              .timeout(const Duration(seconds: 5));
        }
        final assembled = Assembly();
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (DateTime.now().isBefore(deadline)) {
          final f = await central
              .readCharacteristic(p, characteristic)
              .timeout(const Duration(seconds: 5));
          if (f.length == 1 && f[0] == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            continue;
          }
          final done = assembled.add(f);
          if (done != null) {
            return Map<String, dynamic>.from(jsonDecode(utf8.decode(done)));
          }
        }
        throw TimeoutException('Peer did not acknowledge stored packet');
      }

      return await run(rpc);
    } finally {
      try {
        await central.disconnect(p);
      } catch (_) {}
    }
  }

  @override
  Future<void> stop() async {
    running = false;
    cleanup?.cancel();
    try {
      await central.stopDiscovery();
    } catch (_) {}
    try {
      await peripheral.stopAdvertising();
    } catch (_) {}
    for (final s in subscriptions) {
      await s.cancel();
    }
    subscriptions.clear();
    incoming.clear();
    outgoing.clear();
    touched.clear();
    processing.clear();
    discovered.clear();
  }
}
