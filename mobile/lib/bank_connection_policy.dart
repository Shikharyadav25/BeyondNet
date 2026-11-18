import 'dart:async';
import 'dart:io';

/// Delivery timing never changes financial authorization or receipt validity.
class BankConnectionPolicy {
  static const healthFreshness = Duration(seconds: 30);
  static const socketConnect = Duration(seconds: 20);
  static const heartbeat = Duration(seconds: 45);
  static const submit = Duration(seconds: 45);
  // Switch transport promptly if a live socket silently stalls. HTTPS retains
  // its longer weak-network deadline and resubmits the exact original packet.
  static const liveSubmitFallback = Duration(seconds: 6);
  static Duration timeout(String path) {
    if (path == '/api/packets') return submit;
    if (path == '/api/health') return const Duration(seconds: 10);
    if (path == '/api/me') return const Duration(seconds: 10);
    return const Duration(seconds: 30);
  }

  static Duration retry(int failures) =>
      Duration(seconds: [5, 10, 20, 40, 60][(failures - 1).clamp(0, 4)]);
  static bool transportError(Object error) =>
      error is TimeoutException ||
      error is SocketException ||
      error is HttpException;
}
