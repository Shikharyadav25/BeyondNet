import 'dart:async';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'bank_setup_code.dart';

String? bankSetupFromValues(Iterable<String?> values) {
  final valid = <String, String>{};
  for (final raw in values) {
    if (raw == null) continue;
    try {
      final code = BankSetupCode.parse(raw);
      valid['${code.url}|${code.fingerprint}'] = raw;
    } on FormatException {
      /* Skip unrelated codes in the same photo. */
    }
  }
  if (valid.length > 1) {
    throw const FormatException(
      'This image has different bank setup codes. Select an image containing only the bank you want.',
    );
  }
  return valid.values.firstOrNull;
}

Future<String?> pickBankSetupImage() async {
  final picker = ImagePicker();
  final image = await picker.pickImage(
    source: ImageSource.gallery,
    requestFullMetadata: false,
  );
  if (image == null) return null;
  return readBankSetupImage(image.path);
}

Future<String> readBankSetupImage(String path) async {
  final scanner = MobileScannerController(
    autoStart: false,
    formats: [BarcodeFormat.qrCode],
  );
  try {
    final capture = await scanner.analyzeImage(
      path,
      formats: [BarcodeFormat.qrCode],
    );
    final raw = bankSetupFromValues(
      capture?.barcodes.map((b) => b.rawValue) ?? [],
    );
    if (raw == null) {
      throw const FormatException(
        'No BeyondNet bank setup QR found. Choose a clear, uncropped image downloaded from Device setup on the bank dashboard.',
      );
    }
    return raw;
  } finally {
    await scanner.dispose();
  }
}

/// Gallery recovery after Android reclaims the activity while its picker is open.
Future<String?> recoverBankSetupImage() async {
  final result = await ImagePicker().retrieveLostData();
  if (result.isEmpty) return null;
  if (result.exception != null) throw result.exception!;
  final image = result.files?.firstOrNull;
  return image == null ? null : readBankSetupImage(image.path);
}

class BankSetupScanPage extends StatefulWidget {
  const BankSetupScanPage({super.key});
  @override
  State<BankSetupScanPage> createState() => _BankSetupScanPageState();
}

class _BankSetupScanPageState extends State<BankSetupScanPage> {
  final controller = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool done = false;
  String? error;
  @override
  void dispose() {
    unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan bank setup QR')),
    body: Stack(
      children: [
        MobileScanner(
          controller: controller,
          onDetect: (capture) {
            if (done) return;
            try {
              final raw = bankSetupFromValues(
                capture.barcodes.map((b) => b.rawValue),
              );
              if (raw == null) {
                setState(
                  () => error = 'Scan the bank setup QR, not a payment QR.',
                );
                return;
              }
              done = true;
              Navigator.pop(context, raw);
            } on FormatException catch (e) {
              setState(() => error = e.message);
            }
          },
          errorBuilder: (context, error) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Allow camera access to scan the bank setup QR.'),
                TextButton(
                  onPressed: openAppSettings,
                  child: const Text('Open Settings'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Use an image instead'),
                ),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              error ??
                  'Scan the QR on your trusted bank dashboard’s Device setup page. It contains the bank URL and fingerprint.',
            ),
          ),
        ),
      ],
    ),
  );
}
