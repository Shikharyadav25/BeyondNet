import 'dart:async';
import 'dart:convert';
import 'package:beyondnet/android_ble_session.dart';
import 'package:beyondnet/background_relay.dart';
import 'package:beyondnet/ble_frames.dart';
import 'package:beyondnet/ble_transport.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCentral implements CentralManager {
  final events = StreamController<DiscoveredEventArgs>.broadcast();
  BluetoothLowEnergyState currentState = BluetoothLowEnergyState.poweredOn;
  int scans = 0, stops = 0;
  Future<void>? scanWait, stopWait;
  @override
  BluetoothLowEnergyState get state => currentState;
  @override
  Stream<DiscoveredEventArgs> get discovered => events.stream;
  @override
  Future<void> startDiscovery({List<UUID>? serviceUUIDs}) async {
    scans++;
    await scanWait;
  }

  @override
  Future<void> stopDiscovery() async {
    stops++;
    await stopWait;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakePeer implements Peripheral {
  @override
  final UUID uuid = UUID.fromString('12345678-1234-1234-1234-123456789abc');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeRemoteCentral implements Central {
  @override
  final uuid = UUID.fromString('22345678-1234-1234-1234-123456789abc');
}

class FakeWrite implements GATTWriteRequest {
  @override
  final Uint8List value;
  FakeWrite(this.value);
  @override
  int get offset => 0;
}

class FakeRead implements GATTReadRequest {
  @override
  int get offset => 0;
}

class FakePeripheral implements PeripheralManager {
  final writes =
      StreamController<GATTCharacteristicWriteRequestedEventArgs>.broadcast();
  final reads =
      StreamController<GATTCharacteristicReadRequestedEventArgs>.broadcast();
  BluetoothLowEnergyState currentState = BluetoothLowEnergyState.poweredOn;
  Advertisement? lastAdvertisement;
  int failedAdds = 0, adds = 0, advertisements = 0;
  int writeAcks = 0;
  int advertisementStops = 0;
  Future<void>? clearWait, addWait, advertiseWait, stopWait;
  bool failReadResponse = false;
  final responses = <Uint8List>[];
  @override
  Future<int> getMaximumNotifyLength(Central central) async => 180;
  @override
  Future<void> respondWriteRequest(GATTWriteRequest request) async {
    writeAcks++;
  }

  @override
  Future<void> respondReadRequestWithValue(
    GATTReadRequest request, {
    required Uint8List value,
  }) async {
    if (failReadResponse) throw StateError('Disconnected');
    responses.add(Uint8List.fromList(value));
  }

  @override
  BluetoothLowEnergyState get state => currentState;
  @override
  Stream<GATTCharacteristicWriteRequestedEventArgs>
  get characteristicWriteRequested => writes.stream;
  @override
  Stream<GATTCharacteristicReadRequestedEventArgs>
  get characteristicReadRequested => reads.stream;
  @override
  Future<void> removeAllServices() async {
    await clearWait;
  }

  @override
  Future<void> addService(GATTService service) async {
    adds++;
    await addWait;
    if (adds <= failedAdds) {
      throw PlatformException(code: 'IllegalStateException');
    }
  }

  @override
  Future<void> startAdvertising(Advertisement advertisement) async {
    lastAdvertisement = advertisement;
    advertisements++;
    await advertiseWait;
  }

  @override
  Future<void> stopAdvertising() async {
    advertisementStops++;
    await stopWait;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const close = BasicMessageChannel<Object?>(
    '${AndroidBleSession.prefix}closeGATTServer',
    StandardMessageCodec(),
  );
  const open = BasicMessageChannel<Object?>(
    '${AndroidBleSession.prefix}openGATTServer',
    StandardMessageCodec(),
  );
  late FakeCentral central;
  late FakePeripheral peripheral;
  late BleTransport radio;
  final calls = <String>[];
  setUp(() {
    calls.clear();
    central = FakeCentral();
    peripheral = FakePeripheral();
    radio = BleTransport(
      (_) async => {},
      (_) {},
      central: central,
      peripheral: peripheral,
      androidSession: AndroidBleSession(),
    );
    messenger.setMockDecodedMessageHandler<Object?>(close, (_) async {
      calls.add('close');
      return [null];
    });
    messenger.setMockDecodedMessageHandler<Object?>(open, (_) async {
      calls.add('open');
      return [null];
    });
  });
  tearDown(() async {
    await radio.stop();
    await central.events.close();
    await peripheral.writes.close();
    await peripheral.reads.close();
    messenger.setMockDecodedMessageHandler<Object?>(open, null);
    messenger.setMockDecodedMessageHandler<Object?>(close, null);
  });
  test(
    'Closed Android GATT session reopens before registration, then scans',
    () async {
      await radio.start();
      expect(calls.take(2), ['close', 'open']);
      expect(radio.running, isTrue);
      expect(central.scans, 1);
      expect(peripheral.advertisements, 1);
      expect(
        peripheral.lastAdvertisement?.name,
        isNull,
        reason: "Startup must not depend on renaming the Android phone",
      );
      expect(peripheral.lastAdvertisement?.serviceUUIDs, isNotEmpty);
    },
  );
  test(
    'Broad scan retains a BeyondNet peer even when its service UUID is omitted',
    () async {
      await radio.start();
      final peer = FakePeer();
      central.events.add(
        DiscoveredEventArgs(peer, -57, Advertisement(name: 'BeyondNet')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(radio.discovered[peer.uuid.toString()]?.rssi, -57);
      central.events.add(
        DiscoveredEventArgs(
          FakePeer(),
          -31,
          Advertisement(name: 'Unrelated device'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(radio.discovered[peer.uuid.toString()]?.rssi, -57);
    },
  );
  test('Refused GATT registration retries with a fresh server', () async {
    peripheral.failedAdds = 1;
    await radio.start();
    expect(peripheral.adds, 2);
    expect(calls.where((c) => c == 'open').length, 2);
    expect(peripheral.writes.hasListener, isTrue);
    expect(radio.running, isTrue);
  });
  test(
    'Persistent registration failure cleans all state, exposes useful message and allows retry',
    () async {
      peripheral.failedAdds = 3;
      await expectLater(
        radio.start(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Turn Bluetooth off and on'),
          ),
        ),
      );
      expect(peripheral.adds, 3);
      expect(radio.running, isFalse);
      expect(peripheral.writes.hasListener, isFalse);
      expect(peripheral.reads.hasListener, isFalse);
      expect(radio.subscriptions, isEmpty);
      expect(central.scans, 0);
      peripheral.failedAdds = 0;
      await radio.start();
      expect(radio.running, isTrue);
    },
  );
  test(
    'Native session API errors propagate rather than marking relay active',
    () async {
      messenger.setMockDecodedMessageHandler<Object?>(
        open,
        (_) async => ['IllegalStateException', 'Gatt unavailable', null],
      );
      await expectLater(
        AndroidBleSession().reopen(),
        throwsA(isA<PlatformException>()),
      );
    },
  );
  for (final method in ['ready', 'start', 'stop']) {
    testWidgets('Unanswered native relay $method has a deadline', (
      tester,
    ) async {
      messenger.setMockMethodCallHandler(
        BackgroundRelay.channel,
        (_) => Completer<Object?>().future,
      );
      try {
        final background = BackgroundRelay();
        final Future<Object?> operation = switch (method) {
          'ready' => background.ready(),
          'start' => background.start(),
          _ => background.stop(),
        };
        final result = expectLater(operation, throwsA(isA<TimeoutException>()));
        await tester.pump(BackgroundRelay.responseTimeout);
        await result;
      } finally {
        messenger.setMockMethodCallHandler(BackgroundRelay.channel, null);
      }
    });
  }
  for (final stage in ['clear services', 'register', 'advertise', 'discover']) {
    test(
      'Missing $stage callback releases startup and permits retry',
      () async {
        final pending = Completer<void>();
        switch (stage) {
          case 'clear services':
            peripheral.clearWait = pending.future;
          case 'register':
            peripheral.addWait = pending.future;
          case 'advertise':
            peripheral.advertiseWait = pending.future;
          case 'discover':
            central.scanWait = pending.future;
        }
        radio = BleTransport(
          (_) async => {},
          (_) {},
          central: central,
          peripheral: peripheral,
          androidSession: AndroidBleSession(),
          operationTimeout: const Duration(milliseconds: 30),
        );
        await expectLater(
          radio.start().timeout(const Duration(seconds: 2)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Bluetooth timed out while'),
            ),
          ),
        );
        expect(radio.running, isFalse);
        expect(radio.subscriptions, isEmpty);
        expect(peripheral.writes.hasListener, isFalse);
        expect(peripheral.advertisementStops, greaterThan(0));
        final scans = central.scans;
        // A late native reply must not resume the abandoned Dart startup.
        pending.complete();
        await Future<void>.delayed(Duration.zero);
        expect(radio.running, isFalse);
        expect(central.scans, scans);
        await radio.start();
        expect(radio.running, isTrue);
      },
    );
  }
  test(
    'Unanswered stop callbacks still close GATT and detach handlers',
    () async {
      radio = BleTransport(
        (_) async => {},
        (_) {},
        central: central,
        peripheral: peripheral,
        androidSession: AndroidBleSession(),
        cleanupTimeout: const Duration(milliseconds: 30),
      );
      await radio.start();
      central.stopWait = Completer<void>().future;
      peripheral.stopWait = Completer<void>().future;
      final closes = calls.where((c) => c == 'close').length;
      await radio.stop().timeout(const Duration(seconds: 1));
      expect(radio.running, isFalse);
      expect(radio.subscriptions, isEmpty);
      expect(peripheral.writes.hasListener, isFalse);
      expect(calls.where((c) => c == 'close').length, closes + 1);
    },
  );
  test(
    'Unsupported BLE advertising fails without opening or starting radio',
    () async {
      peripheral.currentState = BluetoothLowEnergyState.unsupported;
      await expectLater(
        radio.start(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('does not support'),
          ),
        ),
      );
      expect(radio.running, isFalse);
      expect(calls, isEmpty);
    },
  );
  test(
    'indexed GATT handler tolerates repeated reads and final writes',
    () async {
      var executions = 0;
      radio = BleTransport(
        (request) async {
          executions++;
          return {'reply': List.filled(400, 'x').join()};
        },
        (_) {},
        central: central,
        peripheral: peripheral,
        androidSession: AndroidBleSession(),
      );
      await radio.start();
      final remote = FakeRemoteCentral();
      final characteristic = GATTCharacteristic.mutable(
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
      );
      Future<void> write(Uint8List bytes) async {
        peripheral.writes.add(
          GATTCharacteristicWriteRequestedEventArgs(
            remote,
            characteristic,
            FakeWrite(bytes),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      Future<Uint8List> read() async {
        peripheral.reads.add(
          GATTCharacteristicReadRequestedEventArgs(
            remote,
            characteristic,
            FakeRead(),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return peripheral.responses.last;
      }

      final request = BleFrames.encode(
        utf8.encode('{"command":"inventory"}'),
        42,
      );
      for (final part in request) {
        await write(part);
      }
      await write(request.last);
      expect(executions, 1);
      await write(BleFrames.select(42, 0));
      final first = await read();
      expect(await read(), first);
      await write(BleFrames.select(42, 1));
      expect(BleFrames.index(await read()), 1);
      // A new transfer cannot accidentally expose the previous response.
      final next = BleFrames.encode(utf8.encode('{"command":"inventory"}'), 43);
      await write(next.first);
      expect(await read(), [0]);
      expect(executions, 1);
    },
  );
  test('Campus cannot replace an active Payments Bluetooth service', () async {
    await radio.start();
    final other = BleTransport(
      (_) async => {},
      (_) {},
      campus: true,
      central: central,
      peripheral: peripheral,
    );
    final adds = peripheral.adds;
    await expectLater(other.start(), throwsStateError);
    await other.stop();
    expect(radio.running, isTrue);
    expect(peripheral.adds, adds);
  });
  test(
    'read invalidated by disconnect does not escape the stream handler',
    () async {
      await radio.start();
      peripheral.failReadResponse = true;
      peripheral.reads.add(
        GATTCharacteristicReadRequestedEventArgs(
          FakeRemoteCentral(),
          GATTCharacteristic.mutable(
            uuid: rpcId,
            properties: [GATTCharacteristicProperty.read],
            permissions: [GATTCharacteristicPermission.read],
            descriptors: [],
          ),
          FakeRead(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(radio.running, isTrue);
    },
  );
}
