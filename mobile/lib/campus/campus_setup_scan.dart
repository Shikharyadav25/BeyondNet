import 'dart:async';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'campus_setup_code.dart';

String? campusSetupFromValues(Iterable<String?> values) {
  final valid = <String, String>{};
  for (final raw in values) {
    if (raw == null) continue;
    try {
      final code = CampusSetupCode.parse(raw);
      valid['${code.code}|${code.url}|${code.fingerprint}'] = raw;
    } on FormatException {
      /* Skip unrelated codes in the same photo. */
    }
  }
  if (valid.length > 1) {
    throw const FormatException(
      'This image has different campus setup codes. Select an image containing only the campus you want.',
    );
  }
  return valid.values.firstOrNull;
}

Future<String?> pickCampusSetupImage() async {
  final picker = ImagePicker();
  final image = await picker.pickImage(
    source: ImageSource.gallery,
    requestFullMetadata: false,
  );
  if (image == null) return null;
  return readCampusSetupImage(image.path);
}

Future<String> readCampusSetupImage(String path) async {
  final scanner = MobileScannerController(
    autoStart: false,
    formats: [BarcodeFormat.qrCode],
  );
  try {
    final capture = await scanner.analyzeImage(
      path,
      formats: [BarcodeFormat.qrCode],
    );
    final raw = campusSetupFromValues(
      capture?.barcodes.map((b) => b.rawValue) ?? [],
    );
    if (raw == null) {
      throw const FormatException(
        'No BeyondNet campus setup QR found. Choose a clear, uncropped image downloaded from the campus console.',
      );
    }
    return raw;
  } finally {
    await scanner.dispose();
  }
}

/// Gallery recovery after Android reclaims the activity while its picker is open.
Future<String?> recoverCampusSetupImage() async {
  final result = await ImagePicker().retrieveLostData();
  if (result.isEmpty) return null;
  if (result.exception != null) throw result.exception!;
  final image = result.files?.firstOrNull;
  return image == null ? null : readCampusSetupImage(image.path);
}

class CampusSetupScanPage extends StatefulWidget {
  const CampusSetupScanPage({super.key});
  @override
  State<CampusSetupScanPage> createState() => _CampusSetupScanPageState();
}

class _CampusSetupScanPageState extends State<CampusSetupScanPage> {
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
    appBar: AppBar(title: const Text('Scan campus setup QR')),
    body: Stack(
      children: [
        MobileScanner(
          controller: controller,
          onDetect: (capture) {
            if (done) return;
            try {
              final raw = campusSetupFromValues(
                capture.barcodes.map((b) => b.rawValue),
              );
              if (raw == null) {
                setState(
                  () => error = 'Scan the campus setup QR, not a payment QR.',
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
                const Text('Allow camera access to scan the campus setup QR.'),
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
                  'Scan the QR on your trusted campus console’s Device setup page. It contains the college URL and fingerprint.',
            ),
          ),
        ),
      ],
    ),
  );
}
