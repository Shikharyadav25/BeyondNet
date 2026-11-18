import 'dart:io';

import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Keep device-owner confirmation mandatory when an Android biometric prompt
/// cannot offer its advertised PIN/pattern fallback (notably on older devices).
class PaymentAuth {
  static const channel = MethodChannel('beyondnet/payment_auth');
  final Future<bool> Function(String) biometric;
  final Future<bool> Function(String) credential;
  final bool android;
  PaymentAuth({
    Future<bool> Function(String)? biometric,
    Future<bool> Function(String)? credential,
    bool? android,
  }) : biometric =
           biometric ??
           ((reason) => LocalAuthentication().authenticate(
             localizedReason: reason,
             biometricOnly: false,
             persistAcrossBackgrounding: true,
           )),
       credential =
           credential ??
           ((reason) async =>
               await channel.invokeMethod<bool>('confirmDeviceCredential', {
                 'reason': reason,
               }) ==
               true),
       android = android ?? Platform.isAndroid;

  Future<bool> authenticate(String reason) async {
    try {
      return await biometric(reason);
    } on LocalAuthException catch (error) {
      if (android &&
          const {
            LocalAuthExceptionCode.noBiometricHardware,
            LocalAuthExceptionCode.noBiometricsEnrolled,
            LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable,
            LocalAuthExceptionCode.noCredentialsSet,
            LocalAuthExceptionCode.temporaryLockout,
            LocalAuthExceptionCode.biometricLockout,
            LocalAuthExceptionCode.userRequestedFallback,
          }.contains(error.code)) {
        return _confirmCredential(reason);
      }
      if (error.code == LocalAuthExceptionCode.userCanceled ||
          error.code == LocalAuthExceptionCode.systemCanceled ||
          error.code == LocalAuthExceptionCode.timeout) {
        return false;
      }
      throw StateError(
        'Phone authentication could not open. Unlock your phone and try again.',
      );
    }
  }

  Future<bool> _confirmCredential(String reason) async {
    try {
      return await credential(reason);
    } on PlatformException catch (error) {
      if (error.code == 'noScreenLock') {
        throw StateError(
          'Set a phone screen-lock PIN, pattern or password in Android Settings, then try again. Fingerprint is optional.',
        );
      }
      throw StateError(
        'Phone screen-lock confirmation could not finish. Unlock your phone and try again.',
      );
    } on MissingPluginException {
      throw StateError(
        'Restart BeyondNet to enable phone screen-lock confirmation, then try again.',
      );
    }
  }
}
