import 'package:beyondnet/nearby_permissions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  int? sdk;
  var granted = true;
  var locationEnabled = true;
  var incompleteResponse = false;
  final calls = <MethodCall>[];

  setUp(() {
    sdk = 29;
    granted = true;
    locationEnabled = true;
    incompleteResponse = false;
    calls.clear();
    messenger.setMockMethodCallHandler(NearbyPermissions.platform, (
      call,
    ) async {
      expect(call.method, 'androidSdkVersion');
      return sdk;
    });
    messenger.setMockMethodCallHandler(permissions, (call) async {
      calls.add(call);
      if (call.method == 'requestPermissions') {
        final requested = List<int>.from(call.arguments as List);
        return <int, int>{
          for (final id in requested.take(
            incompleteResponse ? requested.length - 1 : requested.length,
          ))
            id: granted ? 1 : 4,
        };
      }
      if (call.method == 'checkServiceStatus') {
        return locationEnabled ? 1 : 0;
      }
      throw StateError('Unexpected permission operation: ${call.method}');
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(NearbyPermissions.platform, null);
    messenger.setMockMethodCallHandler(permissions, null);
  });

  for (final version in [29, 30]) {
    test(
      'Android API $version grants foreground location before BLE',
      () async {
        sdk = version;
        await NearbyPermissions.ensureAndroidReady();
        expect(calls.map((c) => c.method), [
          'requestPermissions',
          'checkServiceStatus',
        ]);
        expect(calls.first.arguments, [Permission.locationWhenInUse.value]);
        expect(calls.last.arguments, Permission.locationWhenInUse.value);
      },
    );
  }

  test('Android 10 location denial blocks relay and explains permission', () {
    granted = false;
    return expectLater(
      NearbyPermissions.ensureAndroidReady(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Location permission'),
        ),
      ),
    );
  });

  test('Android 10 permission granted but Location off blocks scanning', () {
    locationEnabled = false;
    return expectLater(
      NearbyPermissions.ensureAndroidReady(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Turn Location on'),
        ),
      ),
    );
  });

  test('Android 12+ requests Nearby devices without Location access', () async {
    sdk = 31;
    await NearbyPermissions.ensureAndroidReady();
    expect(calls, hasLength(1));
    expect(calls.single.arguments, [
      Permission.bluetoothScan.value,
      Permission.bluetoothConnect.value,
      Permission.bluetoothAdvertise.value,
    ]);
  });

  test(
    'Android 12+ denied or incomplete permission grant blocks relay',
    () async {
      sdk = 36;
      granted = false;
      await expectLater(
        NearbyPermissions.ensureAndroidReady(),
        throwsA(isA<StateError>()),
      );
      granted = true;
      incompleteResponse = true;
      await expectLater(
        NearbyPermissions.ensureAndroidReady(),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'Unknown or unsupported Android version never starts permissions',
    () async {
      for (final version in [null, 28]) {
        sdk = version;
        await expectLater(
          NearbyPermissions.ensureAndroidReady(),
          throwsA(isA<StateError>()),
        );
      }
      expect(calls, isEmpty);
    },
  );
}
