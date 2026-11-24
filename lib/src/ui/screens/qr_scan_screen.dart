// Scans the QR that `agentd relay invite` prints on the host. The screen pops
// with the scanned text once it holds an agentd://relay invite; the caller
// sends it through the same path as a pasted link. The camera is the
// mobile_scanner plugin (CameraX + ML Kit on Android, AVFoundation + Vision on
// iOS); tests pass their own [QrScanScreen.preview].

import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/contracts.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Builds the camera preview; calls [onCode] with the text of every code it
/// reads (the same code may be reported many times).
typedef QrPreviewBuilder = Widget Function(BuildContext context, void Function(String text) onCode);

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key, this.preview});

  /// Replaces the camera (tests).
  final QrPreviewBuilder? preview;

  /// Opens the scanner; the scanned invite text, or null when closed.
  static Future<String?> open(BuildContext context) => Navigator.of(context).push<String>(MaterialPageRoute<String>(builder: (_) => const QrScanScreen()));

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _done = false;
  bool _foreign = false;

  // The scanned text is a secret (the invite code): never logged.
  void _onCode(String text) {
    if (_done || !mounted) return;
    if (relayLinkCandidates(text).isEmpty) {
      if (!_foreign) setState(() => _foreign = true);
      return;
    }
    _done = true;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          const RouteHeader(title: 'Escanear invitación', close: true),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: ColoredBox(
                  color: AppColors.terminalBg,
                  child: SizedBox.expand(child: widget.preview?.call(context, _onCode) ?? _CameraPreview(onCode: _onCode)),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _foreign
                    ? 'Ese QR no es una invitación de agentd. Apunta al que muestra agentd relay invite.'
                    : 'Apunta al QR que muestra agentd relay invite en el host.',
                key: const ValueKey('qr-scan-hint'),
                textAlign: TextAlign.center,
                style: AppFonts.inter(size: 13.5, color: _foreign ? AppColors.waiting : AppColors.secondary, height: 1.4),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// User-facing (Spanish) text for a camera failure.
String describeScannerError(MobileScannerErrorCode code) => switch (code) {
  MobileScannerErrorCode.permissionDenied => 'Sin permiso de cámara. Actívalo en los ajustes del sistema, o pega el enlace de la invitación.',
  MobileScannerErrorCode.unsupported => 'Este dispositivo no tiene una cámara que se pueda usar. Pega el enlace de la invitación.',
  _ => 'No se pudo abrir la cámara. Pega el enlace de la invitación.',
};

class _CameraPreview extends StatefulWidget {
  const _CameraPreview({required this.onCode});
  final void Function(String text) onCode;

  @override
  State<_CameraPreview> createState() => _CameraPreviewState();
}

class _CameraPreviewState extends State<_CameraPreview> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MobileScanner(
    controller: _controller,
    onDetect: (capture) {
      for (final b in capture.barcodes) {
        final v = b.rawValue;
        if (v != null && v.isNotEmpty) widget.onCode(v);
      }
    },
    // A decode error of one frame is not worth showing.
    onDetectError: (_, _) {},
    errorBuilder: (context, error) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.no_photography_outlined, size: 32, color: AppColors.muted),
            const SizedBox(height: 12),
            Text(
              describeScannerError(error.errorCode),
              key: const ValueKey('qr-scan-error'),
              textAlign: TextAlign.center,
              style: AppFonts.inter(size: 14, color: AppColors.secondary, height: 1.4),
            ),
          ],
        ),
      ),
    ),
  );
}
