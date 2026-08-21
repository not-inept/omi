import 'dart:typed_data';

import 'package:omi/gen/dji_mic_pigeon.g.dart';

/// Public bridge that implements Pigeon callbacks and forwards them to
/// Dart-side listeners. Mirrors RayBanMetaFlutterBridge.
class DjiMicFlutterBridge implements DjiMicFlutterApi {
  final void Function(Uint8List pcm16leMono16k, int sessionId)? onAudioFrameCb;
  final void Function(DjiMicCaptureState state, int sessionId)? onStateChangedCb;
  final void Function(String code, String message, int sessionId)? onCaptureErrorCb;

  DjiMicFlutterBridge({
    this.onAudioFrameCb,
    this.onStateChangedCb,
    this.onCaptureErrorCb,
  });

  @override
  void onAudioFrame(Uint8List pcm16leMono16k, int sessionId) {
    onAudioFrameCb?.call(pcm16leMono16k, sessionId);
  }

  @override
  void onStateChanged(DjiMicCaptureState state, int sessionId) {
    onStateChangedCb?.call(state, sessionId);
  }

  @override
  void onCaptureError(String code, String message, int sessionId) {
    onCaptureErrorCb?.call(code, message, sessionId);
  }
}
