import 'protocol.dart';

/// Routing hints are outside the signed financial authorization. They can help
/// delivery but never authorize money or prove that a payment was processed.
class RelayRouting {
  static const maxHops = 4;
  static const offlineFanout = 3;
  static const custodyWindowSeconds = 90;

  static bool canForward(Json packet, String from, String to) {
    if (from == to ||
        packet['expires_at'] <= nowSeconds ||
        packet['hops'] >= maxHops) {
      return false;
    }
    final trail = (packet['trail'] as List? ?? const []).cast<String>();
    if (trail.contains(to) || trail.contains(from)) return false;
    return packet['kind'] != 'payment' ||
        !(packet['path'] as List).contains(to);
  }

  static Json forward(Json packet, String from) {
    final path = (packet['path'] as List).cast<String>().toList();
    final trail = (packet['trail'] as List? ?? const [])
        .cast<String>()
        .toList();
    if (!trail.contains(from)) trail.add(from);
    if (packet['kind'] == 'payment' && !path.contains(from)) path.add(from);
    final clean = Map<String, dynamic>.from(packet)..remove('uploaded');
    return {...clean, 'hops': packet['hops'] + 1, 'path': path, 'trail': trail};
  }

  static bool improves(Json packet, int? remoteHops) =>
      remoteHops != null && packet['hops'] + 1 < remoteHops;

  static int priority(Json packet, String peer) => packet['kind'] == 'receipt'
      ? ((packet['path'] as List).contains(peer) ? 0 : 1)
      : 2;

  /// Return-path receipts are sorted first within their lane. Interleaving
  /// lanes prevents a receipt backlog from starving new payment requests.
  static List<Json> fairOrder(List<Json> ordered) {
    final receipts = ordered.where((p) => p['kind'] == 'receipt').toList();
    final payments = ordered.where((p) => p['kind'] != 'receipt').toList();
    return [
      for (var i = 0; i < receipts.length || i < payments.length; i++) ...[
        if (i < receipts.length) receipts[i],
        if (i < payments.length) payments[i],
      ],
    ];
  }
}
