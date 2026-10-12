import 'dart:async';
import 'package:beyondnet/android_ble_session.dart';
import 'package:beyondnet/ble_transport.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCentral implements CentralManager {
  final events = StreamController<DiscoveredEventArgs>.broadcast();
  BluetoothLowEnergyState currentState = BluetoothLowEnergyState.poweredOn;
  int scans = 0, stops = 0;
  @override
  BluetoothLowEnergyState get state => currentState;
  @override
  Stream<DiscoveredEventArgs> get discovered => events.stream;
  @override
  Future<void> startDiscovery({List<UUID>? serviceUUIDs}) async {
    scans++;
  }

  @override
  Future<void> stopDiscovery() async {
    stops++;
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

class FakePeripheral implements PeripheralManager {
  final writes =
      StreamController<GATTCharacteristicWriteRequestedEventArgs>.broadcast();
  final reads =
      StreamController<GATTCharacteristicReadRequestedEventArgs>.broadcast();
  BluetoothLowEnergyState currentState = BluetoothLowEnergyState.poweredOn;
  int failedAdds = 0, adds = 0, advertisements = 0;
  @override
  BluetoothLowEnergyState get state => currentState;
  @override
  Stream<GATTCharacteristicWriteRequestedEventArgs>
  get characteristicWriteRequested => writes.stream;
  @override
  Stream<GATTCharacteristicReadRequestedEventArgs>
  get characteristicReadRequested => reads.stream;
  @override
  Future<void> removeAllServices() async {}
  @override
  Future<void> addService(GATTService service) async {
    adds++;
    if (adds <= failedAdds) {
      throw PlatformException(code: 'IllegalStateException');
    }
  }

  @override
  Future<void> startAdvertising(Advertisement advertisement) async {
    advertisements++;
  }

  @override
  Future<void> stopAdvertising() async {}
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
}
