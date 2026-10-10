import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'engine.dart';

class PaymentPinDialog extends StatefulWidget {
  final int amount;
  final String recipient;
  const PaymentPinDialog({
    super.key,
    required this.amount,
    required this.recipient,
  });
  @override
  State<PaymentPinDialog> createState() => _PaymentPinDialogState();
}

class _PaymentPinDialogState extends State<PaymentPinDialog> {
  final pin = TextEditingController();
  String? error;
  @override
  void dispose() {
    pin.clear();
    pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Confirm demo payment'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '₹${(widget.amount / 100).toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
        ),
        Text('To ${widget.recipient}'),
        const SizedBox(height: 16),
        TextField(
          controller: pin,
          obscureText: true,
          keyboardType: TextInputType.number,
          enableSuggestions: false,
          autocorrect: false,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: 'Six-digit payment PIN',
            errorText: error,
          ),
        ),
        const Text(
          'Your PIN is encrypted for the bank. Nearby phones cannot read it. Payment can complete immediately; the request expires after 10 minutes if it has not been processed.',
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (!RegExp(r'^[0-9]{6}$').hasMatch(pin.text)) {
            setState(() => error = 'Enter all six digits');
            return;
          }
          final value = pin.text;
          pin.clear();
          Navigator.pop(context, value);
        },
        child: const Text('Authorize'),
      ),
    ],
  );
}

class PaymentPinPage extends StatefulWidget {
  final BeyondNetEngine engine;
  const PaymentPinPage({super.key, required this.engine});
  @override
  State<PaymentPinPage> createState() => _PaymentPinPageState();
}

class _PaymentPinPageState extends State<PaymentPinPage> {
  final password = TextEditingController(),
      pin = TextEditingController(),
      confirmation = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    for (final c in [password, pin, confirmation]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (pin.text != confirmation.text) {
      setState(() => error = 'The PINs do not match');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.engine.setPaymentPin(password.text, pin.text);
      for (final c in [password, pin, confirmation]) {
        c.clear();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment PIN saved at the bank')),
        );
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not save PIN. Check your account password, internet and bank connection; use six digits.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Payment PIN')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Set or change your six-digit payment PIN while online. Your account password is required. The bank stores a salted hash; this app does not save the PIN.',
        ),
        const SizedBox(height: 20),
        TextField(
          controller: password,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Account password'),
        ),
        const SizedBox(height: 12),
        for (final field in [
          (pin, 'New six-digit PIN'),
          (confirmation, 'Confirm PIN'),
        ]) ...[
          TextField(
            controller: field.$1,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: field.$2),
          ),
          const SizedBox(height: 12),
        ],
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: busy || !widget.engine.bankReachable ? null : save,
          child: Text(busy ? 'Saving…' : 'Save payment PIN'),
        ),
        if (!widget.engine.bankReachable)
          const Text('Connect to the bank online to continue.'),
      ],
    ),
  );
}
