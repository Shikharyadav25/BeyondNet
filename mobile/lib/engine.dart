import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'protocol.dart';
import 'bank_connection_policy.dart';
import 'payment_auth.dart';
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

class EnrollmentFailure implements Exception {
  final String message;
  final bool resumeSignIn;
  EnrollmentFailure(this.message, {this.resumeSignIn = false});
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
  final PaymentAuth auth = PaymentAuth();
  late SimpleKeyPair signing, encryption;
  PeerTransport? _radio;
  PeerTransport get radio => _radio ??= BleTransport(
    handleRpc,
    (s) => unawaited(log(s)),
    onPeerDiscovered: () {
      if (!relay || _disposed) return;
      notifyListeners();
      unawaited(tick());
    },
  );
  int get unverifiedPeerCount =>
      _radio?.discovered.entries
          .where(
            (entry) =>
                DateTime.now().difference(entry.value.seen) <
                    const Duration(seconds: 25) &&
                !identityByRadio.containsKey(entry.key),
          )
          .length ??
      0;
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
  List<Json> payments = [], receipts = [], events = [], invitations = [];
  List<Json> relayQueue = [];
  List<Json> connectionRequests = [];
  final Map<String, Json> connectionStates = {};
  bool seekingRelay = false;
  int? notificationTab;
  bool connectionApproved(String id) =>
      connectionStates[id]?['state'] == 'accepted' &&
      (connectionStates[id]?['expiry'] as int? ?? 0) > nowSeconds;
  String connectionLabel(String id) {
    if (connectionApproved(id)) return 'Approved · ready to pay offline';
    return switch (connectionStates[id]?['state']) {
      'pending' => 'Waiting for connection approval',
      'declined' => 'Connection declined · choose another phone',
      'offline' => 'Relay cannot reach the bank',
      'unsupported' => 'Update this phone to approve connections',
      _ => 'Request connection for payment',
    };
  }

  void findPaymentRelay() {
    seekingRelay = true;
    notifyListeners();
    unawaited(tick());
  }

  List<Json> nearby = [];
  List<String> allowlist = [];
  int queueSize = 0;
  bool gateway = false, relay = false, working = false, ready = false;
  bool relayEnabled = false, backgroundActive = false;
  String? relayBlocked;
  String? _relayStartFailure;
  bool _relayTransition = false;
  Completer<void>? _relayTransitionDone;
  bool get relayChanging => _relayTransition;
  bool _manualConnectionWaiting = false;
  bool _authorizingPayment = false;
  bool _recipientLookupWaiting = false;
  String network = 'Checking connection…';
  bool? internet;
  bool bankReachable = false, checkingConnection = false;
  bool connectionUnstable = false;
  String? bankAttention;
  int _connectionFailures = 0;
  bool _bankWorkDelayed = false;
  DateTime _nextHealthAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  Json? _cachedHealth;
  Future<Json>? _healthRequest;
  bool _temporaryBankError(Object error) =>
      BankConnectionPolicy.transportError(error) ||
      error is http.ClientException ||
      (error is BankFailure &&
          (error.status == 200 ||
              error.status == 408 ||
              error.status == 429 ||
              error.status >= 500));
  void _connectionProblem(Object error) {
    bankReachable = false;
    if (_temporaryBankError(error)) {
      _connectionFailures++;
      connectionUnstable = internet != false;
      bankAttention = null;
      network = internet == false
          ? 'Internet is off · saved payments will retry'
          : _connectionFailures < 3
          ? 'Connection unstable · saved payments will retry'
          : 'Waiting for bank connection · payment outcomes remain pending';
    } else {
      connectionUnstable = false;
      _cachedHealth = null;
      bankAttention = error is BankFailure && [401, 403].contains(error.status)
          ? 'Sign in again to renew bank access'
          : error.toString().replaceFirst('Bad state: ', '');
      network = bankAttention!;
      closeLive();
    }
  }

  Future<Json> _verifiedHealth({bool force = false}) async {
    if (_healthRequest != null) return _healthRequest!;
    if (!force &&
        _cachedHealth != null &&
        _cachedHealth!['fingerprint'] == trust['fingerprint'] &&
        DateTime.now().difference(_lastHealthCheck) <
            BankConnectionPolicy.healthFreshness) {
      return _cachedHealth!;
    }
    final pending = () async {
      final health = await request('/api/health');
      if (health['fingerprint'] != trust['fingerprint']) {
        throw StateError(
          'Bank identity changed. Verify the bank fingerprint before continuing.',
        );
      }
      _lastHealthCheck = DateTime.now();
      _cachedHealth = health;
      return health;
    }();
    _healthRequest = pending;
    try {
      return await pending;
    } finally {
      if (identical(_healthRequest, pending)) _healthRequest = null;
    }
  }

  bool get isMerchant => account?['role'] == 'merchant';
  bool get pinConfigured => account?['pin_configured'] == true;
  int get availableBalance => _availableBalance(payments);

  int _availableBalance(List<Json> intents) {
    final reserved = intents
        .where(
          (p) =>
              p['sender'] == accountId &&
              !['paid', 'rejected'].contains(p['state']),
        )
        .fold<int>(0, (sum, p) => sum + (p['amount'] as int));
    return ((account?['balance'] as num? ?? 0).toInt() - reserved).clamp(
      0,
      100000000,
    );
  }

  Future<void> _ensurePaymentFunds(int amount) async {
    final available = _availableBalance(await store.payments());
    if (amount > available) {
      final pending = (account!['balance'] as num).toInt() > available;
      throw StateError(
        'Insufficient demo balance. Available: ₹${(available / 100).toStringAsFixed(2)}. '
        '${pending ? "Money reserved for pending payments is unavailable until their bank result is known. " : ""}'
        'Add demo money online before paying.',
      );
    }
  }

  Future<void> preparePayment(int amount) async {
    if (amount < 1 || amount > 1000000) {
      throw ArgumentError('Enter ₹0.01 to ₹10,000.');
    }
    // Online uses a fresh authoritative snapshot. Offline uses the last bank
    // snapshot less unresolved local intents; expiry alone never releases them.
    if (bankReachable &&
        !connectionUnstable &&
        DateTime.now().difference(_lastProfileRefresh).inSeconds >= 30) {
      try {
        await refreshProfile();
      } catch (error) {
        if (!_temporaryBankError(error)) rethrow;
        _connectionProblem(error);
      }
    }
    await _ensurePaymentFunds(amount);
  }

  String? connectedPeer;
  // Authorization is independent of connectivity. Bank reachability only
  // determines whether delivery is direct or queued for Bluetooth carriage.
  bool get canPay =>
      profile != null &&
      pinConfigured &&
      certificate['body']['expires_at'] > nowSeconds;
  bool get liveConnected => _socket != null && _liveReady;
  WebSocket? _socket;
  bool _liveReady = false, _openingSocket = false, _disposed = false;
  final Map<String, Completer<Json>> _pending = {};
  DateTime _nextSocketAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastProfileRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastHealthCheck = DateTime.fromMillisecondsSinceEpoch(0);
  bool _urgentBankWork = false;
  Future<void>? _gatewayWork;
  int _inboxCursor = 0;
  Timer? connectionTimer;
  static const platform = MethodChannel('beyondnet/network');
  String? lastError;
  Timer? timer;
  int backoffSeconds = 5;
  DateTime nextBankAttempt = DateTime.now();
  final Map<String, DateTime> peerRetry = {};
  final Map<String, int> peerFailures = {};
  final Map<String, String> identityByRadio = {};
  final Map<String, int> _offeredPackets = {};
  final Map<String, int> _discoveryStarted = {};
  final Set<String> _awaitingPeer = {};
  final Random _jitter = Random();
  int _peerRound = 0;
  int _proofRound = 0;
  Future<void> init({String? databasePath}) async {
    await store.init(databasePath: databasePath);
    final saved = await secure.read(key: 'profile');
    if (saved != null) {
      profile = Map<String, dynamic>.from(jsonDecode(saved));
      _inboxCursor =
          (await store.config('inbox_cursor:$deviceId') as int?) ?? 0;
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
            .timeout(BankConnectionPolicy.timeout(path));
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

  Future<Json> paymentIdChoices(
    String url,
    String fingerprint,
    String name,
    String id,
  ) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      throw StateError('Set up your bank to check payment IDs.');
    }
    final base = url.trim().replaceAll(RegExp(r'/+$'), '');
    final health = await request('/api/health', url: base);
    final expected = fingerprint.trim().toLowerCase();
    final actual = await digest({
      for (final k in ['sign_key', 'box_key', 'mesh_id']) k: health[k],
    });
    if (expected.length != 64 ||
        actual != expected ||
        health['fingerprint'] != actual) {
      throw StateError(
        'Verify your bank fingerprint before checking payment IDs.',
      );
    }
    return request(
      '/api/payment-ids?${Uri(queryParameters: {'name': name.trim(), 'id': id.trim()}).query}',
      url: base,
    );
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
    Json health;
    try {
      health = await request('/api/health', url: base);
    } on TimeoutException {
      throw EnrollmentFailure(
        'The bank did not respond. Check this phone’s internet connection and '
        'that the bank and tunnel are running. No account details were sent.',
      );
    } on SocketException {
      throw EnrollmentFailure(
        'Cannot reach the bank. Connect this phone to the internet and check '
        'the bank URL. No account details were sent.',
      );
    } on http.ClientException {
      throw EnrollmentFailure(
        'Cannot connect securely to the bank. Check this phone’s internet '
        'connection and bank URL. No account details were sent.',
      );
    }
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
    Json result;
    try {
      result = await request(
        name == null ? '/api/login' : '/api/signup',
        url: base,
        body: {
          'account': id.trim().toLowerCase(),
          'password': password,
          if (name != null) 'name': name.trim(),
          if (name != null) 'role': role,
        },
      );
    } on BankFailure catch (error) {
      if (name != null && error.status == 409) {
        throw EnrollmentFailure(
          'This payment ID is already registered. Sign in with the same ID '
          'and password to finish setup, or choose a different ID.',
          resumeSignIn: true,
        );
      }
      rethrow;
    } on TimeoutException {
      throw _accountConnectionFailure(name != null);
    } on SocketException {
      throw _accountConnectionFailure(name != null);
    } on http.ClientException {
      throw _accountConnectionFailure(name != null);
    }
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
    Json registered;
    try {
      registered = await request(
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
    } catch (error) {
      if (error is TimeoutException ||
          error is SocketException ||
          error is http.ClientException ||
          error is BankFailure) {
        throw EnrollmentFailure(
          'Your account was verified, but device setup did not finish. '
          'Check the connection and sign in with the same ID and password '
          'to finish setup. Your saved device keys will be kept.',
          resumeSignIn: true,
        );
      }
      rethrow;
    }
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

  EnrollmentFailure _accountConnectionFailure(
    bool creating,
  ) => EnrollmentFailure(
    creating
        ? 'The bank did not confirm account creation. Your account may already '
              'exist. Check the connection, then sign in with the same ID and '
              'password to finish setup.'
        : 'Sign-in did not finish. Check this phone’s internet connection and '
              'that the bank and tunnel are running, then sign in again.',
    resumeSignIn: creating,
  );
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
    _lastProfileRefresh = DateTime.now();
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
      unawaited(_checkConnection(force: false));
    });
    timer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(tick());
    });
    unawaited(checkConnection());
  }

  Future<void> checkConnection() => _checkConnection(force: true);

  Future<void> _checkConnection({required bool force}) async {
    if (profile == null ||
        checkingConnection ||
        _disposed ||
        (!force && DateTime.now().isBefore(_nextHealthAttempt))) {
      return;
    }
    checkingConnection = true;
    notifyListeners();
    final wasReachable = bankReachable;
    try {
      try {
        internet = await platform
            .invokeMethod<bool>('hasInternet')
            .timeout(const Duration(seconds: 2));
      } on MissingPluginException {
        internet = null;
      } on PlatformException {
        internet = null;
      } on TimeoutException {
        internet = null;
      }
      // Android's validation flag is a hint. A verified HTTPS response from
      // this bank is authoritative, including on networks the OS misclassifies.
      if (bankReachable &&
          liveConnected &&
          DateTime.now().difference(_lastHealthCheck).inSeconds < 30) {
        unawaited(tick());
        return;
      }
      final health = await _verifiedHealth(force: force);
      if (health['fingerprint'] != trust['fingerprint']) {
        throw StateError(
          'Bank identity changed. Verify the bank fingerprint before continuing.',
        );
      }
      internet = true;
      bankReachable = health['online'] == true;
      if (bankReachable &&
          !wasReachable &&
          !DateTime.now().isBefore(nextBankAttempt)) {
        nextBankAttempt = DateTime.now();
        _urgentBankWork = true;
      }
      connectionUnstable = _bankWorkDelayed;
      bankAttention = null;
      _connectionFailures = 0;
      _nextHealthAttempt = DateTime.now().add(
        BankConnectionPolicy.healthFreshness,
      );
      network = bankReachable
          ? (_bankWorkDelayed
                ? 'Connection unstable · saved payments will retry'
                : 'Connected to bank')
          : 'Bank is paused';
      if (!_disposed) notifyListeners();
      if (bankReachable) {
        unawaited(openLive());
        if (DateTime.now().difference(_lastProfileRefresh).inMinutes >= 5) {
          try {
            await refreshProfile();
          } catch (error) {
            if (error is BankFailure && error.status == 401) rethrow;
            await store.event(
              'Balance refresh delayed; bank connection retained.',
            );
          }
        }
        unawaited(tick());
      }
    } catch (error) {
      _connectionProblem(error);
      _nextHealthAttempt = DateTime.now().add(
        BankConnectionPolicy.retry(_connectionFailures),
      );
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
      bool expired = false;
      final opening = (socketConnector ?? WebSocket.connect)(uri.toString());
      unawaited(
        opening.then((socket) async {
          if (expired || _disposed) await socket.close();
        }, onError: (Object _) {}),
      );
      final socket = await opening.timeout(
        BankConnectionPolicy.socketConnect,
        onTimeout: () {
          expired = true;
          throw TimeoutException('Bank live connection is slow');
        },
      );
      if (_disposed) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.pingInterval = BankConnectionPolicy.heartbeat;
      socket.add(
        jsonEncode({
          'token': profile!['token'],
          'device_id': deviceId,
          'after': _inboxCursor,
        }),
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
          case 'connection_status':
            if (!_liveReady) throw StateError('Live session not verified');
            connectionUnstable = data['status'] == 'delayed';
            network = connectionUnstable
                ? 'Bank updates delayed · saved payments will retry'
                : 'Connected to bank';
            break;
          case 'account':
            if (!_liveReady) throw StateError('Live session not verified');
            applyAccount(Map<String, dynamic>.from(data['account']));
            await saveProfile();
            break;
          case 'receipts':
            if (!_liveReady) throw StateError('Live session not verified');
            await _receiveBankReceipts(data['receipts']);
            _inboxCursor = max(
              _inboxCursor,
              data['cursor'] as int? ?? _inboxCursor,
            );
            await store.saveConfig('inbox_cursor:$deviceId', _inboxCursor);
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
        return await completion.future.timeout(
          BankConnectionPolicy.liveSubmitFallback,
        );
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
      if (saved != null && saved['amount'] != amount) {
        throw StateError(
          'An earlier ₹${(saved['amount'] / 100).toStringAsFixed(2)} top-up has an unknown result. Retry that amount first to resolve it safely.',
        );
      }
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
      try {
        final result = await request(
          '/api/recipients/${Uri.encodeComponent(target)}',
        );
        final cert = Map<String, dynamic>.from(result['certificate']);
        if (cert['body']['account_id'] != target) {
          throw StateError(
            'Recipient ID does not match the requested account.',
          );
        }
        await addRecipient(cert);
        return cert;
      } catch (error) {
        if (!_temporaryBankError(error)) rethrow;
        _connectionProblem(error);
      }
    }
    for (final cert in merchants) {
      if (cert['body']['account_id'] == target &&
          cert['body']['expires_at'] > nowSeconds) {
        return cert;
      }
    }
    if (connectedPeer != null && relay) {
      if (_recipientLookupWaiting) {
        throw StateError('Another recipient lookup is in progress.');
      }
      _recipientLookupWaiting = true;
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 35));
        while (working && !_disposed) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError(
              'Nearby exchange is still busy. Retry recipient lookup shortly.',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        if (_disposed) throw StateError('App session closed.');
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
                expectedDevice: connectedPeer,
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
      } finally {
        _recipientLookupWaiting = false;
      }
    }
    throw StateError(
      'This ID is not saved or available through your relay. Scan their BeyondNet QR to verify them offline.',
    );
  }

  Future<void> connectNearby(String id) async {
    if (!relay) throw StateError('Enable nearby payments first.');
    // A periodic scan may already own the central radio. Never present that
    // unfinished scan as a successful user connection.
    _manualConnectionWaiting = true;
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (working && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (working) throw StateError('Bluetooth is busy. Try connecting again.');
      final radioId = identityByRadio.entries
          .where((x) => x.value == id)
          .firstOrNull
          ?.key;
      final peer = radioId == null ? null : radio.discovered[radioId];
      if (peer == null ||
          DateTime.now().difference(peer.seen) > const Duration(seconds: 25)) {
        nearby.removeWhere((p) => p['device_id'] == id);
        notifyListeners();
        throw StateError(
          'This phone is no longer advertising nearby. Scan again.',
        );
      }
      connectedPeer = id;
      seekingRelay = true;
      working = true;
      try {
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            await syncPeer(peer);
            break;
          } catch (error) {
            if (attempt == 1 || !error.toString().contains('133')) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 800));
          }
        }
        for (final payment in await store.payments()) {
          if (!['paid', 'rejected'].contains(payment['state']) &&
              payment['packet_id'] is String) {
            await store.chooseRoute(payment['packet_id'] as String, id);
          }
        }
        connectedPeer = id;
        notifyListeners();
      } finally {
        working = false;
      }
    } finally {
      _manualConnectionWaiting = false;
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
    if (_authorizingPayment) {
      throw StateError('Another payment is being authorized. Please wait.');
    }
    _authorizingPayment = true;
    try {
      return await _pay(recipient, amount, pin: pin);
    } finally {
      _authorizingPayment = false;
    }
  }

  Future<String> _pay(Json recipient, int amount, {required String pin}) async {
    if (!pinConfigured) {
      throw StateError('Set your payment PIN online before paying.');
    }
    if (!RegExp(r'^[0-9]{6}$').hasMatch(pin)) {
      throw ArgumentError('Enter your six-digit payment PIN.');
    }
    if (amount < 1 || amount > 1000000) {
      throw ArgumentError('Enter ₹0.01 to ₹10,000');
    }
    await preparePayment(amount);
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
            'Authorize a demo payment of ₹${(amount / 100).toStringAsFixed(2)} to ${beneficiary['display_name'] ?? beneficiary['account_id']}',
          );
    if (!authenticated) {
      throw StateError('Payment authorization was cancelled.');
    }
    await _ensurePaymentFunds(amount);
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
    final intent = <String, dynamic>{
      for (final entry in body.entries)
        if (entry.key != 'pin') entry.key: entry.value,
      'name': beneficiary['display_name'] ?? beneficiary['account_id'],
      'packet_id': p['id'],
      'state': 'queued',
      'transport': bankReachable
          ? 'Sending the original request to the bank'
          : 'Looking for a nearby phone to carry this request',
    };
    await store.createPayment(p, intent);
    payments = [intent, ...payments.where((row) => row['payment_id'] != id)];
    seekingRelay = !bankReachable;
    _discoveryStarted[p['id'] as String] = nowSeconds;
    peerRetry.clear();
    try {
      await log('Payment request saved. Waiting for a verified bank decision.');
    } catch (_) {
      // Authorization and reservation have committed. Return the same payment
      // ID even if a secondary log or screen refresh failed.
      lastError =
          'Payment saved. Activity will refresh when storage is available.';
    }
    if (!_disposed) notifyListeners();
    _urgentBankWork = true;
    nextBankAttempt = DateTime.now();
    if (bankReachable && timer?.isActive == true) unawaited(gatewayTick());
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
    invitations = await store.invitations();
    connectionRequests = await store.connectionRequests();
    relayQueue = await store.awaitingRoute();
    queueSize = (await store.packets()).length;
  }

  Future<void> decideConnectionRequest(String peer, bool allow) async {
    if (allow && !canPay) {
      throw StateError('Connect this phone to the bank before accepting.');
    }
    await store.decideConnection(peer, allow);
    try {
      await background?.clearRequest('connection:$peer');
    } catch (_) {}
    await log(
      allow
          ? 'Connection approved. Waiting for the sender’s payment.'
          : 'Connection declined.',
    );
    unawaited(tick());
  }

  Future<void> decideRelayInvitation(
    String id,
    bool allow, {
    String? token,
  }) async {
    final packet = await store.decideInvitation(id, allow, token: token);
    if (packet == null) {
      await reload();
      if (!_disposed) notifyListeners();
      throw StateError(
        'This request has ended. Check Nearby for the current offer.',
      );
    }
    invitations.removeWhere((row) => row['id'] == id);
    if (!_disposed) notifyListeners();
    unawaited(background?.clearRequest(id).catchError((Object _) {}));
    if (allow) {
      _discoveryStarted[id] = nowSeconds;
      _urgentBankWork = true;
      nextBankAttempt = DateTime.now();
      peerRetry.clear();
      if (bankReachable) unawaited(gatewayTick());
      unawaited(tick());
    }
    try {
      await log(
        allow
            ? 'Request saved. Automatically looking for bank access or the next phone.'
            : 'Declined a nearby payment request.',
      );
    } catch (_) {
      lastError =
          'Relay decision saved. Activity will refresh when storage is available.';
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> chooseRelayRoute(String packet, String peer) async {
    if (!nearby.any(
      (p) => p['device_id'] == peer && p['at'] >= nowSeconds - 45,
    )) {
      throw StateError('Scan again to find this phone.');
    }
    if ((await store.packetSource(packet)) == peer) {
      throw StateError(
        'Choose a different phone so the request does not loop back.',
      );
    }
    await store.chooseRoute(packet, peer);
    await log('Selected the next nearby phone for this encrypted request.');
    unawaited(tick());
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
  String _relayProblem(Object error) {
    if (error is StateError) return error.message.toString();
    if (error is TimeoutException) {
      return 'Android did not respond. Turn Bluetooth off and on, then retry Nearby relay.';
    }
    if (error is PlatformException && error.message != null) {
      return error.message!;
    }
    return 'Bluetooth relay could not start. Check Nearby devices permissions, then retry.';
  }

  Future<void> _changeRelay(Future<void> Function() action) async {
    _relayTransition = true;
    final done = _relayTransitionDone = Completer<void>();
    if (!_disposed) notifyListeners();
    try {
      await action();
    } finally {
      _relayTransition = false;
      _relayTransitionDone = null;
      done.complete();
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> startRelay() async {
    if (profile == null) throw StateError('Enroll online first.');
    if (_relayTransition) return;
    await _changeRelay(() async {
      try {
        _relayStartFailure = null;
        await background?.start();
        relayEnabled = true;
        await _startRadio();
        relayBlocked = null;
      } catch (error) {
        relayEnabled = false;
        backgroundActive = false;
        relay = false;
        relayBlocked = _relayProblem(error);
        // Each native cleanup is bounded; attempt both even if one fails.
        try {
          await _radio?.stop();
        } catch (_) {}
        try {
          await background?.stop();
        } catch (_) {}
        rethrow;
      }
    });
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
    await _changeRelay(() async {
      try {
        final status = await background!.ready();
        if (status['notificationTab'] is int) {
          notificationTab = status['notificationTab'] as int;
        }
        relayEnabled = status['enabled'] == true;
        backgroundActive = status['running'] == true;
        final nativeBlocked = status['blocked'] as String?;
        // A failed restore stays paused instead of repeatedly locking the
        // switch on every timer tick. Explicit retry or an adapter/permission
        // change allows another attempt.
        if (nativeBlocked != null) _relayStartFailure = null;
        relayBlocked = nativeBlocked ?? _relayStartFailure;
        if (relayEnabled &&
            backgroundActive &&
            relayBlocked == null &&
            profile != null) {
          final transport = radio;
          if (transport is BleTransport &&
              status['screenInteractive'] is bool) {
            transport.setScreenInteractive(status['screenInteractive'] as bool);
          }
          if (!relay || !radio.running) await _startRadio();
        } else if (relay && _radio != null) {
          relay = false;
          await _radio!.stop();
          connectedPeer = null;
        }
      } catch (error) {
        relayBlocked = _relayStartFailure = _relayProblem(error);
        relay = false;
        await _radio?.stop();
      }
    });
  }

  Future<void> stopRelay() async {
    // A notification/lifecycle refresh can be starting the radio. Finish that
    // transition before stopping so its late completion cannot turn us back on.
    while (_relayTransition) {
      await _relayTransitionDone!.future;
    }
    await _changeRelay(() async {
      try {
        await background?.stop();
      } finally {
        relayEnabled = false;
        backgroundActive = false;
        relay = false;
        relayBlocked = null;
        _relayStartFailure = null;
        connectedPeer = null;
        nearby.clear();
        identityByRadio.clear();
        peerRetry.clear();
        peerFailures.clear();
        _awaitingPeer.clear();
        await _radio?.stop();
      }
    });
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
  Future<Json> validateRpc(
    Json message, {
    String? expectedRequest,
    Json? expectedPeer,
    String? expectedDevice,
  }) async {
    final cert = Map<String, dynamic>.from(message['certificate']);
    final peer = await verify(trust['sign_key'], cert);
    if (peer['mesh_id'] != trust['mesh_id'] ||
        peer['expires_at'] <= nowSeconds ||
        peer['device_id'] == deviceId ||
        !allowed(peer['device_id'])) {
      throw StateError('Peer is not permitted in this mesh.');
    }
    final body = await verify(peer['sign_key'], message);
    if (expectedDevice != null && peer['device_id'] != expectedDevice) {
      throw StateError('The responding phone is not the selected peer.');
    }
    if (expectedPeer != null &&
        [
          'device_id',
          'account_id',
          'mesh_id',
          'sign_key',
          'box_key',
        ].any((field) => peer[field] != expectedPeer[field])) {
      throw StateError('Peer identity changed during the exchange.');
    }
    if (expectedRequest != null && body['request_id'] != expectedRequest) {
      throw StateError('Peer response does not match request.');
    }
    if (body['at'] is! int || (body['at'] - nowSeconds).abs() > 120) {
      throw StateError('Peer clock differs by more than two minutes');
    }
    if (body['request_id'] is! String ||
        body['request_id'].isEmpty ||
        body['request_id'].length > 80) {
      throw StateError('Invalid request identity');
    }
    await store.savePeer(peer['device_id'], cert);
    return {
      'peer': peer,
      'command': body['command'],
      'request_id': body['request_id'],
      'at': body['at'],
    };
  }

  Future<Json> handleRpc(Json message) async {
    if (!relay) throw StateError('Nearby relay is off');
    final checked = await validateRpc(message);
    final rid = checked['request_id'];
    final cmd = Map<String, dynamic>.from(checked['command']);
    final peer = Map<String, dynamic>.from(checked['peer']);
    await store.claimRpc(peer['device_id'], rid, checked['at']);
    final response = await command(cmd, peer);
    if (cmd['op'] == 'inventory' && (cmd['offset'] ?? 0) == 0) {
      final online = cmd['online'];
      _rememberPeer(peer, online: online is bool ? online : null);
    }
    return signedRpc(response, rid);
  }

  Future<Json> command(Json cmd, Json peer) async {
    switch (cmd['op']) {
      case 'connection_request':
        final id = peer['device_id'] as String;
        if (!canPay) {
          return {'op': 'connection', 'state': 'offline', 'expiry': nowSeconds};
        }
        final fresh = await store.requestConnection(
          id,
          (peer['display_name'] ?? peer['account_id'] ?? 'Nearby phone')
              as String,
        );
        final state = await store.connection(id);
        if (fresh) {
          await reload();
          notifyListeners();
          try {
            await background?.noticeConnection(id, state!['name'] as String);
          } catch (_) {}
        }
        return {
          'op': 'connection',
          'state': state?['state'] ?? 'expired',
          'expiry': state?['expiry'] ?? nowSeconds,
        };
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
      case 'proofs':
        if (cmd.containsKey('ids') || cmd.containsKey('receipt_id')) {
          final ids = cmd['ids'];
          final receiptId = cmd['receipt_id'];
          bool validId(Object? id) =>
              id is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(id);
          if ((ids != null && receiptId != null) ||
              (ids != null &&
                  (ids is! List ||
                      ids.length > 8 ||
                      ids.any((id) => !validId(id)))) ||
              (receiptId != null && !validId(receiptId)) ||
              (ids == null && receiptId == null)) {
            throw StateError('Invalid targeted proof request');
          }
          final all = ids is List
              ? await store.proofsForPackets(ids.cast<String>())
              : await store.proofs();
          final selected = <Json>[];
          for (final proof in all.where(
            (p) => ids != null
                ? (ids as List).contains(p['body']['packet_id'])
                : (p['body']['receipt_ids'] as List).contains(receiptId),
          )) {
            if (selected.length >= 8) break;
            if (canonical({
                  'proofs': [...selected, proof],
                }).length <
                maxRpcBytes - 2048) {
              selected.add(proof);
            }
          }
          return {'op': 'proofs', 'proofs': selected, 'next': null};
        }
        final offset = cmd['offset'] ?? 0;
        if (offset is! int || offset < 0 || offset > 1000) {
          throw StateError('Invalid proof cursor');
        }
        final all = await store.proofs();
        return {
          'op': 'proofs',
          'proofs': all.skip(offset).take(1).toList(),
          'next': offset + 1 < all.length ? offset + 1 : null,
        };
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
          'routing': 4,
          'proof_lookup': true,
          'connection_approval': false,
          'route_ready': bankReachable,
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
        if (p['kind'] == 'payment') return {'op': 'missing'};
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
        final response = <String, dynamic>{
          'op': 'packet',
          'packet': forwarded(p),
        };
        final proof = (await store.proofs())
            .where(
              (proof) =>
                  (proof['body']['receipt_ids'] as List).contains(p['id']),
            )
            .firstOrNull;
        if (proof != null &&
            canonical({...response, 'proof': proof}).length <
                maxRpcBytes - 2048) {
          response['proof'] = proof;
        }
        return response;
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
        if (cmd['proof'] is Map) {
          await receiveDeliveryProof(Map<String, dynamic>.from(cmd['proof']));
        }
        final p = Map<String, dynamic>.from(cmd['packet']);
        if (p['kind'] == 'payment') {
          throw StateError(
            'Payments require per-request acceptance; update the sending app.',
          );
        }
        await accept(p, fromPeer: peer['device_id'] as String);
        return {'op': 'stored', 'id': p['id']};
      case 'offer':
        final raw = cmd['packet'];
        if (raw is! Map) throw StateError('Invalid relay invitation');
        final p = Map<String, dynamic>.from(raw);
        if (p['kind'] != 'payment') {
          throw StateError('Only payments need approval');
        }
        if (cmd['deadline'] is! int ||
            cmd['token'] is! String ||
            (cmd['token'] as String).length != 48 ||
            cmd['deadline'] <= nowSeconds ||
            cmd['deadline'] > nowSeconds + 35 ||
            cmd['deadline'] > p['expires_at']) {
          throw StateError('Invalid or closed payment offer');
        }
        final state = await receiveOffer(
          p,
          peer,
          deadline: cmd['deadline'],
          token: cmd['token'],
        );
        return {
          'op': 'offer',
          'id': p['id'],
          'state': state == 'new' ? 'pending' : state,
        };
      default:
        throw StateError('Unknown peer command');
    }
  }

  Json forwarded(Json p) {
    return RelayRouting.forward(p, deviceId);
  }

  Future<String> receiveOffer(
    Json packet,
    Json peer, {
    int? deadline,
    String? token,
  }) async {
    final name =
        (peer['display_name'] ?? peer['account_id'] ?? 'Nearby phone')
            as String;
    if ((packet['trail'] as List? ?? []).contains(deviceId)) {
      throw StateError('Payment route loops back to this phone');
    }
    if (packet['expires_at'] > nowSeconds + 660) {
      throw const FormatException('Invalid payment retention');
    }
    final state = await store.invite(
      packet,
      peer['device_id'] as String,
      name,
      deadline: deadline,
      token: token,
    );
    if (state == 'new') {
      invitations = await store.invitations();
      if (!_disposed) notifyListeners();
      // Android notification delivery must not delay the storage acknowledgement.
      unawaited(
        background
            ?.noticeRequest(packet['id'] as String, name)
            .catchError((Object _) {}),
      );
    }
    return state;
  }

  Future<void> accept(Json p, {String? fromPeer}) async {
    await checkPacket(p);
    if (p['expires_at'] <= nowSeconds) {
      throw StateError('Packet retention expired');
    }
    final maximum = p['kind'] == 'payment' ? 600 : 7 * 86400;
    if (p['expires_at'] > nowSeconds + maximum + 60) {
      throw const FormatException(
        'Packet retention exceeds the protocol limit',
      );
    }
    bool ownedReceipt = false;
    if (p['kind'] == 'receipt') {
      Json? signed;
      try {
        signed = await openBox(encryption, Map<String, dynamic>.from(p['box']));
      } catch (_) {
        // Other phones' receipts remain opaque relay traffic.
      }
      if (signed != null) {
        final result = await verify(trust['sign_key'], signed);
        ownedReceipt = result['device_id'] == deviceId;
      }
    }
    if (p['kind'] == 'receipt' && !ownedReceipt && fromPeer != null) {
      final known = await store.proofs();
      if (!known.any(
        (proof) => (proof['body']['receipt_ids'] as List).contains(p['id']),
      )) {
        throw const FormatException(
          'Receipt has no authenticated bank delivery proof',
        );
      }
    }
    final inserted = await store.putPacket(
      p,
      owned: ownedReceipt,
      source: fromPeer,
    );
    if (inserted && p['kind'] == 'payment' && bankReachable) {
      _urgentBankWork = true;
      nextBankAttempt = DateTime.now();
      if (timer?.isActive == true) unawaited(gatewayTick());
    }
    // Store before delivering or acknowledging. Crash recovery replays cached
    // signed receipts, never loses a packet after a successful storage ACK.
    if (p['kind'] == 'receipt') await deliverReceipt(p);
    if (inserted) {
      await log(
        'Stored encrypted ${p['kind']} packet ${p['id'].toString().substring(0, 8)}.',
      );
      if (p['kind'] == 'receipt' && relay) {
        // A newly stored result should be offered back now, rather than wait
        // behind the idle-peer cooldown or another bank polling interval.
        peerRetry.clear();
        if (timer?.isActive == true) unawaited(tick());
      }
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
    if (local != null && !['paid', 'rejected'].contains(local['state'])) {
      try {
        await background?.noticeResult(
          r['payment_id'] as String,
          r['status'] as String,
        );
      } catch (_) {}
    }
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

  void _rememberPeer(Json identity, {bool? online, bool? routeReady}) {
    if (_disposed || !relay) return;
    final id = identity['device_id'] as String;
    final previous = nearby.where((p) => p['device_id'] == id).firstOrNull;
    final radioId = identityByRadio.entries
        .where((e) => e.value == id)
        .firstOrNull
        ?.key;
    final entry = <String, dynamic>{
      'device_id': id,
      'name': identity['display_name'] ?? identity['account_id'] ?? id,
      'online': online ?? previous?['online'] ?? false,
      'route_ready': routeReady ?? online ?? previous?['route_ready'] ?? false,
      'rssi': _radio?.discovered[radioId]?.rssi ?? previous?['rssi'],
      'at': nowSeconds,
    };
    nearby.remove(previous);
    nearby.add(entry);
    notifyListeners();
  }

  Future<void> syncPeer(PeerRadio peer) async {
    final key = peer.peripheral.uuid.toString();
    final selectedDevice = identityByRadio[key];
    await radio.connect<void>(peer, (raw) async {
      Json? peerIdentity;
      Future<Json> rpc(Json cmd) async {
        final rid = const Uuid().v4();
        final response = await raw(await signedRpc(cmd, rid));
        final checked = await validateRpc(
          response,
          expectedRequest: rid,
          expectedPeer: peerIdentity,
          expectedDevice: selectedDevice,
        );
        peerIdentity = Map<String, dynamic>.from(checked['peer']);
        identityByRadio[key] = peerIdentity!['device_id'];
        // A successful authenticated exchange proves this peer is still here,
        // even while scanning is paused for its GATT transfer.
        peer.seen = DateTime.now();
        return Map<String, dynamic>.from(checked['command']);
      }

      await syncPackets(rpc, () => peerIdentity!);
    });
    lastError = null;
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
    bool remoteRouteReady = false;
    int remoteRouting = 0;
    bool targetedProofs = false;
    while (offset != null) {
      final remote = await rpc({
        'op': 'inventory',
        'offset': offset,
        'online': bankReachable,
      });
      if (remote['op'] != 'inventory' ||
          remote['device_id'] != peerIdentity()['device_id'] ||
          remote['ids'] is! List ||
          remote['ids'].length > 48 ||
          remote['ids'].any((id) => id is! String || id.length != 64)) {
        throw StateError('Invalid inventory');
      }
      peerOnline = remote['online'] == true;
      remoteRouteReady = remote['route_ready'] == true;
      remoteRouting = remote['routing'] is int ? remote['routing'] as int : 0;
      targetedProofs = remote['proof_lookup'] == true;
      remoteIds.addAll((remote['ids'] as List).cast<String>());
      if (remote['routing'] == 2 ||
          remote['routing'] == 3 ||
          remote['routing'] == 4) {
        final routes = remote['routes'];
        if (routes is! List || routes.length != remote['ids'].length) {
          throw StateError('Invalid route inventory');
        }
        for (final item in routes) {
          if (item is! Map ||
              !remote['ids'].contains(item['id']) ||
              item['hops'] is! int ||
              item['hops'] < 0 ||
              item['hops'] > maxRelayHops ||
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
    _awaitingPeer.remove(peerId);
    _rememberPeer(identity, online: peerOnline, routeReady: remoteRouteReady);
    if (remoteRouting == 4 && targetedProofs) {
      final unresolved = await store.missingProofIds();
      if (unresolved.isNotEmpty) {
        final offset = _proofRound % unresolved.length;
        final ids = [
          ...unresolved.skip(offset),
          ...unresolved.take(offset),
        ].take(8).toList();
        _proofRound += ids.length;
        final page = await rpc({'op': 'proofs', 'ids': ids});
        if (page['op'] != 'proofs' ||
            page['proofs'] is! List ||
            page['proofs'].length > ids.length ||
            page['next'] != null) {
          throw StateError('Invalid targeted proof response');
        }
        for (final proof in page['proofs']) {
          if (proof is! Map ||
              proof['body'] is! Map ||
              !ids.contains(proof['body']['packet_id'])) {
            throw StateError('Peer returned an unrelated delivery proof');
          }
          await receiveDeliveryProof(Map<String, dynamic>.from(proof));
        }
      }
    } else if (remoteRouting == 4) {
      int? proofOffset = 0;
      while (proofOffset != null) {
        final page = await rpc({'op': 'proofs', 'offset': proofOffset});
        if (page['op'] != 'proofs' ||
            page['proofs'] is! List ||
            page['proofs'].length > 16) {
          throw StateError('Invalid proof page');
        }
        for (final proof in page['proofs']) {
          await receiveDeliveryProof(Map<String, dynamic>.from(proof));
        }
        final next = page['next'];
        if (next != null &&
            (next is! int || next <= proofOffset || next > 1000)) {
          throw StateError('Invalid proof cursor');
        }
        proofOffset = next;
      }
    }
    final local = await store.packets();
    final localById = {for (final p in local) p['id']: p};
    // A signed inventory also repairs an ACK lost after the peer committed its
    // copy. Always retain our original until a verified bank result is known.
    for (final id in remoteIds.where(localById.containsKey)) {
      final p = localById[id]!;
      await store.offerResult(id, peerId, 'accepted');
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
      if (item['kind'] == 'payment') continue;
      final id = item['id'] as String;
      final value = await rpc({'op': 'get', 'id': id, 'online': bankReachable});
      if (value['op'] == 'packet') {
        final packet = Map<String, dynamic>.from(value['packet']);
        if (packet['id'] != id) {
          throw StateError('Peer returned a different packet than requested.');
        }
        final needsApproval = packet['kind'] == 'payment';
        if (needsApproval) {
          await receiveOffer(packet, identity);
        } else {
          if (value['proof'] is Map) {
            final proof = Map<String, dynamic>.from(value['proof']);
            if (proof['body']?['receipt_ids'] is! List ||
                !(proof['body']['receipt_ids'] as List).contains(id)) {
              throw StateError('Delivery proof is for another receipt');
            }
            await receiveDeliveryProof(proof);
          } else if (targetedProofs &&
              !(await store.proofs()).any(
                (proof) => (proof['body']['receipt_ids'] as List).contains(id),
              )) {
            final page = await rpc({'op': 'proofs', 'receipt_id': id});
            if (page['op'] != 'proofs' ||
                page['proofs'] is! List ||
                page['proofs'].length > 8 ||
                page['next'] != null) {
              throw StateError('Invalid receipt proof response');
            }
            for (final proof in page['proofs']) {
              if (proof is! Map ||
                  proof['body'] is! Map ||
                  proof['body']['receipt_ids'] is! List ||
                  !(proof['body']['receipt_ids'] as List).contains(id)) {
                throw StateError('Peer returned an unrelated receipt proof');
              }
              await receiveDeliveryProof(Map<String, dynamic>.from(proof));
            }
          }
          await accept(packet, fromPeer: peerId);
        }
        if (!needsApproval && remoteRoutes.containsKey(id)) {
          final ack = await rpc({'op': 'ack', 'id': id});
          if (ack['op'] != 'acknowledged' || ack['id'] != id) {
            throw StateError('Peer did not accept durable acknowledgement');
          }
        }
      }
    }
    final outgoing = <Json>[];
    for (final p in await store.packets()) {
      if (!RelayRouting.canForward(p, deviceId, peerId) ||
          (remoteIds.contains(p['id']) &&
              !RelayRouting.improves(
                p,
                remoteRoutes[p['id']]?['hops'] as int?,
              ))) {
        continue;
      }
      if (p['kind'] == 'payment' &&
          (remoteRouting != 4 || p['uploaded'] == 1)) {
        continue;
      }
      outgoing.add(p);
    }
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
      Json? offer;
      if (p['kind'] == 'payment') {
        // The scheduler prefers reachable gateways. After the discovery grace,
        // an old gateway advertisement or a decline must not veto this carrier.
        if (!peerOnline && _radio is BleTransport) {
          _discoveryStarted.removeWhere((_, at) => at < nowSeconds - 660);
          final started = _discoveryStarted.putIfAbsent(
            p['id'],
            () => nowSeconds,
          );
          if (nowSeconds - started < 3) {
            _awaitingPeer.add(peerId);
            continue;
          }
        }
        offer = await store.offerFor(p['id'], peerId, p['expires_at']);
        if (offer == null) continue;
        await store.deliveryText(
          p['id'],
          'Waiting for a nearby phone to accept',
        );
      }
      final proof = p['kind'] == 'receipt'
          ? (await store.proofs())
                .where(
                  (proof) =>
                      (proof['body']['receipt_ids'] as List).contains(p['id']),
                )
                .firstOrNull
          : null;
      final response = await rpc({
        'proof': ?proof,
        'op': p['kind'] == 'payment' ? 'offer' : 'put',
        'packet': forwarded(p),
        if (offer != null) 'deadline': offer['deadline'],
        if (offer != null) 'token': offer['token'],
      });
      if (response['op'] == 'offer' && response['id'] == p['id']) {
        if (response['state'] == 'pending') {
          _awaitingPeer.add(peerId);
          sent++;
          continue;
        }
        if (response['state'] == 'declined' || response['state'] == 'expired') {
          await store.offerResult(p['id'], peerId, response['state'] as String);
          await store.clearRoute(p['id'] as String);
          await log(
            'Nearby offer closed. Automatically looking for another phone.',
          );
          sent++;
          continue;
        }
        if (response['state'] == 'accepted') {
          await store.offerResult(p['id'], peerId, 'accepted');
          // The peer already committed the packet; treat this as a storage ACK.
          for (final intent in payments.where(
            (x) => x['packet_id'] == p['id'],
          )) {
            await store.markRelayed(intent['payment_id']);
          }
          await store.acknowledge(
            p['id'],
            peerId,
            p['hops'] + 1,
            p['expires_at'],
          );
          sent++;
          continue;
        }
      }
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

  Future<Json> _verifiedProofBody(Json proof) async {
    final b = await verify(trust['sign_key'], proof);
    if (b['v'] != 1 ||
        b['type'] != 'delivery_proof' ||
        b['mesh_id'] != trust['mesh_id'] ||
        b['packet_id'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(b['packet_id']) ||
        b['receipt_ids'] is! List ||
        b['receipt_ids'].isEmpty ||
        b['receipt_ids'].length > 100 ||
        b['receipt_ids'].any(
          (id) => id is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(id),
        ) ||
        b['recorded_at'] is! int ||
        b['recorded_at'] > nowSeconds + 60 ||
        b['expires_at'] is! int ||
        b['expires_at'] <= nowSeconds ||
        b['expires_at'] > b['recorded_at'] + 7 * 86400) {
      throw const FormatException('Invalid bank delivery proof');
    }
    return b;
  }

  Future<void> receiveDeliveryProof(Json proof) async {
    final body = await _verifiedProofBody(proof);
    await _saveVerifiedProof(proof, body);
  }

  Future<void> _saveVerifiedProof(Json proof, Json body) async {
    await store.saveProof(proof);
    await store.deliveryText(
      body['packet_id'],
      'Bank recorded a result. Waiting for your private receipt.',
    );
  }

  Future<void> _receiveSubmission(Json result, String expectedPacket) async {
    if (result['delivery_proof'] is! Map) {
      throw StateError('Bank update required for payment delivery proofs');
    }
    final proof = Map<String, dynamic>.from(result['delivery_proof']);
    final body = await _verifiedProofBody(proof);
    if (body['packet_id'] != expectedPacket) {
      throw const FormatException('Bank proof is for another request');
    }
    final expected = (body['receipt_ids'] as List).toSet();
    final batch = result['receipts'];
    if (batch is! List || batch.length != expected.length) {
      throw const FormatException('Incomplete bank receipt response');
    }
    for (final value in batch) {
      if (value is! Map ||
          value['kind'] != 'receipt' ||
          !expected.remove(value['id'])) {
        throw const FormatException(
          'Receipt differs from the signed bank response',
        );
      }
      await accept(Map<String, dynamic>.from(value));
    }
    // Saving the proof marks this packet uploaded. An interrupted receipt
    // batch must leave the original eligible for idempotent resubmission.
    await _saveVerifiedProof(proof, body);
  }

  Future<void> _receiveBankReceipts(Object? values) async {
    if (values is! List) throw const FormatException('Invalid receipt batch');
    for (final value in values) {
      Json packet;
      try {
        if (value is! Map || value.keys.any((key) => key is! String)) {
          throw const FormatException('Invalid receipt entry');
        }
        packet = Map<String, dynamic>.from(value);
        await checkPacket(packet);
        if (packet['kind'] != 'receipt') {
          throw const FormatException('Expected a bank receipt');
        }
      } on FormatException {
        await store.event('Ignored an invalid bank receipt.');
        continue;
      } on ArgumentError {
        await store.event('Ignored an invalid bank receipt.');
        continue;
      }
      try {
        await accept(packet);
      } on PacketStorageFull {
        rethrow; // Retain the inbox cursor so an unsaved receipt can retry.
      } on FormatException {
        await store.event('Ignored an invalid bank receipt.');
      } on StateError {
        await store.event('Ignored an unverifiable or expired bank receipt.');
      }
      // Database/filesystem failures intentionally propagate; never skip them.
    }
  }

  Future<void> gatewayTick() {
    if (_disposed) return Future<void>.value();
    return _gatewayWork ??= _runGatewayTick().whenComplete(() {
      _gatewayWork = null;
      if (_urgentBankWork && bankReachable && !_disposed) {
        nextBankAttempt = DateTime.now();
        unawaited(gatewayTick());
      }
    });
  }

  Future<void> _runGatewayTick() async {
    if (DateTime.now().isBefore(nextBankAttempt)) return;
    _urgentBankWork = false;
    try {
      if (!liveConnected) {
        final health = await _verifiedHealth();
        if (health['fingerprint'] != trust['fingerprint']) {
          throw StateError('Bank trust changed. Stop and verify bank setup.');
        }
        if (health['online'] != true) {
          throw BankFailure(503, 'Demo bank is paused');
        }
      }
      network = 'Connected to bank';
      final pendingPackets = (await store.packets())
          .where(
            (p) =>
                p['kind'] == 'payment' &&
                p['uploaded'] == 0 &&
                (relay || payments.any((x) => x['packet_id'] == p['id'])),
          )
          .toList();
      final ownIds = payments.map((p) => p['packet_id']).toSet();
      pendingPackets.sort(
        (a, b) => (ownIds.contains(a['id']) ? 0 : 1).compareTo(
          ownIds.contains(b['id']) ? 0 : 1,
        ),
      );
      for (final p in pendingPackets.take(6)) {
        final clean = Map<String, dynamic>.from(p)..remove('uploaded');
        try {
          final result = await submitPacket(clean);
          // Persist every receipt before marking this submission complete.
          await _receiveSubmission(result, p['id']);
          await store.uploaded(p['id']);
          if (!ownIds.contains(p['id'])) {
            try {
              await background?.noticeSubmitted(p['id'] as String);
            } catch (_) {}
          }
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
      if (!liveConnected) {
        final own = await request(
          '/api/receipts/$deviceId?after=$_inboxCursor',
        );
        await _receiveBankReceipts(own['receipts']);
        _inboxCursor = max(_inboxCursor, own['cursor'] as int);
        await store.saveConfig('inbox_cursor:$deviceId', _inboxCursor);
      }
      // Recover a committed result if the gateway lost the HTTP response, including after expiry.
      final cached = await store.packets(activeOnly: false);
      final receiptCaps = cached
          .where((p) => p['kind'] == 'receipt')
          .map((p) => p['mailbox'])
          .toSet();
      final terminalCaps = (await store.payments())
          .where((p) => ['paid', 'rejected'].contains(p['state']))
          .map((p) => p['sender_mailbox'])
          .toSet();
      final queriedMailboxes = <String>{};
      for (final p
          in cached
              .where(
                (p) =>
                    p['kind'] == 'payment' &&
                    !receiptCaps.contains(p['mailbox']) &&
                    !terminalCaps.contains(p['mailbox']),
              )
              .take(6)) {
        queriedMailboxes.add(p['mailbox'] as String);
        final recovered = await request('/api/mailbox/${p['mailbox']}');
        await _receiveBankReceipts(recovered['receipts']);
        if ((recovered['receipts'] as List).isEmpty &&
            p['expires_at'] <= nowSeconds) {
          // Ask the bank to resolve the ORIGINAL expired authorization. A
          // previous commit returns its original paid receipt; an unprocessed
          // expiry returns a signed rejection. Never extend TTL or invent a
          // local cancellation to release reserved funds.
          final original = Map<String, dynamic>.from(p)..remove('uploaded');
          final result = await submitPacket(original);
          await _receiveSubmission(result, p['id']);
          await store.uploaded(p['id']);
        }
      }
      // Resolve unknown outcomes even after local payment authorization expiry.
      for (final intent
          in (await store.payments())
              .where((p) => !['paid', 'rejected'].contains(p['state']))
              .take(12)) {
        if (!queriedMailboxes.add(intent['sender_mailbox'] as String)) continue;
        final result = await request(
          '/api/mailbox/${intent['sender_mailbox']}',
        );
        await _receiveBankReceipts(result['receipts']);
      }
      bankReachable = true;
      _bankWorkDelayed = false;
      connectionUnstable = false;
      bankAttention = null;
      _connectionFailures = 0;
      backoffSeconds = 5;
      nextBankAttempt = DateTime.now().add(const Duration(seconds: 30));
    } catch (e) {
      _bankWorkDelayed = _temporaryBankError(e);
      _connectionProblem(e);
      nextBankAttempt = DateTime.now().add(Duration(seconds: backoffSeconds));
      _nextHealthAttempt = nextBankAttempt;
      backoffSeconds = (backoffSeconds * 2).clamp(5, 60);
    }
  }

  Future<void> tick() async {
    if (working || _recipientLookupWaiting || profile == null || _disposed) {
      return;
    }
    working = true;
    try {
      await restoreBackgroundRelay();
      // Start bank delivery promptly, but a slow internet request must never
      // own the Bluetooth/UI work lock. The bank worker coalesces all callers.
      if (bankReachable || gateway) {
        unawaited(gatewayTick());
      }
      if (relay && radio.running) {
        final selectedRoutes = <String>{?connectedPeer};
        for (final packet in await store.packets()) {
          if (packet['kind'] == 'payment') {
            final selected = await store.route(packet['id'] as String);
            if (selected != null) selectedRoutes.add(selected);
          }
        }
        final now = DateTime.now();
        final candidates = radio.discovered.values.where((p) {
          final key = p.peripheral.uuid.toString();
          final id = identityByRadio[key];
          return now.difference(p.seen) < const Duration(seconds: 25) &&
              !(peerRetry[key]?.isAfter(now) ?? false) &&
              (id == null || allowed(id));
        }).toList();
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
                selectedRoutes.contains(
                  identityByRadio[p.peripheral.uuid.toString()],
                )
                ? -1
                : nearby.any(
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
        for (final peer in peers.take(2)) {
          if (_manualConnectionWaiting) break;
          final id = peer.peripheral.uuid.toString();
          try {
            await syncPeer(peer);
            peerFailures[id] = 0;
            peerRetry[id] = DateTime.now().add(
              Duration(
                milliseconds: _awaitingPeer.contains(identityByRadio[id])
                    ? 1000 + _jitter.nextInt(700)
                    : 7000 + _jitter.nextInt(3000),
              ),
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
      // Offline senders ask relays for cached receipts by normal inventory exchange.
      // Gateway relays recover their cached original submissions through idempotent retry.
      await store.cleanup();
      await reload();
      if (backgroundActive) {
        await background?.update(
          relayBlocked ??
              'Nearby delivery active · ${bankReachable ? "Bank reachable" : "Looking for bank access"}',
        );
      }
      nearby.removeWhere((p) => p['at'] < nowSeconds - 45);
    } catch (e) {
      lastError = e.toString();
    } finally {
      working = false;
      if (_urgentBankWork && bankReachable && !_disposed) {
        unawaited(gatewayTick());
      }
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> retryNow({bool checkBank = false}) async {
    nextBankAttempt = DateTime.now();
    peerRetry.clear();
    final probe = checkBank ? checkConnection() : null;
    await tick();
    if (probe != null) {
      await probe;
      if (bankReachable && !_disposed) await gatewayTick();
    }
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
