import 'package:flutter/material.dart';
import 'campus_client.dart';
import 'campus_protocol.dart';

class CampusPage extends StatefulWidget {
  const CampusPage({super.key});
  @override
  State<CampusPage> createState() => _CampusPageState();
}

class _CampusPageState extends State<CampusPage> {
  final client = CampusClient();
  final query = TextEditingController();
  bool ready = false, busy = false;
  String? error, notice;
  CampusJson? result;
  int page = 0;
  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await client.init();
      if (mounted) setState(() => ready = true);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Campus storage is unavailable. Restart the app.',
        );
      }
    }
  }

  @override
  void dispose() {
    query.dispose();
    client.close();
    super.dispose();
  }

  Future<void> search({bool next = false}) async {
    setState(() {
      busy = true;
      error = null;
      if (!next) {
        page = 0;
      } else {
        page++;
      }
    });
    try {
      final found = await client.search(query.text, page: page);
      if (mounted) setState(() => result = found);
    } catch (_) {
      if (mounted) {
        setState(() {
          result = null;
          error =
              'No verified answer is available. Check your query, campus setup and connection, or refresh the public cache.';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> setup() async {
    final endpoint = TextEditingController(text: client.url),
        key = TextEditingController(text: client.publisherKey),
        token = TextEditingController();
    final route = DialogRoute<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect your campus'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Get these details from your institution. Verify the publisher key with staff before saving. Campus enrollment is separate from your payment account.',
              ),
              TextField(
                controller: endpoint,
                decoration: const InputDecoration(
                  labelText: 'Campus HTTPS address',
                ),
              ),
              TextField(
                controller: key,
                decoration: const InputDecoration(
                  labelText: 'Publisher public key',
                ),
              ),
              TextField(
                controller: token,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Campus enrollment token',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final accepted = await Navigator.of(context).push(route);
    if (accepted == true) {
      try {
        await client.configure(endpoint.text, key.text, token.text);
        if (mounted) {
          setState(() {
            result = null;
            error = null;
            notice =
                'Campus connected. Download the public cache for offline searches.';
          });
        }
      } catch (e) {
        if (mounted) setState(() => error = e.toString());
      }
    }
    await route.completed;
    endpoint.dispose();
    key.dispose();
    token.dispose();
  }

  Future<void> refresh() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await client.refresh();
      if (mounted) {
        setState(
          () => notice =
              'Verified public information saved for offline use (up to 24 hours).',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not refresh verified information. Check campus setup and connection.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Text(
        'Your campus, within reach',
        style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      const Text(
        'Find public notices, contacts, locations and library information. Download verified information while online to search it offline.',
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: ready && !busy ? setup : null,
            icon: const Icon(Icons.school_outlined),
            label: Text(
              client.configured ? 'Campus settings' : 'Set up Campus',
            ),
          ),
          OutlinedButton.icon(
            onPressed: ready && client.configured && !busy ? refresh : null,
            icon: const Icon(Icons.download_outlined),
            label: const Text('Refresh offline information'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      TextField(
        controller: query,
        onSubmitted: (_) {
          if (!busy && ready) search();
        },
        decoration: const InputDecoration(
          labelText: 'Search campus',
          hintText: 'Library hours, notices, department contacts',
          prefixIcon: Icon(Icons.search),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: ready && client.configured && !busy ? search : null,
        child: const Text('Search'),
      ),
      if (busy)
        const Padding(
          padding: EdgeInsets.all(16),
          child: LinearProgressIndicator(),
        ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (notice != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(notice!),
        ),
      if (result != null) ...[
        Text(
          '${result!['source']} · ${DateTime.fromMillisecondsSinceEpoch((result!['created_at'] as int) * 1000).toLocal()}',
        ),
        if ((result!['results'] as List).isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No matching public information. Try different words.'),
          ),
        for (final record in result!['results'] as List)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record['title'] as String,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(record['body'] as String),
                  const SizedBox(height: 12),
                  Text(
                    'Source: ${record['source']}\nUpdated: ${DateTime.fromMillisecondsSinceEpoch((record['updated_at'] as int) * 1000).toLocal()}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        if (result!['has_more'] == true)
          TextButton(
            onPressed: busy ? null : () => search(next: true),
            child: const Text('More results'),
          ),
      ],
      const SizedBox(height: 24),
      const Text(
        'Nearby campus gateway access and student messaging are not enabled in this build. Demo payments remain available from the payment account area. Real fees and institutional accounts require separate integrations.',
        style: TextStyle(fontSize: 12),
      ),
    ],
  );
}
