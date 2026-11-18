import 'package:beyondnet/payment_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final code in [
    LocalAuthExceptionCode.noBiometricHardware,
    LocalAuthExceptionCode.noBiometricsEnrolled,
    LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable,
    LocalAuthExceptionCode.noCredentialsSet,
    LocalAuthExceptionCode.temporaryLockout,
    LocalAuthExceptionCode.biometricLockout,
  ]) {
    test(
      '$code uses system credentials and requires their successful result',
      () async {
        var called = 0;
        final auth = PaymentAuth(
          android: true,
          biometric: (_) async => throw LocalAuthException(code: code),
          credential: (reason) async {
            called++;
            expect(reason, 'Payment');
            return called == 1;
          },
        );
        expect(await auth.authenticate('Payment'), isTrue);
        expect(await auth.authenticate('Payment'), isFalse);
        expect(called, 2);
      },
    );
  }
  test('Successful biometrics do not open a second prompt', () async {
    final auth = PaymentAuth(
      android: true,
      biometric: (_) async => true,
      credential: (_) async => throw StateError('Unexpected fallback'),
    );
    expect(await auth.authenticate('Payment'), isTrue);
  });
  test('Cancellation does not trigger another authentication prompt', () async {
    final auth = PaymentAuth(
      android: true,
      biometric: (_) async => throw const LocalAuthException(
        code: LocalAuthExceptionCode.userCanceled,
      ),
      credential: (_) async => throw StateError('Unexpected fallback'),
    );
    expect(await auth.authenticate('Payment'), isFalse);
  });
  test(
    'No screen lock gives setup instructions and never authorizes',
    () async {
      final auth = PaymentAuth(
        android: true,
        biometric: (_) async => throw const LocalAuthException(
          code: LocalAuthExceptionCode.noBiometricHardware,
        ),
        credential: (_) async => throw PlatformException(code: 'noScreenLock'),
      );
      await expectLater(
        auth.authenticate('Payment'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Set a phone screen-lock'),
          ),
        ),
      );
    },
  );
  test('Interrupted system credential confirmation never authorizes', () async {
    final auth = PaymentAuth(
      android: true,
      biometric: (_) async => throw const LocalAuthException(
        code: LocalAuthExceptionCode.noBiometricHardware,
      ),
      credential: (_) async => throw PlatformException(code: 'authInterrupted'),
    );
    await expectLater(auth.authenticate('Payment'), throwsStateError);
  });
  test('Native channel null or cancel cannot be treated as success', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(PaymentAuth.channel, (call) async {
      expect(call.method, 'confirmDeviceCredential');
      return null;
    });
    final auth = PaymentAuth(
      android: true,
      biometric: (_) async => throw const LocalAuthException(
        code: LocalAuthExceptionCode.noBiometricHardware,
      ),
    );
    expect(await auth.authenticate('Payment'), isFalse);
    messenger.setMockMethodCallHandler(PaymentAuth.channel, null);
  });
}
