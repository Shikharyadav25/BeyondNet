import 'package:flutter/material.dart';

/// Demonstration input only. Document details stay in this screen's memory and
/// are disposed when the user continues or skips; they are not proof of identity.
class DemoIdentityStep extends StatefulWidget {
  final VoidCallback onContinue, onSkip, onSignIn;
  const DemoIdentityStep({
    super.key,
    required this.onContinue,
    required this.onSkip,
    required this.onSignIn,
  });
  @override
  State<DemoIdentityStep> createState() => _DemoIdentityStepState();
}

class _DemoIdentityStepState extends State<DemoIdentityStep> {
  static const teal = Color(0xff008876);
  static const documents = [
    'Aadhaar',
    'Passport',
    'PAN card',
    'Driving licence',
  ];
  final number = TextEditingController();
  String selected = documents.first;
  @override
  void dispose() {
    number.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff4f7f5),
    appBar: AppBar(title: const Text('Identity setup')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(26),
            children: [
              const Icon(Icons.badge_outlined, size: 52, color: teal),
              const SizedBox(height: 20),
              Text(
                'Your identity.\nYour choice.',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'One last step before you enter BeyondNet. Add a document for the identity setup demo, or skip for now.',
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xffe2efe7),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, color: teal),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Identity setup · Demo\nYour document details stay private to this screen and are cleared when you continue.',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Choose a document',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              ...documents.map(
                (document) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: selected == document
                        ? const Color(0xffe2efe7)
                        : Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(
                        color: selected == document
                            ? teal
                            : const Color(0xffdfe8e3),
                      ),
                    ),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      leading: const Icon(
                        Icons.credit_card_outlined,
                        color: teal,
                      ),
                      title: Text(document),
                      trailing: Icon(
                        selected == document
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: selected == document ? teal : Colors.grey,
                      ),
                      onTap: () => setState(() {
                        selected = document;
                        number.clear();
                      }),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: number,
                onChanged: (_) => setState(() {}),
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 40,
                decoration: InputDecoration(
                  labelText: '$selected document number',
                  hintText: 'Enter sample details',
                  helperText: 'For this demo only. Details are not saved.',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: number.text.trim().isEmpty
                    ? null
                    : widget.onContinue,
                style: FilledButton.styleFrom(
                  backgroundColor: teal,
                  padding: const EdgeInsets.all(17),
                ),
                child: const Text('Continue to BeyondNet'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: widget.onSkip,
                child: const Text('Skip for now'),
              ),
              const Divider(height: 24),
              TextButton(
                onPressed: widget.onSignIn,
                child: const Text('Already have an account? Sign in'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
