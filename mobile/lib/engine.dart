import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:local_auth/local_auth.dart';
import 'package:uuid/uuid.dart';
import 'protocol.dart';
import 'store.dart';
import 'ble_transport.dart';
import 'relay_routing.dart';
import 'background_relay.dart';

class BankFailure implements Exception {
  final int status;
  final String message;
  BankFailure(this.status, this.message);
  @override
  String toString() => message;
}

class BeyondNetEngine extends ChangeNotifier {
  final LocalStore store = LocalStore();
  final FlutterSecureStorage secure = const FlutterSecureStorage();
  final http.Client httpClient;
  final Future<bool> Function()? authorizePayment;
  final Future<WebSocket> Function(String)? socketConnector;
  final BackgroundRelay? background;
  BeyondNetEngine({
    http.Client? client,
    this.authorizePayment,
    this.socketConnector,
    PeerTransport? transport,
    BackgroundRelay? backgroundRelay,
  }) : httpClient = client ?? http.Client(),
       _radio = transport,
       background =
           backgroundRelay ?? (Platform.isAndroid ? BackgroundRelay() : null);
  final LocalAuthentication auth = LocalAuthentication();
  late SimpleKeyPair signing, encryption;
  PeerTransport? _radio;
  PeerTransport get radio => _radio ??= BleTransport(handleRpc, (s) {
    unawaited(log(s));
  });
  Json? profile;
  Json? get account => profile?['account'] == null
      ? null
      : Map<String, dynamic>.from(profile!['account']);
  Json get trust => Map<String, dynamic>.from(profile!['trust']);
  Json get certificate => Map<String, dynamic>.from(profile!['certificate']);
  String get deviceId => profile!['device_id'];
  String get accountId => account!['id'];
  String get bankUrl => profile!['bank_url'];
  List<Json> merchants = [];
  List<Json> payments = [], receipts = [], events = [];
  List<Json> nearby = [];
  List<String> allowlist = [];
  int queueSize = 0;
  bool gateway = false, relay = false, working = false, ready = false;
  bool relayEnabled = false, backgroundActive = false;
  String? relayBlocked;
  bool _relayTransition = false;
  String network = 'Checking connection…';
  bool? internet;
  bool bankReachable = false, checkingConnection = false;
  bool get isMerchant => account?['role'] == 'merchant';
  bool get pinConfigured => account?['pin_configured'] == true;
  String? connectedPeer;
  bool get canPay =>
      bankReachable ||
      (relay &&
          connectedPeer != null &&
          nearby.any(
            (p) =>
                p['device_id'] == connectedPeer && p['at'] >= nowSeconds - 90,
          ));
  bool get liveConnected => _socket != null && _liveReady;
  WebSocket? _socket;
  bool _liveReady = false, _openingSocket = false, _disposed = false;
  final Map<String, Completer<Json>> _pending = {};
  DateTime _nextSocketAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastProfileRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  int _inboxCursor = 0;
  Timer? connectionTimer;
  static const platform = MethodChannel('beyondnet/network');
  String? lastError;
  Timer? timer;
  int backoffSeconds = 5;
  DateTime nextBankAttempt = DateTime.now();
  final Map<String, int> seenRpc = {};
  final Map<String, DateTime> peerRetry = {};
  final Map<String, int> peerFailures = {};
  final Map<String, String> identityByRadio = {};
  final Map<String, int> _offeredPackets = {};
  final Random _jitter = Random();
  int _peerRound = 0;
  Future<void> init({String? databasePath}) async {
    await store.init(databasePath: databasePath);
    final saved = await secure.read(key: 'profile');
    if (saved != null) {
      profile = Map<String, dynamic>.from(jsonDecode(saved));
      await loadKeys();
      merchants = (profile!['merchants'] as List? ?? [])
          .map((x) => Map<String, dynamic>.from(x))
          .toList();
      allowlist = (await store.config('allowlist') as List? ?? [])
          .cast<String>();
    }
    if (profile != null) {
      for (final p in await store.packets(activeOnly: false)) {
        if (p['kind'] == 'receipt') {
          try {
            await deliverReceipt(p);
          } catch (_) {
            await store.event('Ignored an unverifiable cached receipt.');
          }
        }
      }
    }
    await reload();
    ready = true;
    background?.listen(restoreBackgroundRelay);
    await restoreBackgroundRelay();
    if (profile != null) startMonitoring();
    notifyListeners();
  }

  Future<void> loadKeys() async {
    final raw = await secure.read(key: 'device_keys');
    if (raw == null) {
      throw StateError(
        'Device keys are missing. Preserve this installation and restore its keys before using pending payments.',
      );
    }
    final keys = jsonDecode(raw);
    signing = await ed.newKeyPairFromSeed(base64Decode(keys['sign']));
    encryption = await x.newKeyPairFromSeed(base64Decode(keys['box']));
  }

  Future<Json> request(
    String path, {
    Json? body,
    String? url,
    String? token,
  }) async {
    final base = url ?? bankUrl;
    final authToken = token ?? (url == null ? (profile?['token']) : null);
    final headers = {
      'Content-Type': 'application/json',
      if (authToken != null) 'Authorization': 'Bearer $authToken',
    };
    final uri = Uri.parse('$base$path');
    final response =
        await (body == null
                ? httpClient.get(uri, headers: headers)
                : httpClient.post(
                    uri,
                    headers: headers,
                    body: jsonEncode(body),
                  ))
            .timeout(const Duration(seconds: 12));
    Json data;
    try {
      data = Map<String, dynamic>.from(jsonDecode(response.body));
    } catch (_) {
      throw BankFailure(
        response.statusCode,
        'The bank returned an unexpected response. Check its URL and try again.',
      );
    }
    if (response.statusCode >= 400) {
      throw BankFailure(
        response.statusCode,
        data['detail']?.toString() ?? 'Bank request failed',
      );
    }
    return data;
  }

  Future<void> enroll(
    String url,
    String id,
    String password,
    String fingerprint, {
    String? name,
    String? role,
  }) async {
    final parsed = Uri.tryParse(url.trim());
    if (parsed == null ||
        parsed.scheme != 'https' ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment ||
        (parsed.path.isNotEmpty && parsed.path != '/')) {
      throw ArgumentError(
        'Enter the bank HTTPS origin, for example https://your-bank.example',
      );
    }
    final base = url.trim().replaceAll(RegExp(r'/+$'), '');
    final health = await request('/api/health', url: base);
    final t = {
      for (final k in ['sign_key', 'box_key', 'mesh_id', 'fingerprint'])
        k: health[k],
    };
    final actual = await digest({
      for (final k in ['sign_key', 'box_key', 'mesh_id']) k: t[k],
    });
    final expected = fingerprint.toLowerCase().replaceAll(RegExp(r'\s'), '');
    if (expected.length != 64 ||
        t['fingerprint'] != actual ||
        actual != expected) {
      throw StateError(
        'Bank fingerprint does not match the laptop. Check the URL and fingerprint.',
      );
    }
    final result = await request(
      name == null ? '/api/login' : '/api/signup',
      url: base,
      body: {
        'account': id.trim().toLowerCase(),
        'password': password,
        if (name != null) 'name': name.trim(),
        if (name != null) 'role': role,
      },
    );
    if (result['trust']['fingerprint'] != actual) {
      throw StateError(
        'Bank trust changed during enrollment. Retry after checking the laptop.',
      );
    }
    if (profile != null &&
        (profile!['account']['id'] != result['account']['id'] ||
            trust['fingerprint'] != actual)) {
      throw StateError(
        'This installation belongs to another account or bank. Use a separate installation; preserve pending payments.',
      );
    }
    if (await secure.read(key: 'device_keys') == null) {
      final sk = await ed.newKeyPair();
      final bk = await x.newKeyPair();
      await secure.write(
        key: 'device_keys',
        value: jsonEncode({
          'id': const Uuid().v4(),
          'sign': base64Encode(await sk.extractPrivateKeyBytes()),
          'box': base64Encode(await bk.extractPrivateKeyBytes()),
        }),
      );
    }
    await loadKeys();
    final did = jsonDecode((await secure.read(key: 'device_keys'))!)['id'];
    final aid = result['account']['id'];
    final identity = {
      'device_id': did,
      'account_id': aid,
      'sign_key': base64Encode((await signing.extractPublicKey()).bytes),
      'box_key': base64Encode((await encryption.extractPublicKey()).bytes),
    };
    final registered = await request(
      '/api/devices',
      url: base,
      token: result['token'],
      body: {
        for (final k in ['device_id', 'sign_key', 'box_key']) k: identity[k],
        'proof': (await sign(signing, {
          'device_id': did,
          'account_id': aid,
          'sign_key': identity['sign_key'],
          'box_key': identity['box_key'],
        }))['signature'],
      },
    );
    await verify(
      t['sign_key'],
      Map<String, dynamic>.from(registered['certificate']),
    );
    profile = {
      'account': result['account'],
      'token': result['token'],
      'session_expires_at': result['session_expires_at'],
      'trust': t,
      'device_id': did,
      'certificate': registered['certificate'],
      'bank_url': base,
      'merchants': registered['merchants'],
      'balance_checked_at': nowSeconds,
    };
    merchants = (registered['merchants'] as List)
        .map((x) => Map<String, dynamic>.from(x))
        .toList();
    await saveProfile();
    startMonitoring();
    await log('Account enrolled and bank trust verified.');
    await reload();
    notifyListeners();
  }

  Future<void> saveProfile() =>
      secure.write(key: 'profile', value: jsonEncode(profile));
  Future<void> refreshProfile() async {
    final result = await request('/api/me');
    applyAccount(Map<String, dynamic>.from(result['account']));
    profile!['balance_checked_at'] = nowSeconds;
    merchants = <String, Json>{
      for (final cert in merchants.where(
        (c) => c['body']['expires_at'] > nowSeconds,
      ))
        cert['body']['account_id']: cert,
      for (final value in result['merchants'])
        value['body']['account_id']: Map<String, dynamic>.from(value),
    }.values.toList();
    profile!['merchants'] = merchants;
    await saveProfile();
    await log('Balance and verified recipient directory refreshed online.');
  }

  void applyAccount(Json value) {
    if (value['id'] != accountId) {
      throw StateError('Bank returned another account');
    }
    if ((value['revision'] as int? ?? 0) >=
        (account!['revision'] as int? ?? 0)) {
      profile!['account'] = value;
      profile!['balance_checked_at'] = nowSeconds;
    }
  }

  void startMonitoring() {
    connectionTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(checkConnection());
    });
    timer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(tick());
    });
    unawaited(checkConnection());
  }

  Future<void> checkConnection() async {
    if (profile == null || checkingConnection || _disposed) return;
    checkingConnection = true;
    try {
      try {
        internet = await platform.invokeMethod<bool>('hasInternet');
      } on MissingPluginException {
        internet = null;
      }
      if (internet == false) {
        throw const SocketException('No internet connection');
      }
      final health = await request('/api/health');
      if (health['fingerprint'] != trust['fingerprint']) {
        throw StateError(
          'Bank identity changed. Verify the bank fingerprint before continuing.',
        );
      }
      internet = true;
      bankReachable = health['online'] == true;
      network = bankReachable ? 'Connected to bank' : 'Bank is paused';
      if (bankReachable) {
        await openLive();
        if (DateTime.now().difference(_lastProfileRefresh).inSeconds >= 30) {
          await refreshProfile();
          _lastProfileRefresh = DateTime.now();
        }
        nextBankAttempt = DateTime.now();
        unawaited(tick());
      }
    } catch (error) {
      bankReachable = false;
      network = internet == false
          ? 'Internet is off'
          : error is BankFailure && error.status == 401
          ? 'Sign in again to renew access'
          : 'Bank unavailable · nearby payments available';
      if (error is StateError) network = error.message.toString();
      closeLive();
    } finally {
      checkingConnection = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> openLive() async {
    if (_socket != null ||
        _openingSocket ||
        DateTime.now().isBefore(_nextSocketAttempt)) {
      return;
    }
    _openingSocket = true;
    try {
      final uri = Uri.parse('$bankUrl/api/live').replace(scheme: 'wss');
      final socket = await (socketConnector ?? WebSocket.connect)(
        uri.toString(),
      ).timeout(const Duration(seconds: 8));
      if (_disposed) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 15);
      socket.add(
        jsonEncode({'token': profile!['token'], 'device_id': deviceId}),
      );
      unawaited(readLive(socket));
    } catch (_) {
      _nextSocketAttempt = DateTime.now().add(const Duration(seconds: 15));
    } finally {
      _openingSocket = false;
    }
  }

  Future<void> readLive(WebSocket socket) async {
    try {
      await for (final raw in socket) {
        if (_disposed || socket != _socket) break;
        final data = Map<String, dynamic>.from(jsonDecode(raw as String));
        switch (data['type']) {
          case 'ready':
            if (data['fingerprint'] != trust['fingerprint']) {
              throw StateError('Live bank identity mismatch');
            }
            _liveReady = true;
            break;
          case 'account':
            if (!_liveReady) throw StateError('Live session not verified');
            applyAccount(Map<String, dynamic>.from(data['account']));
            await saveProfile();
            break;
          case 'receipts':
            if (!_liveReady) throw StateError('Live session not verified');
            for (final p in data['receipts']) {
              await accept(Map<String, dynamic>.from(p));
            }
            await reload();
            break;
          case 'result':
            _pending.remove(data['id'])?.complete(data);
            break;
          case 'error':
            _pending
                .remove(data['id'])
                ?.completeError(BankFailure(data['status'], data['message']));
            break;
        }
        if (!_disposed) notifyListeners();
      }
    } catch (_) {
      // The original packet remains durable. HTTP recovery uses the same payment ID.
    } finally {
      if (socket == _socket) closeLive();
    }
  }

  void closeLive() {
    final socket = _socket;
    _socket = null;
    _liveReady = false;
    if (socket != null) unawaited(socket.close());
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('Live connection interrupted'));
      }
    }
    _pending.clear();
    _nextSocketAttempt = DateTime.now().add(const Duration(seconds: 10));
  }

  Future<Json> submitPacket(Json packet) async {
    if (liveConnected) {
      final id = const Uuid().v4();
      final completion = Completer<Json>();
      _pending[id] = completion;
      try {
        _socket!.add(
          jsonEncode({'type': 'submit', 'id': id, 'packet': packet}),
        );
        return await completion.future.timeout(const Duration(seconds: 12));
      } on BankFailure {
        rethrow;
      } catch (_) {
        closeLive();
      } finally {
        _pending.remove(id);
      }
    }
    return request('/api/packets', body: packet);
  }

  bool addingMoney = false;
  Future<void> addDemoMoney(int amount) async {
    if (addingMoney) return;
    if (!bankReachable) {
      throw StateError('Connect to the bank online to add demo money.');
    }
    if (amount < 100 || amount > 1000000) {
      throw ArgumentError('Add ₹1 to ₹10,000.');
    }
    addingMoney = true;
    try {
      final saved = await store.config('pending_topup');
      final pending = saved == null
          ? {'request_id': const Uuid().v4(), 'amount': amount}
          : Map<String, dynamic>.from(saved);
      // Preserve the request ID after response loss or restart so retries cannot credit twice.
      await store.saveConfig('pending_topup', pending);
      final result = await request('/api/topups', body: pending);
      applyAccount(Map<String, dynamic>.from(result['account']));
      await saveProfile();
      await store.db.delete(
        'config',
        where: 'key=?',
        whereArgs: ['pending_topup'],
      );
      await log(
        'Demo money added: ₹${(pending['amount'] / 100).toStringAsFixed(2)}.',
      );
    } on BankFailure catch (e) {
      if (e.status == 400 || e.status == 409 || e.status == 422) {
        await store.db.delete(
          'config',
          where: 'key=?',
          whereArgs: ['pending_topup'],
        );
      }
      rethrow;
    } finally {
      addingMoney = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<Json> findRecipient(String id) async {
    final target = id.trim().toLowerCase();
    if (bankReachable) {
      final result = await request(
        '/api/recipients/${Uri.encodeComponent(target)}',
      );
      final cert = Map<String, dynamic>.from(result['certificate']);
      if (cert['body']['account_id'] != target) {
        throw StateError('Recipient ID does not match the requested account.');
      }
      await addRecipient(cert);
      return cert;
    }
    for (final cert in merchants) {
      if (cert['body']['account_id'] == target &&
          cert['body']['expires_at'] > nowSeconds) {
        return cert;
      }
    }
    if (connectedPeer != null && !working && relay) {
      final radioId = identityByRadio.entries
          .where((x) => x.value == connectedPeer)
          .firstOrNull
          ?.key;
      final peer = radioId == null ? null : radio.discovered[radioId];
      if (peer != null) {
        working = true;
        try {
          final cert = await radio.connect<Json?>(peer, (raw) async {
            final id = const Uuid().v4();
            final answer = await validateRpc(
              await raw(
                await signedRpc({'op': 'resolve', 'account_id': target}, id),
              ),
              expectedRequest: id,
            );
            final result = answer['command']['certificate'];
            return result == null ? null : Map<String, dynamic>.from(result);
          });
          if (cert != null) {
            if (cert['body']['account_id'] != target) {
              throw StateError(
                'Relay returned a different recipient. Scan the intended recipient QR.',
              );
            }
            await addRecipient(cert);
            return cert;
          }
        } finally {
          working = false;
        }
      }
    }
    throw StateError(
      'This ID is not saved or available through your relay. Scan their BeyondNet QR to verify them offline.',
    );
  }

  Future<void> connectNearby(String id) async {
    if (!relay) throw StateError('Enable nearby payments first.');
    final p = nearby
        .where((p) => p['device_id'] == id && p['at'] >= nowSeconds - 90)
        .firstOrNull;
    if (p == null) {
      throw StateError('This phone is no longer in range. Scan again.');
    }
    final radioId = identityByRadio.entries
        .where((x) => x.value == id)
        .firstOrNull
        ?.key;
    final peer = radioId == null ? null : radio.discovered[radioId];
    if (peer == null) {
      throw StateError('Phone left Bluetooth range. Scan again.');
    }
    if (working) {
      connectedPeer =
          id; // A recent signed handshake already verified this device.
      notifyListeners();
      return;
    }
    working = true;
    try {
      await syncPeer(peer);
      connectedPeer = id;
      notifyListeners();
    } finally {
      working = false;
    }
  }

  Future<void> addRecipient(Json cert) async {
    final body = await verify(trust['sign_key'], cert);
    if (body['mesh_id'] != trust['mesh_id'] ||
        body['expires_at'] <= nowSeconds) {
      throw StateError(
        'Recipient belongs to another bank or their identity has expired.',
      );
    }
    if (body['account_id'] == accountId) {
      throw StateError('Choose a different recipient.');
    }
    merchants.removeWhere((x) => x['body']['account_id'] == body['account_id']);
    merchants.add(cert);
    profile!['merchants'] = merchants;
    await saveProfile();
    notifyListeners();
  }

  Future<void> setPaymentPin(String password, String pin) async {
    if (!bankReachable) {
      throw StateError('Connect to the bank to set your payment PIN.');
    }
    if (!RegExp(r'^[0-9]{6}$').hasMatch(pin)) {
      throw ArgumentError('Use a six-digit payment PIN.');
    }
    final result = await request(
      '/api/pin',
      body: {'password': password, 'pin': pin},
    );
    applyAccount(Map<String, dynamic>.from(result['account']));
    await saveProfile();
    notifyListeners();
  }

  Future<String> pay(Json recipient, int amount, {required String pin}) async {
    if (!pinConfigured) {
      throw StateError('Set your payment PIN online before paying.');
    }
    if (!RegExp(r'^[0-9]{6}$').hasMatch(pin)) {
      throw ArgumentError('Enter your six-digit payment PIN.');
    }
    if (!canPay) {
      throw StateError(
        'Connect to the bank or a verified nearby relay before paying.',
      );
    }
    if (amount < 1 || amount > 1000000) {
      throw ArgumentError('Enter ₹0.01 to ₹10,000');
    }
    final beneficiary = await verify(trust['sign_key'], recipient);
    if (beneficiary['mesh_id'] != trust['mesh_id'] ||
        beneficiary['expires_at'] <= nowSeconds) {
      throw StateError(
        'Recipient identity expired. Refresh online or scan a fresh code.',
      );
    }
    if (certificate['body']['expires_at'] <= nowSeconds) {
      throw StateError('Reconnect online and renew device enrollment.');
    }
    final authenticated = authorizePayment != null
        ? await authorizePayment!()
        : await auth.authenticate(
            localizedReason:
                'Authorize a demo payment of ₹${(amount / 100).toStringAsFixed(2)} to ${beneficiary['display_name'] ?? beneficiary['account_id']}',
            biometricOnly: false,
            persistAcrossBackgrounding: true,
          );
    if (!canPay) {
      throw StateError(
        'Connection changed. Reconnect before authorizing a new payment.',
      );
    }
    if (!authenticated) {
      throw StateError('Payment authorization was cancelled.');
    }
    final id = const Uuid().v4();
    final createdAt = nowSeconds;
    final body = {
      'v': 2,
      'pin': pin,
      'payment_id': id,
      'sender': accountId,
      'recipient': beneficiary['account_id'],
      'amount': amount,
      'currency': 'INR',
      'created_at': createdAt,
      'expires_at': createdAt + 600,
      'device_id': deviceId,
      'sender_mailbox': randomCapability(),
      'recipient_mailbox': randomCapability(),
    };
    final p = await makePacket(
      'payment',
      await seal(trust['box_key'], await sign(signing, body)),
      body['sender_mailbox'] as String,
      body['expires_at'] as int,
    );
    await store.createPayment(p, {
      for (final entry in body.entries)
        if (entry.key != 'pin') entry.key: entry.value,
      'name': beneficiary['display_name'] ?? beneficiary['account_id'],
      'packet_id': p['id'],
      'state': 'queued',
      'transport': 'Saved on this phone',
    });
    await log('Payment request saved. Waiting for a verified bank decision.');
    await reload();
    notifyListeners();
    unawaited(tick());
    return id;
  }

  Future<void> log(String s) async {
    await store.event(s);
    await reload();
    notifyListeners();
  }

  Future<void> reload() async {
    payments = await store.payments();
    receipts = await store.receipts();
    events = await store.events();
    queueSize = (await store.packets()).length;
  }

  Future<void> setAllowlist(String value) async {
    allowlist = value
        .split(RegExp(r'[,\s]+'))
        .where((x) => x.isNotEmpty)
        .toList();
    await store.saveConfig('allowlist', allowlist);
    notifyListeners();
  }

  bool allowed(String id) => allowlist.isEmpty || allowlist.contains(id);
  Future<void> startRelay() async {
    if (profile == null) throw StateError('Enroll online first.');
    if (_relayTransition) return;
    _relayTransition = true;
    try {
      await background?.start();
      relayEnabled = true;
      await _startRadio();
      relayBlocked = null;
    } catch (error) {
      relayEnabled = false;
      relay = false;
      await _radio?.stop();
      await background?.stop();
      rethrow;
    } finally {
      _relayTransition = false;
      notifyListeners();
    }
    await restoreBackgroundRelay();
    unawaited(tick());
  }

  Future<void> _startRadio() async {
    if (certificate['body']['expires_at'] <= nowSeconds) {
      throw StateError('Reconnect online to renew device enrollment.');
    }
    await radio.start();
    relay = true;
    timer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(tick());
    });
  }

  Future<void> restoreBackgroundRelay() async {
    if (background == null || !ready || _relayTransition || _disposed) return;
    _relayTransition = true;
    try {
      final status = await background!.ready();
      relayEnabled = status['enabled'] == true;
      backgroundActive = status['running'] == true;
      relayBlocked = status['blocked'] as String?;
      if (relayEnabled &&
          backgroundActive &&
          relayBlocked == null &&
          profile != null) {
        if (!relay || !radio.running) await _startRadio();
      } else if (relay && _radio != null) {
        relay = false;
        await _radio!.stop();
        connectedPeer = null;
      }
    } catch (error) {
      relayBlocked = error.toString();
      relay = false;
      await _radio?.stop();
    } finally {
      _relayTransition = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> stopRelay() async {
    await background?.stop();
    relayEnabled = false;
    backgroundActive = false;
    relay = false;
    connectedPeer = null;
    nearby.clear();
    await _radio?.stop();
    await log('Nearby relay stopped. Saved payments are retained.');
  }

  Future<void> setGateway(bool enabled) async {
    gateway = enabled;
    nextBankAttempt = DateTime.now();
    if (enabled) startMonitoring();
    notifyListeners();
    unawaited(tick());
  }

  Future<Json> signedRpc(Json command, String requestId) async => {
    ...await sign(signing, {
      'request_id': requestId,
      'at': nowSeconds,
      'command': command,
    }),
    'certificate': certificate,
  };
  Future<Json> validateRpc(Json message, {String? expectedRequest}) async {
    final cert = Map<String, dynamic>.from(message['certificate']);
    final peer = await verify(trust['sign_key'], cert);
    if (peer['mesh_id'] != trust['mesh_id'] ||
        peer['expires_at'] <= nowSeconds ||
        peer['device_id'] == deviceId ||
        !allowed(peer['device_id'])) {
      throw StateError('Peer is not permitted in this mesh.');
    }
    final body = await verify(peer['sign_key'], message);
    if (expectedRequest != null && body['request_id'] != expectedRequest) {
      throw StateError('Peer response does not match request.');
    }
    if (body['at'] is! int || (body['at'] - nowSeconds).abs() > 120) {
      throw StateError('Peer clock differs by more than two minutes');
    }
    if (body['request_id'] is! String || body['request_id'].length > 80) {
      throw StateError('Invalid request identity');
    }
    await store.savePeer(peer['device_id'], cert);
    return {
      'peer': peer,
      'command': body['command'],
      'request_id': body['request_id'],
    };
  }

  Future<Json> handleRpc(Json message) async {
    if (!relay) throw StateError('Nearby relay is off');
    final checked = await validateRpc(message);
    final rid = checked['request_id'];
    seenRpc.removeWhere((_, t) => t < nowSeconds - 120);
    if (seenRpc.containsKey(rid)) throw StateError('Replayed peer request');
    if (seenRpc.length > 1000) throw StateError('Peer request limit');
    seenRpc[rid] = nowSeconds;
    final cmd = Map<String, dynamic>.from(checked['command']);
    final peer = Map<String, dynamic>.from(checked['peer']);
    final response = await command(cmd, peer);
    return signedRpc(response, rid);
  }

  Future<Json> command(Json cmd, Json peer) async {
    switch (cmd['op']) {
      case 'resolve':
        final id = cmd['account_id'];
        if (id is! String || id.length > 100) {
          throw StateError('Invalid recipient ID');
        }
        if (id == accountId) {
          return {'op': 'recipient', 'certificate': certificate};
        }
        for (final cert in merchants) {
          if (cert['body']['account_id'] == id &&
              cert['body']['expires_at'] > nowSeconds) {
            return {'op': 'recipient', 'certificate': cert};
          }
        }
        if (bankReachable) {
          try {
            return {
              'op': 'recipient',
              'certificate': (await request(
                '/api/recipients/${Uri.encodeComponent(id)}',
              ))['certificate'],
            };
          } on BankFailure {
            return {'op': 'recipient', 'certificate': null};
          }
        }
        return {'op': 'recipient', 'certificate': null};
      case 'inventory':
        final offset = cmd['offset'] ?? 0;
        if (offset is! int || offset < 0 || offset > 1000) {
          throw StateError('Invalid inventory cursor');
        }
        final all = (await store.packets())
          ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
        final page = all.skip(offset).take(48).toList();
        final ids = page.map((p) => p['id']).toList();
        return {
          'op': 'inventory',
          'ids': ids,
          'next': offset + 48 < all.length ? offset + 48 : null,
          'device_id': deviceId,
          'online': bankReachable,
          'routing': 2,
          'routes': [
            for (final p in page)
              {'id': p['id'], 'hops': p['hops'], 'kind': p['kind']},
          ],
        };
      case 'get':
        if (cmd['id'] is! String) throw StateError('Invalid packet request');
        final p = await store.packet(cmd['id']);
        if (p == null ||
            !RelayRouting.canForward(p, deviceId, peer['device_id'])) {
          return {'op': 'missing'};
        }
        final custodians = await store.recentCustodians(p['id']);
        if (cmd['online'] != true &&
            !(p['kind'] == 'receipt' &&
                p['path'].contains(peer['device_id'])) &&
            !custodians.contains(peer['device_id']) &&
            custodians.length >= RelayRouting.offlineFanout) {
          return {'op': 'missing'};
        }
        _offeredPackets.removeWhere((_, at) => at < nowSeconds - 120);
        if (_offeredPackets.length >= 1000) return {'op': 'missing'};
        _offeredPackets['${peer['device_id']}:${p['id']}'] = nowSeconds;
        return {'op': 'packet', 'packet': forwarded(p)};
      case 'ack':
        final id = cmd['id'];
        if (id is! String ||
            id.length != 64 ||
            (_offeredPackets['${peer['device_id']}:$id'] ?? 0) <
                nowSeconds - 120) {
          throw StateError('Unsolicited packet acknowledgement');
        }
        final p = await store.packet(id);
        if (p != null) {
          await store.acknowledge(
            id,
            peer['device_id'],
            p['hops'] + 1,
            p['expires_at'],
          );
        }
        _offeredPackets.remove('${peer['device_id']}:$id');
        return {'op': 'acknowledged', 'id': id};
      case 'put':
        final p = Map<String, dynamic>.from(cmd['packet']);
        await accept(p);
        return {'op': 'stored', 'id': p['id']};
      default:
        throw StateError('Unknown peer command');
    }
  }

  Json forwarded(Json p) {
    return RelayRouting.forward(p, deviceId);
  }

  Future<void> accept(Json p) async {
    await checkPacket(p);
    if (p['expires_at'] <= nowSeconds) {
      throw StateError('Packet retention expired');
    }
    final inserted = await store.putPacket(p);
    // Store before delivering or acknowledging. Crash recovery replays cached
    // signed receipts, never loses a packet after a successful storage ACK.
    if (p['kind'] == 'receipt') await deliverReceipt(p);
    if (inserted) {
      await log(
        'Stored encrypted ${p['kind']} packet ${p['id'].toString().substring(0, 8)}.',
      );
    }
  }

  Future<void> deliverReceipt(Json p) async {
    Json signed;
    try {
      signed = await openBox(encryption, Map<String, dynamic>.from(p['box']));
    } catch (_) {
      return;
    }
    final r = await verify(trust['sign_key'], signed);
    if (r['device_id'] != deviceId ||
        r['v'] != 1 ||
        !['paid', 'rejected'].contains(r['status']) ||
        (r['sender'] != accountId && r['recipient'] != accountId)) {
      throw StateError('Receipt validation failed');
    }
    final local = (await store.payments())
        .where((x) => x['payment_id'] == r['payment_id'])
        .firstOrNull;
    if (local != null &&
        (local['sender'] != r['sender'] ||
            local['recipient'] != r['recipient'] ||
            local['amount'] != r['amount'])) {
      throw StateError('Receipt differs from authorized payment');
    }
    await store.putReceipt(r);
    if (local != null) {
      await store.putPayment({
        ...local,
        'state': r['status'],
        'transport': 'Bank signature verified',
        'receipt': r,
      });
    }
    // Ledger revision prevents equal-timestamp receipts from rolling the displayed balance back.
    final revision = profile!['account']['revision'] as int? ?? 0;
    if (r['balance_revision'] is int && r['balance_revision'] > revision) {
      profile!['account']['balance'] = r['balance'];
      profile!['account']['revision'] = r['balance_revision'];
      profile!['balance_checked_at'] = r['committed_at'];
      await saveProfile();
    }
  }

  Future<void> syncPeer(PeerRadio peer) async {
    final key = peer.peripheral.uuid.toString();
    await radio.connect<void>(peer, (raw) async {
      Json? peerIdentity;
      Future<Json> rpc(Json cmd) async {
        final rid = const Uuid().v4();
        final response = await raw(await signedRpc(cmd, rid));
        final checked = await validateRpc(response, expectedRequest: rid);
        peerIdentity = Map<String, dynamic>.from(checked['peer']);
        identityByRadio[key] = peerIdentity!['device_id'];
        return Map<String, dynamic>.from(checked['command']);
      }

      await syncPackets(rpc, () => peerIdentity!);
    });
  }

  /// The production exchange is transport-independent so fault tests execute
  /// these exact routing/storage rules, rather than a separate mesh simulation.
  Future<void> syncPackets(
    Future<Json> Function(Json) rpc,
    Json Function() peerIdentity,
  ) async {
    final remoteIds = <String>{};
    final remoteRoutes = <String, Json>{};
    int? offset = 0;
    bool peerOnline = false;
    while (offset != null) {
      final remote = await rpc({'op': 'inventory', 'offset': offset});
      if (remote['op'] != 'inventory' ||
          remote['ids'] is! List ||
          remote['ids'].length > 48 ||
          remote['ids'].any((id) => id is! String || id.length != 64)) {
        throw StateError('Invalid inventory');
      }
      peerOnline = remote['online'] == true;
      remoteIds.addAll((remote['ids'] as List).cast<String>());
      if (remote['routing'] == 2) {
        final routes = remote['routes'];
        if (routes is! List || routes.length != remote['ids'].length) {
          throw StateError('Invalid route inventory');
        }
        for (final item in routes) {
          if (item is! Map ||
              !remote['ids'].contains(item['id']) ||
              item['hops'] is! int ||
              item['hops'] < 0 ||
              item['hops'] > 4 ||
              !['payment', 'receipt'].contains(item['kind'])) {
            throw StateError('Invalid route summary');
          }
          remoteRoutes[item['id']] = Map<String, dynamic>.from(item);
        }
        if (remoteRoutes.length != remoteIds.length) {
          throw StateError('Duplicate route summary');
        }
      }
      final next = remote['next'];
      if (next != null && (next is! int || next <= offset || next > 1000)) {
        throw StateError('Invalid inventory cursor');
      }
      offset = next;
    }
    final identity = peerIdentity();
    final peerId = identity['device_id'] as String;
    nearby.removeWhere((x) => x['device_id'] == peerId);
    nearby.add({
      'device_id': peerId,
      'name': identity['display_name'] ?? identity['account_id'],
      'online': peerOnline,
      'at': nowSeconds,
    });
    final local = await store.packets();
    final localById = {for (final p in local) p['id']: p};
    // A signed inventory also repairs an ACK lost after the peer committed its
    // copy. Always retain our original until a verified bank result is known.
    for (final id in remoteIds.where(localById.containsKey)) {
      final p = localById[id]!;
      await store.acknowledge(
        id,
        peerId,
        remoteRoutes[id]?['hops'] ?? p['hops'] + 1,
        p['expires_at'],
      );
      for (final intent in payments.where(
        (intent) => intent['packet_id'] == id,
      )) {
        await store.markRelayed(intent['payment_id']);
      }
    }
    // Fetch receipts first when known; pull a bounded inventory, then push missing packets.
    final incoming =
        remoteIds.where((id) {
          final ours = localById[id];
          return ours == null ||
              (remoteRoutes[id] != null &&
                  remoteRoutes[id]!['hops'] + 1 < ours['hops']);
        }).toList()..sort((a, b) {
          int rank(String id) => remoteRoutes[id]?['kind'] == 'receipt' ? 0 : 1;
          return rank(a).compareTo(rank(b));
        });
    for (final item in RelayRouting.fairOrder([
      for (final id in incoming)
        {'id': id, 'kind': remoteRoutes[id]?['kind'] ?? 'payment'},
    ]).take(8)) {
      final id = item['id'] as String;
      final value = await rpc({'op': 'get', 'id': id, 'online': bankReachable});
      if (value['op'] == 'packet') {
        await accept(Map<String, dynamic>.from(value['packet']));
        if (remoteRoutes.containsKey(id)) {
          final ack = await rpc({'op': 'ack', 'id': id});
          if (ack['op'] != 'acknowledged' || ack['id'] != id) {
            throw StateError('Peer did not accept durable acknowledgement');
          }
        }
      }
    }
    final outgoing = (await store.packets())
        .where(
          (p) =>
              RelayRouting.canForward(p, deviceId, peerId) &&
              (!remoteIds.contains(p['id']) ||
                  RelayRouting.improves(
                    p,
                    remoteRoutes[p['id']]?['hops'] as int?,
                  )),
        )
        .toList();
    outgoing.sort((a, b) {
      final rank = RelayRouting.priority(
        a,
        peerId,
      ).compareTo(RelayRouting.priority(b, peerId));
      return rank != 0
          ? rank
          : (a['expires_at'] as int).compareTo(b['expires_at'] as int);
    });
    var sent = 0;
    for (final p in RelayRouting.fairOrder(outgoing)) {
      if (sent >= 8) break;
      final custodians = await store.recentCustodians(p['id']);
      final isReturnRoute =
          p['kind'] == 'receipt' && p['path'].contains(peerId);
      if (!peerOnline &&
          !isReturnRoute &&
          !custodians.contains(peerId) &&
          custodians.length >= RelayRouting.offlineFanout) {
        continue;
      }
      final response = await rpc({'op': 'put', 'packet': forwarded(p)});
      if (response['op'] != 'stored' || response['id'] != p['id']) {
        throw StateError('Peer did not acknowledge storage');
      }
      await store.acknowledge(p['id'], peerId, p['hops'] + 1, p['expires_at']);
      sent++;
      final localPayment = payments
          .where((x) => x['packet_id'] == p['id'])
          .firstOrNull;
      if (localPayment != null &&
          !['paid', 'rejected'].contains(localPayment['state'])) {
        await store.markRelayed(localPayment['payment_id']);
      }
    }
  }

  Future<void> gatewayTick() async {
    if (DateTime.now().isBefore(nextBankAttempt)) return;
    try {
      final health = await request('/api/health');
      if (health['fingerprint'] != trust['fingerprint']) {
        throw StateError('Bank trust changed. Stop and verify bank setup.');
      }
      if (health['online'] != true) {
        throw BankFailure(503, 'Demo bank is paused');
      }
      network = 'Connected to bank';
      for (final p
          in (await store.packets())
              .where(
                (p) =>
                    p['kind'] == 'payment' &&
                    p['uploaded'] == 0 &&
                    (relay || payments.any((x) => x['packet_id'] == p['id'])),
              )
              .take(6)) {
        final clean = Map<String, dynamic>.from(p)..remove('uploaded');
        try {
          final result = await submitPacket(clean);
          // Persist every receipt before marking this submission complete.
          for (final value in result['receipts']) {
            await accept(Map<String, dynamic>.from(value));
          }
          await store.uploaded(p['id']);
          await log(
            'Bank returned signed receipts for packet ${p['id'].toString().substring(0, 8)}.',
          );
        } on BankFailure catch (e) {
          if (e.status == 400 || e.status == 409) {
            await store.uploaded(p['id']);
            await log(
              'Bank refused packet ${p['id'].toString().substring(0, 8)}. No verified financial outcome available.',
            );
            continue;
          }
          rethrow;
        }
      }
      final own = await request('/api/receipts/$deviceId?after=$_inboxCursor');
      for (final value in own['receipts']) {
        await accept(Map<String, dynamic>.from(value));
      }
      _inboxCursor = own['cursor'];
      // Recover a committed result if the gateway lost the HTTP response, including after expiry.
      final cached = await store.packets(activeOnly: false);
      final receiptCaps = cached
          .where((p) => p['kind'] == 'receipt')
          .map((p) => p['mailbox'])
          .toSet();
      for (final p
          in cached
              .where(
                (p) =>
                    p['kind'] == 'payment' &&
                    !receiptCaps.contains(p['mailbox']),
              )
              .take(6)) {
        final recovered = await request('/api/mailbox/${p['mailbox']}');
        for (final value in recovered['receipts']) {
          await accept(Map<String, dynamic>.from(value));
        }
      }
      // Resolve unknown outcomes even after local payment authorization expiry.
      for (final intent
          in (await store.payments())
              .where((p) => !['paid', 'rejected'].contains(p['state']))
              .take(12)) {
        final result = await request(
          '/api/mailbox/${intent['sender_mailbox']}',
        );
        for (final value in result['receipts']) {
          await accept(Map<String, dynamic>.from(value));
        }
      }
      backoffSeconds = 5;
      nextBankAttempt = DateTime.now().add(const Duration(seconds: 5));
    } catch (e) {
      bankReachable = false;
      network = e is BankFailure && e.status == 401
          ? 'Sign in online to renew gateway session'
          : 'Bank unreachable · retrying in ${backoffSeconds}s';
      nextBankAttempt = DateTime.now().add(Duration(seconds: backoffSeconds));
      backoffSeconds = (backoffSeconds * 2).clamp(5, 60);
    }
  }

  Future<void> tick() async {
    if (working || profile == null || _disposed) return;
    working = true;
    try {
      await restoreBackgroundRelay();
      if (relay && radio.running) {
        final candidates = radio.discovered.values.toList();
        // Rotate equal-priority peers so a dense network cannot permanently
        // starve the only neighbour that leads towards an internet gateway.
        final rotated = candidates.isEmpty
            ? candidates
            : [
                ...candidates.skip(_peerRound % candidates.length),
                ...candidates.take(_peerRound % candidates.length),
              ];
        _peerRound++;
        final peers = rotated
          ..sort((a, b) {
            int priority(PeerRadio p) =>
                nearby.any(
                  (n) =>
                      n['device_id'] ==
                          identityByRadio[p.peripheral.uuid.toString()] &&
                      n['online'] == true &&
                      n['at'] >= nowSeconds - 90,
                )
                ? 0
                : 1;
            return priority(a).compareTo(priority(b));
          });
        for (final peer in peers.take(6)) {
          final id = peer.peripheral.uuid.toString();
          if (identityByRadio.containsKey(id) &&
              !allowed(identityByRadio[id]!)) {
            continue;
          }
          if (peerRetry[id]?.isAfter(DateTime.now()) ?? false) continue;
          try {
            await syncPeer(peer);
            peerFailures[id] = 0;
            peerRetry[id] = DateTime.now().add(
              Duration(milliseconds: 7000 + _jitter.nextInt(3000)),
            );
          } catch (error) {
            lastError = 'Nearby connection: $error';
            final fails = (peerFailures[id] ?? 0) + 1;
            peerFailures[id] = fails;
            peerRetry[id] = DateTime.now().add(
              Duration(
                milliseconds:
                    (5000 * (1 << fails.clamp(0, 4))).clamp(5000, 60000) +
                    _jitter.nextInt(3000),
              ),
            );
          }
        }
      }
      if (bankReachable || gateway) await gatewayTick();
      // Offline senders ask relays for cached receipts by normal inventory exchange.
      // Gateway relays recover their cached original submissions through idempotent retry.
      await store.cleanup();
      await reload();
      if (backgroundActive) {
        await background?.update(
          relayBlocked ??
              '$queueSize encrypted packets · ${bankReachable ? "Bank reachable" : "Offline forwarding"}',
        );
      }
      nearby.removeWhere((p) => p['at'] < nowSeconds - 120);
    } catch (e) {
      lastError = e.toString();
    } finally {
      working = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> retryNow() async {
    nextBankAttempt = DateTime.now();
    peerRetry.clear();
    await tick();
  }

  @override
  void dispose() {
    _disposed = true;
    timer?.cancel();
    connectionTimer?.cancel();
    background?.dispose();
    closeLive();
    httpClient.close();
    if (_radio != null) unawaited(_radio!.stop());
    super.dispose();
  }
}
