import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'engine.dart';
import 'payment_pin.dart';
import 'bank_setup_code.dart';
import 'bank_setup_scan.dart';
import 'protocol.dart';
import 'nearby_permissions.dart';

const ink = Color(0xff143b3b),
    teal = Color(0xff008876),
    lime = Color(0xffc9ef82),
    canvas = Color(0xfff4f7f5),
    muted = Color(0xff788b86);
String rupees(dynamic paise) => '₹${((paise as num) / 100).toStringAsFixed(2)}';
String stamp(dynamic seconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(
    (seconds as int) * 1000,
  ).toLocal();
  return '${d.day}/${d.month} · ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String short(String value) =>
    value.length > 10 ? '${value.substring(0, 8)}…' : value;
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BeyondNetApp());
}

class BeyondNetApp extends StatefulWidget {
  const BeyondNetApp({super.key});
  @override
  State<BeyondNetApp> createState() => _BeyondNetAppState();
}

class _BeyondNetAppState extends State<BeyondNetApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && engine.ready) {
      unawaited(engine.checkConnection());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    engine.dispose();
    super.dispose();
  }

  final engine = BeyondNetEngine();
  late final Future<void> initialized = engine.init();
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'BeyondNet',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: teal,
        primary: teal,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: canvas,
      appBarTheme: const AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: false,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 34,
          fontWeight: FontWeight.w700,
          color: ink,
          letterSpacing: -1.2,
        ),
        headlineMedium: TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w700,
          color: ink,
          letterSpacing: -.7,
        ),
        titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: ink,
        ),
        bodyMedium: TextStyle(color: ink, height: 1.4),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xffdfe8e3)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xffdfe8e3)),
        ),
        contentPadding: const EdgeInsets.all(17),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 17),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    ),
    home: FutureBuilder(
      future: initialized,
      builder: (context, s) {
        if (s.hasError) {
          return Scaffold(
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.lock_outline, size: 48, color: teal),
                    const SizedBox(height: 20),
                    const Text(
                      'Device setup needs attention',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('${s.error}'),
                    const SizedBox(height: 12),
                    const Text(
                      'Your local data has been preserved. Check device storage and restart the app.',
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        if (s.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return ListenableBuilder(
          listenable: engine,
          builder: (context, _) => engine.profile == null
              ? LoginPage(engine: engine)
              : Shell(engine: engine),
        );
      },
    ),
  );
}

class Brand extends StatelessWidget {
  const Brand({super.key});
  @override
  Widget build(BuildContext context) => const Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.blur_on_rounded, color: teal, size: 32),
      SizedBox(width: 7),
      Text(
        'Beyond',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 24,
          letterSpacing: -1,
        ),
      ),
      Text(
        'Net',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 24,
          color: teal,
          letterSpacing: -1,
        ),
      ),
    ],
  );
}

class Box extends StatelessWidget {
  final Widget child;
  final Color? color;
  const Box({super.key, required this.child, this.color});
  @override
  Widget build(BuildContext context) => Material(
    color: color ?? Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: Color(0xffe5ece7)),
    ),
    child: SizedBox(
      width: double.infinity,
      child: Padding(padding: const EdgeInsets.all(20), child: child),
    ),
  );
}

class Eyebrow extends StatelessWidget {
  final String text;
  const Eyebrow(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: const TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.6,
      color: muted,
    ),
  );
}

class Hint extends StatelessWidget {
  final String text;
  const Hint(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(color: muted, fontSize: 12, height: 1.6),
  );
}

Future<void> alert(BuildContext c, Object error) async {
  if (!c.mounted) return;
  await showDialog(
    context: c,
    builder: (c) => AlertDialog(
      title: const Text('Needs your attention'),
      content: Text(
        error.toString().replaceFirst(
          RegExp(r'^(Bad state|Invalid argument\(s\)): '),
          '',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}

class LoginPage extends StatefulWidget {
  final BeyondNetEngine engine;
  final bool renewal;
  final Future<String?> Function()? scanBankCode;
  final Future<String?> Function()? pickBankCode;
  const LoginPage({
    super.key,
    required this.engine,
    this.renewal = false,
    this.scanBankCode,
    this.pickBankCode,
  });
  @override
  State<LoginPage> createState() => _LoginState();
}

class _LoginState extends State<LoginPage> {
  final url = TextEditingController(),
      account = TextEditingController(),
      password = TextEditingController(),
      fingerprint = TextEditingController(),
      name = TextEditingController();
  bool busy = false, visible = false, signup = true;
  String role = 'customer';
  bool importingBank = false;
  String? bankSetupStatus;
  @override
  void initState() {
    super.initState();
    if (widget.renewal) {
      signup = false;
      url.text = widget.engine.bankUrl;
      account.text = widget.engine.accountId;
      fingerprint.text = widget.engine.trust['fingerprint'];
    }
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          final raw = await recoverBankSetupImage();
          if (raw != null && mounted) await reviewBankCode(raw);
        } catch (error) {
          if (mounted) await alert(context, error);
        }
      });
    }
  }

  @override
  void dispose() {
    for (final c in [url, account, password, fingerprint, name]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> reviewBankCode(String raw) async {
    final code = BankSetupCode.parse(raw);
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Use this bank?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Bank HTTPS URL'),
              SelectableText(code.url),
              const SizedBox(height: 12),
              const Text('Bank fingerprint'),
              SelectableText(code.fingerprint),
              const SizedBox(height: 12),
              const Text(
                'Only use a setup QR from your trusted bank dashboard. The app will verify this fingerprint before sending account details.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Use bank details'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      setState(() {
        url.text = code.url;
        fingerprint.text = code.fingerprint;
        bankSetupStatus =
            'Bank details filled from QR. Complete your account details below.';
      });
    }
  }

  Future<void> importBankCode(bool fromGallery) async {
    setState(() => importingBank = true);
    try {
      final String? raw;
      if (fromGallery) {
        raw = await (widget.pickBankCode ?? pickBankSetupImage)();
      } else {
        raw = widget.scanBankCode != null
            ? await widget.scanBankCode!()
            : await Navigator.push<String>(
                context,
                MaterialPageRoute(builder: (_) => const BankSetupScanPage()),
              );
      }
      if (raw != null && mounted) await reviewBankCode(raw);
    } catch (error) {
      if (mounted) await alert(context, error);
    } finally {
      if (mounted) setState(() => importingBank = false);
    }
  }

  Future<void> submit() async {
    setState(() => busy = true);
    try {
      await widget.engine.enroll(
        url.text,
        account.text,
        password.text,
        fingerprint.text,
        name: signup ? name.text : null,
        role: signup ? role : null,
      );
      if (mounted && widget.renewal) Navigator.pop(context);
    } catch (e) {
      if (mounted) await alert(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: widget.renewal
        ? AppBar(title: const Text('Renew online access'))
        : null,
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(26),
            children: [
              const SizedBox(height: 22),
              const Brand(),
              const SizedBox(height: 45),
              const Eyebrow('YOUR SIGNAL IS ENOUGH'),
              const SizedBox(height: 12),
              Text(
                widget.renewal
                    ? 'Reconnect securely.'
                    : signup
                    ? 'Your money.\nMore ways to pay.'
                    : 'Welcome back.',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 15),
              const Hint(
                'Set up online once. Then let nearby participating phones carry your encrypted payment to the demo bank.',
              ),
              const SizedBox(height: 22),
              if (!widget.renewal) ...[
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Create account')),
                    ButtonSegment(value: false, label: Text('Sign in')),
                  ],
                  selected: {signup},
                  onSelectionChanged: busy
                      ? null
                      : (v) => setState(() => signup = v.first),
                ),
                const SizedBox(height: 18),
              ],
              if (signup) ...[
                const Text(
                  'How will you use BeyondNet?',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'customer',
                      icon: Icon(Icons.person_outline),
                      label: Text('Personal'),
                    ),
                    ButtonSegment(
                      value: 'merchant',
                      icon: Icon(Icons.storefront_outlined),
                      label: Text('Merchant'),
                    ),
                  ],
                  selected: {role},
                  onSelectionChanged: busy
                      ? null
                      : (v) => setState(() => role = v.first),
                ),
                const SizedBox(height: 8),
                Hint(
                  role == 'merchant'
                      ? 'Receive payments with your store QR. You can also help nearby phones relay.'
                      : 'Pay by ID or QR. You can also help nearby phones relay.',
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: name,
                  decoration: InputDecoration(
                    labelText: role == 'merchant'
                        ? 'Business name'
                        : 'Your name',
                  ),
                ),
                const SizedBox(height: 14),
              ],
              const Text(
                'Set up your bank',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy || importingBank
                        ? null
                        : () => importBankCode(false),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan bank QR'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy || importingBank
                        ? null
                        : () => importBankCode(true),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Choose QR image'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Hint(
                bankSetupStatus ??
                    'Scan or choose the bank setup QR to fill both fields, or enter them manually.',
              ),
              const SizedBox(height: 14),
              TextField(
                controller: url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Bank HTTPS URL',
                  hintText: 'https://your-bank.example',
                  prefixIcon: Icon(Icons.account_balance_outlined),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: account,
                autocorrect: false,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Payment ID',
                  hintText: 'yourname@beyondnet',
                  prefixIcon: Icon(Icons.alternate_email),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: password,
                obscureText: !visible,
                decoration: InputDecoration(
                  labelText: 'Password (at least 8 characters)',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => visible = !visible),
                    icon: Icon(
                      visible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: fingerprint,
                autocorrect: false,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Bank trust fingerprint',
                  hintText:
                      'Paste the 64-character fingerprint from Device setup on the laptop',
                ),
              ),
              const SizedBox(height: 10),
              const Hint(
                'Compare this fingerprint with your laptop before enrolling. It pins the bank’s signing and encryption keys.',
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: busy || importingBank ? null : submit,
                child: busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        widget.renewal
                            ? 'Renew access'
                            : signup
                            ? 'Create account & continue'
                            : 'Sign in securely',
                      ),
              ),
              const SizedBox(height: 20),
              const SizedBox(height: 25),
              const Center(
                child: Hint('DEMO MONEY ONLY · NO REAL UPI CREDENTIALS'),
              ),
              const SizedBox(height: 15),
            ],
          ),
        ),
      ),
    ),
  );
}

class Shell extends StatefulWidget {
  final BeyondNetEngine engine;
  const Shell({super.key, required this.engine});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  bool starting = false;
  BeyondNetEngine get e => widget.engine;
  Future<void> start() async {
    setState(() => starting = true);
    try {
      if (Platform.isAndroid) {
        await NearbyPermissions.ensureAndroidReady();
      }
      await e.startRelay();
    } catch (err) {
      if (mounted) await alert(context, err);
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  void open(Widget page) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: e,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: tab == 0
            ? const Brand()
            : Text(['', 'Activity', 'Nearby network', 'Your device'][tab]),
        actions: [
          IconButton(
            tooltip: 'Device settings',
            onPressed: () => setState(() => tab = 3),
            icon: CircleAvatar(
              radius: 17,
              backgroundColor: const Color(0xffe2efe7),
              child: Text(
                (e.account?['name'] ?? 'K').toString().substring(0, 1),
                style: const TextStyle(color: teal, fontSize: 14),
              ),
            ),
          ),
        ],
        toolbarHeight: 75,
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 650),
            child: [home(), activity(), nearbyPage(), settings()][tab],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        backgroundColor: Colors.white,
        indicatorColor: const Color(0xffdef0e7),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            label: 'Activity',
          ),
          NavigationDestination(
            icon: Icon(Icons.hub_outlined),
            label: 'Nearby',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_rounded),
            label: 'Device',
          ),
        ],
      ),
    ),
  );
  Widget home() => ListView(
    padding: const EdgeInsets.fromLTRB(23, 12, 23, 28),
    children: [
      if (!e.pinConfigured) ...[
        FilledButton.icon(
          onPressed: () => open(PaymentPinPage(engine: e)),
          icon: const Icon(Icons.lock_outline),
          label: const Text('Set payment PIN while online'),
        ),
        const SizedBox(height: 16),
      ],
      Text(
        'Hello, ${e.account!['name'].toString().split(' ').first}',
        style: const TextStyle(fontSize: 15, color: muted),
      ),
      const SizedBox(height: 9),
      Text(
        e.isMerchant
            ? 'Ready for your\nnext customer.'
            : 'Pay your way.\nOnline or nearby.',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 18),
      connectionCard(),
      const SizedBox(height: 18),
      Container(
        padding: const EdgeInsets.all(25),
        decoration: BoxDecoration(
          color: ink,
          borderRadius: BorderRadius.circular(23),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'LAST CONFIRMED DEMO BALANCE',
              style: TextStyle(
                fontSize: 9,
                color: Color(0xffa3c1b7),
                letterSpacing: 1.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              rupees(e.account!['balance']),
              style: const TextStyle(
                fontSize: 38,
                color: Colors.white,
                fontWeight: FontWeight.w600,
                letterSpacing: -1,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.verified_user_outlined, color: lime, size: 15),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    e.accountId,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xffc4d6ce),
                    ),
                  ),
                ),
                Text(
                  stamp(e.profile!['balance_checked_at']),
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xff8fb1a4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            const Text(
              'Pending payments may change your available balance.',
              style: TextStyle(fontSize: 10, color: Color(0xff8fb1a4)),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.tonalIcon(
        onPressed: () => open(AddMoneyPage(engine: e)),
        icon: const Icon(Icons.add_circle_outline),
        label: const Text('Add demo money'),
      ),
      const SizedBox(height: 18),
      if (e.isMerchant)
        FilledButton.icon(
          onPressed: () => open(ReceivePage(engine: e)),
          icon: const Icon(Icons.qr_code_2),
          label: const Text('Show my payment QR'),
        )
      else
        Row(
          children: [
            Expanded(
              child: action(
                Icons.north_east_rounded,
                'Pay by ID',
                () => beginPay(),
                highlight: true,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: action(
                Icons.qr_code_scanner_rounded,
                'Scan QR',
                () => beginPay(scanCode: true),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: action(
                Icons.qr_code_2_rounded,
                'My QR',
                () => open(ReceivePage(engine: e)),
              ),
            ),
          ],
        ),
      const SizedBox(height: 18),
      Box(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Help as a nearby relay'),
              subtitle: const Text(
                'Available to personal and merchant accounts',
              ),
              value: e.relay,
              onChanged: starting
                  ? null
                  : (v) async {
                      if (v) {
                        await start();
                      } else {
                        await e.stopRelay();
                      }
                    },
            ),
            const Hint(
              'Needs Bluetooth on and BeyondNet open. Allow Nearby devices on Android 12+, or Location permission and Location on for Android 10–11. Internet is optional: when available, your phone forwards requests to the bank automatically.',
            ),
            TextButton(
              onPressed: () => setState(() => tab = 2),
              child: const Text('Nearby setup & connections'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 28),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Recent payments',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
          ),
          TextButton(
            onPressed: () => setState(() => tab = 1),
            child: const Text('View all'),
          ),
        ],
      ),
      if (e.isMerchant)
        Box(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Incoming payments',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              if (e.receipts
                  .where((r) => r['recipient'] == e.accountId)
                  .isEmpty)
                const Hint(
                  'Show your QR to a customer. Verified bank receipts appear in Activity.',
                ),
              ...e.receipts
                  .where((r) => r['recipient'] == e.accountId)
                  .take(3)
                  .map(
                    (r) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(rupees(r['amount'])),
                      subtitle: Text('${r['sender']} · ${r['status']}'),
                    ),
                  ),
            ],
          ),
        )
      else if (e.payments.isEmpty)
        const Box(
          child: Column(
            children: [
              Icon(Icons.send_outlined, color: muted, size: 30),
              SizedBox(height: 10),
              Text(
                'Your first payment starts here',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 7),
              Hint(
                'Choose Pay or scan a recipient’s code.\nA signed bank receipt confirms the result.',
              ),
            ],
          ),
        )
      else
        ...e.payments.take(3).map(paymentTile),
      const SizedBox(height: 24),
      const Center(
        child: Hint('ENCRYPTED BETWEEN PHONES · CONFIRMED BY THE BANK'),
      ),
    ],
  );
  Widget connectionCard() => Box(
    color: e.bankReachable ? const Color(0xffe2f2e8) : const Color(0xfffff3df),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(e.bankReachable ? Icons.wifi : Icons.wifi_off, color: teal),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                e.checkingConnection && e.internet == null
                    ? 'Checking your connection…'
                    : e.bankReachable
                    ? 'You’re online'
                    : e.internet == false
                    ? 'Your internet is off'
                    : 'Cannot reach the bank',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Check connection',
              onPressed: e.checkingConnection
                  ? null
                  : () => e.checkConnection(),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Hint(
          e.bankReachable
              ? 'Pay directly. ${e.liveConnected ? 'Live payment updates are connected.' : 'Payment status will sync automatically.'}'
              : 'You can still send a payment through a nearby phone. Enable Bluetooth, allow Nearby devices (Location access on Android 10–11), scan and connect to a verified relay.',
        ),
        if (!e.bankReachable) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => setState(() => tab = 2),
            icon: const Icon(Icons.bluetooth_searching),
            label: Text(
              e.canPay ? 'Nearby connection ready' : 'Set up offline payments',
            ),
          ),
          const SizedBox(height: 6),
          const Hint(
            'A relay connection does not guarantee an internet route. Only a bank receipt confirms payment.',
          ),
        ],
      ],
    ),
  );

  void beginPay({bool scanCode = false}) {
    if (!e.canPay) {
      setState(() => tab = 2);
      return;
    }
    if (scanCode) {
      unawaited(scan());
    } else {
      open(PayPage(engine: e));
    }
  }

  Widget action(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool highlight = false,
  }) => Material(
    color: highlight ? teal : Colors.white,
    borderRadius: BorderRadius.circular(17),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(17),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          children: [
            Icon(icon, color: highlight ? Colors.white : teal, size: 27),
            const SizedBox(height: 9),
            Text(
              label,
              style: TextStyle(
                color: highlight ? Colors.white : ink,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Future<void> scan() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (result == null) return;
    try {
      final qr = jsonDecode(result);
      if (qr['type'] != 'offline-karo/recipient/v1') {
        throw StateError('This is not a BeyondNet recipient code.');
      }
      final cert = Map<String, dynamic>.from(qr['certificate']);
      await e.addRecipient(cert);
      if (mounted) open(PayPage(engine: e, selected: cert));
    } catch (err) {
      if (mounted) await alert(context, err);
    }
  }

  Widget paymentTile(Json p) {
    final finalState = ['paid', 'rejected'].contains(p['state']);
    final expired = !finalState && p['expires_at'] < nowSeconds;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 17,
            vertical: 7,
          ),
          leading: CircleAvatar(
            backgroundColor: const Color(0xffedf4ef),
            child: Icon(
              p['state'] == 'paid'
                  ? Icons.check_rounded
                  : Icons.north_east_rounded,
              color: teal,
            ),
          ),
          title: Text(
            p['name'] ?? p['recipient'],
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            expired
                ? 'Outcome unknown · check receipt'
                : {
                        'paid': 'Paid · bank verified',
                        'rejected': 'Rejected · bank verified',
                        'relayed': 'Relayed · awaiting receipt',
                        'queued': 'Queued on this phone',
                      }[p['state']] ??
                      'Awaiting receipt',
            style: TextStyle(
              fontSize: 11,
              color: p['state'] == 'paid' ? teal : muted,
            ),
          ),
          trailing: Text(
            rupees(p['amount']),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          onTap: () => open(PaymentDetails(engine: e, id: p['payment_id'])),
        ),
      ),
    );
  }

  Widget activity() => ListView(
    padding: const EdgeInsets.all(23),
    children: [
      const Hint(
        'Transport progress and bank confirmation are separate. Only a verified receipt confirms a payment.',
      ),
      const SizedBox(height: 22),
      const Eyebrow('SENT PAYMENTS'),
      const SizedBox(height: 12),
      if (e.payments.isEmpty) const Box(child: Hint('No sent payments yet.')),
      ...e.payments.map(paymentTile),
      const SizedBox(height: 24),
      const Eyebrow('RECEIVED BANK RECEIPTS'),
      const SizedBox(height: 12),
      if (e.receipts.where((r) => r['recipient'] == e.accountId).isEmpty)
        const Box(
          child: Hint(
            'Incoming payments appear here when their signed receipt arrives.',
          ),
        ),
      ...e.receipts
          .where((r) => r['recipient'] == e.accountId)
          .map(
            (r) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Box(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.verified_outlined,
                          color: teal,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            r['sender'],
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          rupees(r['amount']),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 9),
                    Hint(
                      '${r['status'].toString().toUpperCase()} · ${stamp(r['committed_at'])}',
                    ),
                    const SizedBox(height: 5),
                    SelectableText(
                      r['bank_ref'],
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
    ],
  );
  Widget nearbyPage() => ListView(
    padding: const EdgeInsets.all(23),
    children: [
      const Eyebrow('EVERY PARTICIPATING PHONE CAN HELP'),
      const SizedBox(height: 13),
      const Text(
        'Carry a payment forward.',
        style: TextStyle(
          fontSize: 25,
          fontWeight: FontWeight.w700,
          letterSpacing: -.7,
        ),
      ),
      const SizedBox(height: 12),
      const Hint(
        'Nearby phones carry encrypted packets. A phone with internet can send them to the bank and bring receipts back.',
      ),
      const SizedBox(height: 23),
      Box(
        child: Column(
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Nearby relay',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Bluetooth LE · keep app open',
                style: TextStyle(fontSize: 12, color: muted),
              ),
              value: e.relay,
              onChanged: starting
                  ? null
                  : (v) async {
                      if (v) {
                        await start();
                      } else {
                        await e.stopRelay();
                      }
                    },
            ),
            const Divider(),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.checklist, color: teal),
              title: Text('Before you connect'),
              subtitle: Text(
                '1. Turn Bluetooth on.\n2. Android 12+: allow Nearby devices. Android 10–11: allow Location while using the app and turn Location on.\n3. Keep BeyondNet open on both phones.\n4. Set a screen lock to authorize payments.\nCamera permission is needed only for QR scanning.',
              ),
            ),
            TextButton(
              onPressed: () => openAppSettings(),
              child: const Text('Open device permissions'),
            ),
            Text(
              e.network,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Hint(
              'No special gateway account is needed. An online phone with relay enabled automatically connects the nearby network to the bank.',
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      Row(
        children: [
          Expanded(
            child: Box(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${e.nearby.length}',
                    style: const TextStyle(
                      fontSize: 27,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Hint('Verified peers'),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Box(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${e.queueSize}',
                    style: const TextStyle(
                      fontSize: 27,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Hint('Active packets'),
                ],
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 20),
      OutlinedButton.icon(
        onPressed: e.working || starting
            ? null
            : () async {
                if (!e.relay) {
                  await start();
                } else {
                  await e.retryNow();
                }
              },
        icon: const Icon(Icons.refresh),
        label: Text(
          e.working ? 'Scanning & verifying phones…' : 'Scan for nearby phones',
        ),
      ),
      const SizedBox(height: 20),
      if (e.nearby.isEmpty)
        const Box(
          child: Hint(
            'No verified peers yet. Start Nearby relay on another enrolled phone, keep both apps open and move within Bluetooth range.',
          ),
        ),
      ...e.nearby.map(
        (p) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Box(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.phone_android, color: teal),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        p['name'],
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      '${p['rssi']} dBm',
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SelectableText(
                  p['device_id'],
                  style: const TextStyle(fontSize: 10, color: muted),
                ),
                Hint(
                  p['online'] == true
                      ? 'Internet gateway available'
                      : 'Nearby relay · internet route not yet known',
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: starting
                      ? null
                      : () async {
                          setState(() => starting = true);
                          try {
                            await e.connectNearby(p['device_id']);
                            if (mounted) setState(() => tab = 0);
                          } catch (error) {
                            if (mounted) await alert(context, error);
                          } finally {
                            if (mounted) setState(() => starting = false);
                          }
                        },
                  child: Text(
                    e.connectedPeer == p['device_id'] && e.canPay
                        ? 'Connected · continue'
                        : 'Connect',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 20),
      const Eyebrow('LOCAL TRANSFER LOG'),
      const SizedBox(height: 12),
      if (e.lastError != null) Hint(e.lastError!),
      ...e.events
          .take(20)
          .map(
            (ev) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.circle, size: 6, color: teal),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ev['text'], style: const TextStyle(fontSize: 12)),
                        Text(
                          stamp(ev['at']),
                          style: const TextStyle(fontSize: 10, color: muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
    ],
  );
  Widget settings() => ListView(
    padding: const EdgeInsets.all(23),
    children: [
      Box(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              e.account!['name'],
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            Text(e.accountId, style: const TextStyle(color: teal)),
            const SizedBox(height: 20),
            const Eyebrow('DEVICE ID'),
            const SizedBox(height: 8),
            SelectableText(e.deviceId, style: const TextStyle(fontSize: 12)),
            TextButton.icon(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: e.deviceId)),
              icon: const Icon(Icons.copy, size: 15),
              label: const Text('Copy device ID'),
            ),
            const Hint(
              'Keys are stored using this phone’s secure storage. Preserve this installation while payments are pending.',
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      Box(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Online setup',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
            ),
            const SizedBox(height: 10),
            SelectableText(
              e.bankUrl,
              style: const TextStyle(fontSize: 12, color: teal),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () async {
                try {
                  await e.refreshProfile();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Recipients and balance refreshed'),
                      ),
                    );
                  }
                } catch (err) {
                  if (mounted) await alert(context, err);
                }
              },
              icon: const Icon(Icons.sync),
              label: const Text('Refresh balance & recipients'),
            ),
            TextButton(
              onPressed: () => open(LoginPage(engine: e, renewal: true)),
              child: const Text('Renew login / update bank URL'),
            ),
            TextButton(
              onPressed: () => open(PaymentPinPage(engine: e)),
              child: Text(
                e.pinConfigured ? 'Change payment PIN' : 'Set payment PIN',
              ),
            ),
            TextButton(
              onPressed: () => openAppSettings(),
              child: const Text('Open device permissions'),
            ),
            const SizedBox(height: 12),
            const Eyebrow('TRUSTED BANK FINGERPRINT'),
            const SizedBox(height: 8),
            SelectableText(
              e.trust['fingerprint'],
              style: const TextStyle(fontSize: 10, color: muted),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      Box(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Demo route controls',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            const Hint(
              'Normally connect to any enrolled nearby phone. To force a three-phone chain, restrict which device IDs may exchange packets with this phone.',
            ),
            const SizedBox(height: 12),
            Text(
              'Allowed peers: ${e.allowlist.isEmpty ? 'Any enrolled device' : e.allowlist.length}',
              style: const TextStyle(fontSize: 12, color: teal),
            ),
            TextButton(
              onPressed: editPeers,
              child: const Text('Edit allowed peers'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      const Hint(
        'BeyondNet is a demo bank system. Payments settle only when a gateway reaches the bank. A relay acknowledgment is not proof of payment. Bluetooth relay runs while the app is open.',
      ),
      const SizedBox(height: 20),
      const Center(child: Eyebrow('BEYONDNET · VERSION 1.2.1')),
    ],
  );
  Future<void> editPeers() async {
    final controller = TextEditingController(text: e.allowlist.join('\n'));
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Allowed peer device IDs'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Hint(
              'One device ID per line. Leave empty to allow all enrolled phones.',
            ),
            const SizedBox(height: 12),
            TextField(controller: controller, maxLines: 5),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) await e.setAllowlist(result);
    controller.dispose();
  }
}

class AddMoneyPage extends StatefulWidget {
  final BeyondNetEngine engine;
  const AddMoneyPage({super.key, required this.engine});
  @override
  State<AddMoneyPage> createState() => _AddMoneyState();
}

class _AddMoneyState extends State<AddMoneyPage> {
  final amount = TextEditingController(text: '1000');
  bool busy = false;
  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  Future<void> add() async {
    setState(() => busy = true);
    try {
      if (!RegExp(r'^\d{1,5}(\.\d{1,2})?$').hasMatch(amount.text.trim())) {
        throw ArgumentError('Enter an amount from ₹1 to ₹10,000.');
      }
      final parts = amount.text.trim().split('.');
      final paise =
          int.parse(parts[0]) * 100 +
          (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
      await widget.engine.addDemoMoney(paise);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Demo balance updated')));
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) await alert(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.engine,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Add demo money')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Icon(
            Icons.account_balance_wallet_outlined,
            size: 50,
            color: teal,
          ),
          const SizedBox(height: 20),
          const Text(
            'Ready for your first payment',
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          const Hint(
            'Add free demo INR to your bank account. No card, real money or UPI details are needed. Connect online to add funds before going offline.',
          ),
          const SizedBox(height: 24),
          TextField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Demo amount',
              prefixText: '₹ ',
              helperText: '₹1 to ₹10,000 per top-up',
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            children: [100, 500, 1000]
                .map(
                  (v) => ActionChip(
                    label: Text('₹$v'),
                    onPressed: busy
                        ? null
                        : () => setState(() => amount.text = '$v'),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 24),
          if (!widget.engine.bankReachable)
            const Hint(
              'The bank is currently unreachable. Reconnect to add demo money.',
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: busy || !widget.engine.bankReachable ? null : add,
            child: Text(busy ? 'Updating balance…' : 'Add demo money'),
          ),
          const SizedBox(height: 14),
          const Hint(
            'If a previous top-up was interrupted, this safely completes that same top-up first, without adding it twice.',
          ),
        ],
      ),
    ),
  );
}

class PayPage extends StatefulWidget {
  final BeyondNetEngine engine;
  final Json? selected;
  const PayPage({super.key, required this.engine, this.selected});
  @override
  State<PayPage> createState() => _PayState();
}

class _PayState extends State<PayPage> {
  Json? selected;
  final amount = TextEditingController(), recipientId = TextEditingController();
  bool busy = false, finding = false;
  @override
  void initState() {
    super.initState();
    selected = widget.selected;
  }

  @override
  void dispose() {
    amount.dispose();
    recipientId.dispose();
    super.dispose();
  }

  Future<void> lookup() async {
    setState(() => finding = true);
    try {
      final cert = await widget.engine.findRecipient(recipientId.text);
      if (mounted) setState(() => selected = cert);
    } catch (error) {
      if (mounted) await alert(context, error);
    } finally {
      if (mounted) setState(() => finding = false);
    }
  }

  Future<void> scanRecipient() async {
    final raw = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (raw == null) return;
    try {
      final qr = jsonDecode(raw);
      if (qr['type'] != 'offline-karo/recipient/v1') {
        throw StateError('Scan a BeyondNet payment QR.');
      }
      final cert = Map<String, dynamic>.from(qr['certificate']);
      await widget.engine.addRecipient(cert);
      if (mounted) setState(() => selected = cert);
    } catch (error) {
      if (mounted) await alert(context, error);
    }
  }

  int parseAmount() {
    final value = amount.text.trim();
    if (!RegExp(r'^\d{1,5}(\.\d{1,2})?$').hasMatch(value)) {
      throw ArgumentError('Enter an amount with up to two decimal places.');
    }
    final parts = value.split('.');
    return int.parse(parts[0]) * 100 +
        (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
  }

  Future<void> pay() async {
    if (selected == null) return;
    setState(() => busy = true);
    try {
      final value = parseAmount();
      if (value < 1 || value > 1000000) {
        throw ArgumentError('Enter ₹0.01 to ₹10,000.');
      }
      if (!widget.engine.pinConfigured) {
        throw StateError(
          'Open Settings and set your payment PIN while online first.',
        );
      }
      final enteredPin = await showDialog<String>(
        context: context,
        builder: (_) => PaymentPinDialog(
          amount: value,
          recipient:
              selected!['body']['display_name'] ??
              selected!['body']['account_id'],
        ),
      );
      if (enteredPin == null) return;
      final id = await widget.engine.pay(selected!, value, pin: enteredPin);
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
            builder: (_) => PaymentDetails(engine: widget.engine, id: id),
          ),
        );
      }
    } catch (e) {
      if (mounted) await alert(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Make a payment')),
    body: ListView(
      padding: const EdgeInsets.all(25),
      children: [
        TextField(
          controller: recipientId,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Recipient payment ID',
            hintText: 'shop@beyondnet',
          ),
          onSubmitted: (_) {
            if (!finding) unawaited(lookup());
          },
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: finding ? null : lookup,
                child: Text(finding ? 'Finding…' : 'Find recipient'),
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              onPressed: scanRecipient,
              tooltip: 'Scan QR',
              icon: const Icon(Icons.qr_code_scanner),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Hint(
          'Offline? Use a saved ID or scan their QR to verify a new recipient.',
        ),
        const SizedBox(height: 18),
        const Eyebrow('BANK-VERIFIED RECIPIENTS'),
        const SizedBox(height: 18),
        if (widget.engine.merchants.isEmpty)
          const Box(
            child: Hint(
              'No recipients cached yet. Enroll the merchant phone, then refresh recipients in Device settings while online. You can also scan their receive code offline.',
            ),
          ),
        ...{
          for (final c in widget.engine.merchants.where(
            (x) => x['body']['account_id'] != widget.engine.accountId,
          ))
            c['body']['account_id']: c,
        }.values.map(
          (c) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: selected?['body']['account_id'] == c['body']['account_id']
                  ? const Color(0xffe2f2e8)
                  : Colors.white,
              borderRadius: BorderRadius.circular(15),
              child: ListTile(
                onTap: () => setState(() => selected = c),
                leading: const CircleAvatar(
                  backgroundColor: Colors.white,
                  child: Icon(Icons.storefront_outlined, color: teal),
                ),
                title: Text(
                  c['body']['display_name'] ?? c['body']['account_id'],
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  c['body']['account_id'],
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Icon(
                  selected?['body']['account_id'] == c['body']['account_id']
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  color: teal,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 30),
        const Text(
          'How much?',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 17),
        TextField(
          controller: amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w600),
          decoration: const InputDecoration(
            prefixText: '₹ ',
            hintText: '0.00',
            helperText: 'Demo INR · maximum ₹10,000 per request',
          ),
        ),
        const SizedBox(height: 25),
        const Box(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.enhanced_encryption_outlined, color: teal, size: 21),
              SizedBox(width: 12),
              Expanded(
                child: Hint(
                  'Your payment is signed on this phone and encrypted to the bank. Nearby relays cannot read the amount or authorize another payment.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: busy || selected == null ? null : pay,
          child: Text(busy ? 'Authorizing…' : 'Review payment →'),
        ),
      ],
    ),
  );
}

class PaymentDetails extends StatelessWidget {
  final BeyondNetEngine engine;
  final String id;
  const PaymentDetails({super.key, required this.engine, required this.id});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: engine,
    builder: (context, _) {
      final p = engine.payments.where((x) => x['payment_id'] == id).firstOrNull;
      if (p == null) {
        return const Scaffold(body: Center(child: Text('Payment unavailable')));
      }
      final paid = p['state'] == 'paid',
          rejected = p['state'] == 'rejected',
          expired = !paid && !rejected && p['expires_at'] < nowSeconds;
      final r = p['receipt'];
      return Scaffold(
        appBar: AppBar(title: const Text('Payment details')),
        body: ListView(
          padding: const EdgeInsets.all(27),
          children: [
            const SizedBox(height: 25),
            CircleAvatar(
              radius: 39,
              backgroundColor: paid
                  ? const Color(0xffdff3e8)
                  : const Color(0xffedf1e8),
              child: Icon(
                paid
                    ? Icons.check_rounded
                    : rejected
                    ? Icons.close_rounded
                    : Icons.schedule_rounded,
                size: 39,
                color: teal,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              paid
                  ? 'Payment confirmed'
                  : rejected
                  ? 'Payment rejected'
                  : expired
                  ? 'Outcome not yet known'
                  : 'On its way',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              rupees(p['amount']),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 42,
                fontWeight: FontWeight.w600,
                letterSpacing: -1,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'To ${p['name'] ?? p['recipient']}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted),
            ),
            const SizedBox(height: 28),
            Box(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  step(
                    'Saved on your phone',
                    true,
                    'Your original payment ID is preserved.',
                  ),
                  step(
                    'Delivery progress',
                    p['state'] == 'relayed' || paid || rejected,
                    p['transport'],
                  ),
                  step(
                    'Bank decision verified',
                    paid || rejected,
                    paid
                        ? 'One debit, one credit. Bank signature verified.'
                        : rejected
                        ? r['reason']
                        : expired
                        ? 'The authorization window ended. An earlier submission may have settled; wait for a receipt.'
                        : 'Waiting for a signed bank receipt.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            Box(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Eyebrow('PAYMENT ID'),
                  const SizedBox(height: 7),
                  SelectableText(id, style: const TextStyle(fontSize: 11)),
                  const SizedBox(height: 17),
                  Hint('Created ${stamp(p['created_at'])}'),
                  Hint('Authorization ends ${stamp(p['expires_at'])}'),
                  if (r != null) ...[
                    const SizedBox(height: 18),
                    const Eyebrow('BANK REFERENCE'),
                    const SizedBox(height: 7),
                    SelectableText(
                      r['bank_ref'],
                      style: const TextStyle(fontSize: 12, color: teal),
                    ),
                    const SizedBox(height: 8),
                    Hint('Committed ${stamp(r['committed_at'])}'),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (!paid && !rejected) ...[
              OutlinedButton.icon(
                onPressed: engine.working ? null : () => engine.retryNow(),
                icon: const Icon(Icons.refresh),
                label: const Text('Check delivery again'),
              ),
              const SizedBox(height: 10),
              const Hint(
                'Do not create a new payment to retry this one. The saved request keeps the same payment ID. Keep Nearby relay on; a connected gateway must be reachable.',
              ),
            ],
            const SizedBox(height: 20),
          ],
        ),
      );
    },
  );
  Widget step(String title, bool done, String body) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          done ? Icons.check_circle : Icons.radio_button_unchecked,
          color: done ? teal : muted,
          size: 21,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 5),
              Hint(body),
            ],
          ),
        ),
      ],
    ),
  );
}

class ReceivePage extends StatelessWidget {
  final BeyondNetEngine engine;
  const ReceivePage({super.key, required this.engine});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Receive a payment')),
    body: ListView(
      padding: const EdgeInsets.all(27),
      children: [
        const SizedBox(height: 20),
        const Eyebrow('YOUR BANK-VERIFIED IDENTITY'),
        const SizedBox(height: 18),
        Text(
          engine.account!['name'],
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 9),
        Text(
          engine.accountId,
          textAlign: TextAlign.center,
          style: const TextStyle(color: teal),
        ),
        const SizedBox(height: 25),
        Box(
          child: Center(
            child: QrImageView(
              data: jsonEncode({
                'type': 'offline-karo/recipient/v1',
                'certificate': engine.certificate,
              }),
              size: 290,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.L,
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Hint(
          'The sender scans this code to verify your identity offline, then chooses the amount. Keep Nearby relay on to receive the bank’s signed receipt.',
        ),
        const SizedBox(height: 20),
        const Box(
          child: Row(
            children: [
              Icon(Icons.verified_user_outlined, color: teal),
              SizedBox(width: 13),
              Expanded(
                child: Hint(
                  'Check Activity for the confirmed bank receipt. A sender’s pending screen is not proof of payment.',
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanState();
}

class _ScanState extends State<ScanPage> {
  bool done = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan recipient code')),
    body: Stack(
      children: [
        MobileScanner(
          onDetect: (capture) {
            final value = capture.barcodes.firstOrNull?.rawValue;
            if (value != null && !done) {
              done = true;
              Navigator.pop(context, value);
            }
          },
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Allow camera access to scan a recipient’s QR code.',
                  ),
                  TextButton(
                    onPressed: () => openAppSettings(),
                    child: const Text('Open Settings'),
                  ),
                ],
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: const EdgeInsets.all(25),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(15),
            ),
            child: const Text(
              'Scan the code shown on the recipient’s Receive screen.',
            ),
          ),
        ),
      ],
    ),
  );
}
