import 'dart:async';

import 'package:flutter/material.dart';

import '../engine.dart';
import '../nearby_permissions.dart';
import 'campus_engine.dart';

class CampusPage extends StatefulWidget {
  final CampusEngine campus;
  final BeyondNetEngine payments;
  final VoidCallback openPayments;
  const CampusPage({
    super.key,
    required this.campus,
    required this.payments,
    required this.openPayments,
  });
  @override
  State<CampusPage> createState() => _CampusPageState();
}

class _CampusPageState extends State<CampusPage> with WidgetsBindingObserver {
  final code = TextEditingController(),
      url = TextEditingController(),
      fingerprint = TextEditingController(),
      id = TextEditingController(),
      password = TextEditingController(),
      compose = TextEditingController();
  String role = 'student', kind = 'message';
  String? selected;
  bool busy = false;
  CampusEngine get c => widget.campus;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Campus runs in the foreground; never imply reliable background delivery.
    if (state == AppLifecycleState.paused) unawaited(c.stopNearby());
    if (state == AppLifecycleState.resumed) unawaited(c.tick());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(c.stopNearby());
    for (final x in [code, url, fingerprint, id, password, compose]) {
      x.dispose();
    }
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted)
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Campus needs attention'),
            content: Text(e.toString().replaceFirst('Bad state: ', '')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Got it'),
              ),
            ],
          ),
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(
    TextEditingController ctrl,
    String label, {
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: ctrl,
      obscureText: secret,
      autocorrect: false,
      decoration: InputDecoration(labelText: label),
    ),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('BeyondNet Campus'),
        actions: [
          if (c.session != null)
            IconButton(
              tooltip: 'Leave campus',
              icon: const Icon(Icons.logout),
              onPressed: busy
                  ? null
                  : () => run(() async {
                      final leave = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Leave this campus?'),
                          content: const Text(
                            'This removes campus credentials and cached messages from this phone. Your payment account stays available.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Stay'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Leave'),
                            ),
                          ],
                        ),
                      );
                      if (leave == true) {
                        await c.leave();
                        selected = null;
                      }
                    }),
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: c.session == null ? enrollment(context) : feed(context),
          ),
        ),
      ),
    ),
  );
  Widget enrollment(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Icon(Icons.school_outlined, size: 56, color: Color(0xff008876)),
      const SizedBox(height: 24),
      Text(
        c.discoveredCampus == null
            ? 'Your campus.\nWithin reach.'
            : 'Join ${c.discoveredCampus!['name']}',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 16),
      const Text(
        'Enroll online once with your college-issued identity. Read cached groups and carry encrypted messages over nearby Bluetooth when the network drops.',
      ),
      const SizedBox(height: 24),
      if (c.discoveredCampus == null) ...[
        field(code, 'Campus code'),
        field(url, 'College server HTTPS URL'),
        field(fingerprint, 'Campus fingerprint (from your college)'),
        const Text(
          'Get these details from your college administrator. The fingerprint is checked before sending your credentials.',
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy
              ? null
              : () => run(
                  () => c.discover(url.text, code.text, fingerprint.text),
                ),
          child: Text(busy ? 'Finding campus…' : 'Find my campus'),
        ),
      ] else ...[
        DropdownButtonFormField<String>(
          initialValue: role,
          decoration: const InputDecoration(labelText: 'Join as'),
          items: const [
            DropdownMenuItem(value: 'student', child: Text('Student')),
            DropdownMenuItem(value: 'professor', child: Text('Professor')),
            DropdownMenuItem(value: 'hod', child: Text('Head of department')),
            DropdownMenuItem(
              value: 'authority',
              child: Text('Campus authority'),
            ),
          ],
          onChanged: busy ? null : (v) => setState(() => role = v!),
        ),
        const SizedBox(height: 16),
        field(
          id,
          role == 'student' ? 'ERP / student ID' : 'Faculty / staff ID',
        ),
        field(password, 'College-issued Campus password', secret: true),
        const Text(
          'Your role and section groups are assigned by the college roster. Use Campus credentials provisioned by your college; ERP single sign-on requires a college integration.',
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy
              ? null
              : () => run(() async {
                  await c.enroll(id.text, password.text, role);
                  password.clear();
                  unawaited(c.tick());
                }),
          child: Text(busy ? 'Verifying…' : 'Join campus'),
        ),
        TextButton(
          onPressed: busy
              ? null
              : () => setState(() => c.discoveredCampus = null),
          child: const Text('Use a different campus'),
        ),
      ],
    ],
  );
  Widget feed(BuildContext context) {
    final groupIds = c.groups.keys.toList();
    if (!groupIds.contains(selected)) selected = groupIds.firstOrNull;
    final items = c.messages.where((m) => m['group'] == selected).toList();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          c.session!['name'],
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        Text('${c.member['name']} · ${c.member['role']} · ${c.member['id']}'),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.status,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Nearby copies are not proof that everyone has read a message. Keep Campus open while relaying. Access and messages expire after at most 24 hours; renew online.',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: busy ? null : () => run(() => c.tick()),
                      icon: const Icon(Icons.sync),
                      label: const Text('Sync now'),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                              if (c.nearby) {
                                await c.stopNearby();
                                return;
                              }
                              await NearbyPermissions.ensureAndroidReady();
                              if (widget.payments.relayEnabled)
                                await widget.payments.stopRelay();
                              await c.startNearby();
                            }),
                      icon: Icon(
                        c.nearby ? Icons.bluetooth_connected : Icons.bluetooth,
                      ),
                      label: Text(
                        c.nearby
                            ? 'Stop campus Bluetooth'
                            : 'Start campus Bluetooth',
                      ),
                    ),
                  ],
                ),
                if (widget.payments.relayEnabled)
                  const Text(
                    'Starting campus Bluetooth pauses the payment relay. Enable it again in Payments when needed.',
                  ),
              ],
            ),
          ),
        ),
        if (!c.enrolled)
          Card(
            child: ListTile(
              leading: const Icon(Icons.lock_clock),
              title: const Text('Renew campus access online'),
              subtitle: const Text(
                'Leave this campus and join again with the current college credentials.',
              ),
            ),
          ),
        const SizedBox(height: 14),
        Card(
          child: ListTile(
            leading: const Icon(Icons.local_cafe_outlined),
            title: const Text('Canteen & vending payments'),
            subtitle: const Text(
              'Open Payments, then scan the merchant’s payment QR.',
            ),
            trailing: const Icon(Icons.arrow_forward),
            onTap: busy
                ? null
                : () => run(() async {
                    await c.stopNearby();
                    if (mounted) widget.openPayments();
                  }),
          ),
        ),
        const SizedBox(height: 20),
        Text('Your groups', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (groupIds.isEmpty)
          const Text('No groups assigned. Contact your campus administrator.'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: groupIds
              .map(
                (g) => ChoiceChip(
                  label: Text(c.groups[g]['name']),
                  selected: selected == g,
                  onSelected: busy
                      ? null
                      : (_) => setState(() {
                          selected = g;
                          kind = 'message';
                          compose.clear();
                        }),
                ),
              )
              .toList(),
        ),
        if (selected != null) ...[
          const SizedBox(height: 16),
          Text(
            c.groups[selected]['kind'] == 'section'
                ? 'Section conversation'
                : c.groups[selected]['kind'] == 'faculty'
                ? 'Professor messages & assignments'
                : 'HOD & campus notices',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No messages yet. Sync with the campus server or a nearby campus phone.',
              ),
            ),
          ...items.map(
            (m) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          m['kind'] == 'notice'
                              ? Icons.campaign_outlined
                              : m['kind'] == 'assignment'
                              ? Icons.assignment_outlined
                              : Icons.chat_bubble_outline,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${m['sender']} · ${m['role']}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SelectableText(m['text']),
                    const SizedBox(height: 10),
                    Text(
                      '${m['kind']} · ${DateTime.fromMillisecondsSinceEpoch(m['created_at'] * 1000).toLocal()}\n${m['state']}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (c.canPost(selected!)) ...[
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: ValueKey('$selected:$kind'),
              initialValue: kind,
              decoration: const InputDecoration(labelText: 'Post type'),
              items: [
                const DropdownMenuItem(
                  value: 'message',
                  child: Text('Message'),
                ),
                if (c.member['role'] != 'student')
                  const DropdownMenuItem(
                    value: 'assignment',
                    child: Text('Assignment'),
                  ),
                if (['hod', 'authority'].contains(c.member['role']))
                  const DropdownMenuItem(
                    value: 'notice',
                    child: Text('Notice'),
                  ),
              ],
              onChanged: busy ? null : (v) => setState(() => kind = v!),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: compose,
              maxLines: 4,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: 'Write to this group',
              ),
            ),
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => run(() async {
                      await c.post(selected!, compose.text, kind);
                      compose.clear();
                    }),
              icon: const Icon(Icons.send_outlined),
              label: const Text('Save & send'),
            ),
          ] else
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Only college-authorized staff can post in this group.',
              ),
            ),
        ],
        const SizedBox(height: 32),
      ],
    );
  }
}
