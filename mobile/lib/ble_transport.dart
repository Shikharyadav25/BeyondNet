import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'protocol.dart';
import 'android_ble_session.dart';
import 'ble_frames.dart';

// Small ATT-safe frames: one flag byte + <=19 bytes, never a long GATT read.
// Bit 0 starts a message; bit 1 ends it. Empty [0] means response pending.
const frameSize = 19;
const maxRpcBytes = 12288;
final serviceId = UUID.fromString('f953c610-4f9e-4ac8-a6d6-6f666b61726f');
final rpcId = UUID.fromString('f953c611-4f9e-4ac8-a6d6-6f666b61726f');
final indexedRpcId = UUID.fromString('f953c612-4f9e-4ac8-a6d6-6f666b61726f');
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
  final CentralManager central;
  final PeripheralManager peripheral;
  final AndroidBleSession? androidSession;
  final Duration operationTimeout, cleanupTimeout;
  @override
  final Map<String, PeerRadio> discovered = {};
  final Map<String, Assembly> incoming = {};
  final Map<String, List<Uint8List>> outgoing = {};
  final Map<String, DateTime> touched = {};
  final Set<String> processing = {};
  final Map<String, IndexedBleSession> indexed = {};
  final List<StreamSubscription> subscriptions = [];
  final Future<Json> Function(Json) handler;
  final void Function(String) onEvent;
  @override
  bool running = false;
  bool _connecting = false;
  Timer? cleanup;
  BleTransport(
    this.handler,
    this.onEvent, {
    CentralManager? central,
    PeripheralManager? peripheral,
    AndroidBleSession? androidSession,
    this.operationTimeout = const Duration(seconds: 8),
    this.cleanupTimeout = const Duration(seconds: 3),
  }) : central = central ?? CentralManager(),
       peripheral = peripheral ?? PeripheralManager(),
       androidSession =
           androidSession ?? (Platform.isAndroid ? AndroidBleSession() : null);
  @override
  Future<void> start() async {
    if (running) return;
    // Managers resolve initial poweredOn asynchronously after construction.
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while ((central.state != BluetoothLowEnergyState.poweredOn ||
            peripheral.state != BluetoothLowEnergyState.poweredOn) &&
        DateTime.now().isBefore(deadline)) {
      if (central.state == BluetoothLowEnergyState.unsupported ||
          peripheral.state == BluetoothLowEnergyState.unsupported) {
        throw StateError(
          'This phone does not support Bluetooth LE relaying. Online payments remain available.',
        );
      }
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
        // Some Android scanners miss a 128-bit service UUID when filtering in
        // the controller. A peer's name also helps when scan records omit the
        // UUID; the signed device certificate still authenticates the peer.
        if (!e.advertisement.serviceUUIDs.any(
              (uuid) => uuid.toString() == serviceId.toString(),
            ) &&
            e.advertisement.name != 'BeyondNet') {
          return;
        }
        final id = e.peripheral.uuid.toString();
        discovered[id] = PeerRadio(e.peripheral, e.rssi);
      }),
    );
    subscriptions.add(
      peripheral.characteristicWriteRequested.listen((e) async {
        final id = e.central.uuid.toString();
        if (e.characteristic.uuid == indexedRpcId) {
          await _indexedWrite(e, id);
          return;
        }
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
        try {
          final q = outgoing[id];
          final value = e.characteristic.uuid == indexedRpcId
              ? indexed[id]?.read() ?? Uint8List.fromList([0])
              : (q != null && q.isNotEmpty)
              ? q.first
              : Uint8List.fromList([0]);
          final offset = e.request.offset;
          await peripheral.respondReadRequestWithValue(
            e.request,
            value: offset <= value.length
                ? value.sublist(offset)
                : Uint8List(0),
          );
          if (e.characteristic.uuid == rpcId &&
              q != null &&
              q.isNotEmpty &&
              offset == 0) {
            q.removeAt(0);
          }
        } catch (_) {
          // A disconnect/service restart can invalidate a pending read. Do not
          // leak an unhandled async exception or claim a storage ACK.
          onEvent('Bluetooth read interrupted; saved packets will retry.');
        }
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
    try {
      // Android may retain a closed/busy GATT server after a failed start or
      // adapter restart. Open a fresh session and retry bounded registration.
      // Cleanup covers registration too, not only advertising/discovery.
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await androidSession?.reopen();
          await peripheral.removeAllServices().timeout(operationTimeout);
          await peripheral
              .addService(
                GATTService(
                  uuid: serviceId,
                  isPrimary: true,
                  includedServices: [],
                  characteristics: [
                    characteristic,
                    GATTCharacteristic.mutable(
                      uuid: indexedRpcId,
                      properties: [
                        GATTCharacteristicProperty.read,
                        GATTCharacteristicProperty.write,
                      ],
                      permissions: [
                        GATTCharacteristicPermission.read,
                        GATTCharacteristicPermission.write,
                      ],
                      descriptors: [],
                    ),
                  ],
                ),
              )
              .timeout(operationTimeout);
          break;
        } on TimeoutException {
          // A missing Android callback is not a refused registration. Close the
          // session before another attempt rather than stacking pending calls.
          rethrow;
        } catch (_) {
          if (attempt == 2) {
            throw StateError(
              'This phone could not start its Bluetooth relay service. '
              'Turn Bluetooth off and on, then try again. '
              'Online payments remain available; relaying does not require a payment PIN or an online bank.',
            );
          }
          await androidSession?.close();
          await Future<void>.delayed(
            Duration(milliseconds: 350 * (attempt + 1)),
          );
        }
      }
      await peripheral
          .startAdvertising(
            Advertisement(name: 'BeyondNet', serviceUUIDs: [serviceId]),
          )
          .timeout(operationTimeout);
      await central.startDiscovery().timeout(operationTimeout);
      running = true;
      cleanup = Timer.periodic(const Duration(seconds: 20), (_) {
        for (final id in touched.keys.toList()) {
          if (DateTime.now().difference(touched[id]!).inSeconds > 40 &&
              !processing.contains(id)) {
            incoming.remove(id);
            outgoing.remove(id);
            indexed.remove(id);
            touched.remove(id);
          }
        }
        discovered.removeWhere(
          (_, p) => DateTime.now().difference(p.seen).inSeconds > 90,
        );
      });
      onEvent('Nearby Bluetooth relay started.');
    } catch (error) {
      await stop();
      if (error is TimeoutException) {
        throw StateError(
          'Bluetooth did not finish starting. Turn Bluetooth off and on, '
          'then try Nearby relay again. Your saved payments are retained.',
        );
      }
      if (error is! StateError) {
        throw StateError(
          'Bluetooth relay could not start. Check Nearby devices permissions '
          'and turn Bluetooth off and on before trying again. '
          'The bank and payment PIN do not control Bluetooth startup.',
        );
      }
      rethrow;
    }
  }

  Future<void> _indexedWrite(
    GATTCharacteristicWriteRequestedEventArgs e,
    String id,
  ) async {
    var acknowledged = false;
    try {
      if (e.request.offset != 0 || e.request.value.isEmpty) {
        throw const FormatException('Invalid BLE write');
      }
      if (!indexed.containsKey(id) && indexed.length >= 8) {
        throw StateError('Peer session limit');
      }
      touched[id] = DateTime.now();
      final session = indexed.putIfAbsent(id, IndexedBleSession.new);
      final frame = e.request.value;
      if (frame[0] == 4) {
        session.select(frame);
        await peripheral.respondWriteRequest(e.request);
        return;
      }
      if (frame.length < BleFrames.header) {
        throw const FormatException('Invalid BLE frame');
      }
      if (session.assembly.transfer != BleFrames.tag(frame)) {
        if (processing.contains('indexed:$id')) {
          throw StateError('Previous BLE command is still running');
        }
        session.response = null;
        session.selected = 0;
      }
      final message = session.assembly.add(frame);
      if (message != null) processing.add('indexed:$id');
      await peripheral.respondWriteRequest(e.request);
      acknowledged = true;
      if (message == null) return;
      try {
        final request = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(message)),
        );
        final result = await handler(
          request,
        ).timeout(const Duration(seconds: 20));
        var frameBytes = 20;
        try {
          frameBytes = (await peripheral.getMaximumNotifyLength(
            e.central,
          )).clamp(20, 180);
        } catch (_) {}
        session.response = BleFrames.encode(
          canonical(result),
          session.assembly.transfer!,
          frameBytes: frameBytes,
        );
      } catch (_) {
        session.response = BleFrames.encode(
          utf8.encode('{"error":"Peer exchange rejected"}'),
          session.assembly.transfer!,
        );
      } finally {
        processing.remove('indexed:$id');
      }
    } catch (_) {
      if (!acknowledged) {
        try {
          await peripheral.respondWriteRequestWithError(
            e.request,
            error: GATTError.unlikelyError,
          );
        } catch (_) {}
      }
      onEvent('Bluetooth exchange interrupted; saved packets will retry.');
    }
  }

  @override
  Future<T> connect<T>(
    PeerRadio peer,
    Future<T> Function(Future<Json> Function(Json)) run,
  ) async {
    if (_connecting) {
      throw StateError(
        'Another Bluetooth exchange is in progress. Retry shortly.',
      );
    }
    _connecting = true;
    final p = peer.peripheral;
    var scanningPaused = false;
    try {
      // Android devices can return GATT status 133 when an active low-latency
      // scan competes with a connection and hundreds of ATT writes. Keep the
      // peripheral advertiser running so the other phone can still find us.
      if (running) {
        await central.stopDiscovery().timeout(const Duration(seconds: 3));
        scanningPaused = true;
      }
      await central.connect(p).timeout(const Duration(seconds: 10));
      final services = await central
          .discoverGATT(p)
          .timeout(const Duration(seconds: 10));
      final characteristics = services
          .firstWhere((s) => s.uuid == serviceId)
          .characteristics;
      final reliable = characteristics.any((c) => c.uuid == indexedRpcId);
      final characteristic = characteristics.firstWhere(
        (c) => c.uuid == (reliable ? indexedRpcId : rpcId),
      );
      var frameBytes = 20;
      if (reliable && Platform.isAndroid) {
        try {
          final mtu = await central
              .requestMTU(p, mtu: 185)
              .timeout(const Duration(seconds: 4));
          frameBytes = (mtu - 3).clamp(20, 180);
        } catch (_) {
          // Minimum-MTU operation remains correct on devices that refuse MTU negotiation.
        }
      }
      Future<Json> rpc(Json request) async {
        final wire = canonical(request);
        if (wire.length > maxRpcBytes) {
          throw const FormatException('RPC exceeds limit');
        }
        final transfer = Random.secure().nextInt(1 << 32);
        for (final f
            in reliable
                ? BleFrames.encode(wire, transfer, frameBytes: frameBytes)
                : frames(wire)) {
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
        final indexedAssembly = IndexedBleAssembly();
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (DateTime.now().isBefore(deadline)) {
          if (reliable) {
            await central
                .writeCharacteristic(
                  p,
                  characteristic,
                  value: BleFrames.select(transfer, indexedAssembly.nextIndex),
                  type: GATTCharacteristicWriteType.withResponse,
                )
                .timeout(const Duration(seconds: 5));
          }
          final f = await central
              .readCharacteristic(p, characteristic)
              .timeout(const Duration(seconds: 5));
          if (f.length == 1 && f[0] == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            continue;
          }
          if (reliable &&
              (f.length <= BleFrames.header ||
                  BleFrames.tag(f) != transfer ||
                  BleFrames.index(f) != indexedAssembly.nextIndex)) {
            // A cached/repeated ATT read is harmless: select the same cursor again.
            await Future<void>.delayed(const Duration(milliseconds: 30));
            continue;
          }
          final done = reliable ? indexedAssembly.add(f) : assembled.add(f);
          if (done != null) {
            return Map<String, dynamic>.from(jsonDecode(utf8.decode(done)));
          }
        }
        throw TimeoutException('Peer did not acknowledge stored packet');
      }

      return await run(rpc);
    } finally {
      try {
        await central.disconnect(p).timeout(const Duration(seconds: 3));
      } catch (_) {}
      if (scanningPaused && running) {
        try {
          await central.startDiscovery().timeout(const Duration(seconds: 6));
        } catch (error) {
          onEvent('Nearby scan could not resume: $error');
        }
      }
      _connecting = false;
    }
  }

  @override
  Future<void> stop() async {
    running = false;
    cleanup?.cancel();
    // Always detach handlers and close the GATT session even if Android never
    // acknowledges stopping discovery/advertising. A cleanup wait must not
    // leave the UI permanently disabled after a failed start.
    final cancellations = subscriptions.map((s) => s.cancel()).toList();
    subscriptions.clear();
    incoming.clear();
    outgoing.clear();
    touched.clear();
    processing.clear();
    indexed.clear();
    discovered.clear();
    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation().timeout(cleanupTimeout);
      } catch (_) {}
    }

    await Future.wait([
      attempt(central.stopDiscovery),
      attempt(peripheral.stopAdvertising),
      if (androidSession != null) attempt(androidSession!.close),
      for (final cancellation in cancellations) attempt(() => cancellation),
    ]);
  }
}
