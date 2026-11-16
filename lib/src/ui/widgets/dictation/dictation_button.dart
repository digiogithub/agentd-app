// Mic button for the chat composer (TextField suffixIcon). Tap starts
// dictation, tap again stops and keeps what was heard, long-press cancels
// (the uncommitted words are removed). Partial results are shown live in the
// controller at the cursor.

import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme.dart';
import '../common.dart';
import 'dictation_providers.dart';
import 'dictation_service.dart';
import 'dictation_splice.dart';

class DictationButton extends ConsumerStatefulWidget {
  const DictationButton({super.key, required this.controller, this.focusNode});
  final TextEditingController controller;
  final FocusNode? focusNode;

  @override
  ConsumerState<DictationButton> createState() => _DictationButtonState();
}

class _DictationButtonState extends ConsumerState<DictationButton> {
  late final DictationService _service = ref.read(dictationServiceProvider);
  StreamSubscription<DictationStatus>? _statusSub;
  StreamSubscription<DictationError>? _errorSub;
  Timer? _stopTimer;
  DictationSplice? _splice; // non-null while a dictation owns a text segment
  bool _listening = false;
  bool _starting = false;
  double _level = 0;

  @override
  void initState() {
    super.initState();
    _statusSub = _service.status.listen(_onStatus);
    _errorSub = _service.errors.listen(_onError);
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _errorSub?.cancel();
    _stopTimer?.cancel();
    if (_listening || _splice != null) _service.cancel();
    super.dispose();
  }

  void _onStatus(DictationStatus s) {
    if (!mounted) return;
    if (s == DictationStatus.idle && (_listening || _splice != null)) _finish();
  }

  void _onError(DictationError e) {
    if (!mounted) return;
    if (_listening || _starting) _finish();
    showToast(context, switch (e) {
      DictationError.permissionDenied => 'Permite el micrófono para dictar',
      DictationError.unavailable =>
        'El dictado no está disponible en este dispositivo',
      DictationError.other => 'No se pudo dictar. Inténtalo de nuevo',
    });
  }

  /// Ends the dictation: whatever is in the controller stays.
  void _finish() {
    _stopTimer?.cancel();
    _splice = null;
    if (!mounted) return;
    setState(() {
      _listening = false;
      _starting = false;
      _level = 0;
    });
  }

  Future<String?> _resolveLocale() async {
    try {
      final saved = await ref.read(dictationLocaleProvider.future);
      final supported = await _service.locales();
      if (supported.isEmpty) return saved;
      final device =
          await _service.systemLocaleId() ??
          PlatformDispatcher.instance.locale.toString();
      return pickDictationLocale(
        saved: saved,
        device: device,
        supported: supported,
      );
    } catch (_) {
      return null; // let the recognizer use its default
    }
  }

  Future<void> _start() async {
    if (_starting || _listening) return;
    setState(() => _starting = true);
    final availability = await _service.initialize();
    if (!mounted) return;
    if (availability != DictationAvailability.available) {
      setState(() => _starting = false);
      showToast(
        context,
        availability == DictationAvailability.permissionDenied
            ? 'Permite el micrófono para dictar'
            : 'El dictado no está disponible en este dispositivo',
      );
      return;
    }
    final locale = await _resolveLocale();
    if (!mounted) return;
    HapticFeedback.selectionClick();
    final splice = DictationSplice.start(widget.controller.value);
    _splice = splice;
    setState(() {
      _starting = false;
      _listening = true;
    });
    try {
      await _service.listen(
        localeId: locale,
        onResult: (text, isFinal) => _onResult(splice, text, isFinal),
        onSoundLevel: (l) {
          if (mounted && _listening) setState(() => _level = l);
        },
      );
    } catch (_) {
      if (!mounted) return;
      _finish();
      showToast(context, 'No se pudo dictar. Inténtalo de nuevo');
    }
  }

  void _onResult(DictationSplice splice, String text, bool isFinal) {
    if (!mounted || !identical(_splice, splice)) return;
    widget.controller.value = splice.apply(text);
    if (isFinal) _finish();
  }

  /// Stop, keep what was heard. The recognizer may still deliver a last
  /// result, so results are accepted until it says so (or 2 s pass).
  Future<void> _stop() async {
    setState(() => _level = 0);
    _stopTimer = Timer(const Duration(seconds: 2), _finish);
    await _service.stop();
  }

  Future<void> _cancel() async {
    final splice = _splice;
    _splice = null;
    _stopTimer?.cancel();
    if (splice != null) widget.controller.value = splice.apply('');
    await _service.cancel();
    if (mounted) _finish();
  }

  @override
  Widget build(BuildContext context) {
    final active = _listening;
    final ring = 28.0 + 12.0 * _level;
    return Semantics(
      container: true,
      button: true,
      label: active ? 'Detener dictado' : 'Dictar',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: active ? _stop : _start,
        onLongPress: active ? _cancel : null,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: SizedBox(
              width: 40,
              height: 40,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (active)
                    AnimatedContainer(
                      key: const ValueKey('dictation-ring'),
                      duration: const Duration(milliseconds: 120),
                      width: ring,
                      height: ring,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accent.withValues(alpha: 0.25),
                      ),
                    ),
                  if (_starting)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.muted,
                      ),
                    )
                  else
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: active ? AppColors.accent : null,
                      ),
                      child: Icon(
                        active ? Icons.mic : Icons.mic_none,
                        size: 18,
                        color: active ? AppColors.bg : AppColors.muted,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
