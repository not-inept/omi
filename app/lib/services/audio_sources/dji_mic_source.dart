import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/audio_sources/audio_source.dart';

/// Audio source for DJI Mic 3 (and other Bluetooth communication-device
/// mics), reached over the platform Bluetooth SCO/communication-device
/// route rather than BLE GATT.
///
/// The native DjiMicCaptureEngine (android/.../djimic/DjiMicCaptureEngine.kt)
/// already resamples Bluetooth SCO's variable link rate (8kHz or 16kHz) to a
/// fixed 16kHz mono PCM16 before frames ever reach Dart, so this source's
/// framing logic is a verbatim copy of PhoneMicSource — same rate, same
/// format, same 320-byte (10ms) chunking. Kept as its own class rather than
/// reusing PhoneMicSource directly so `deviceId`/`deviceModel` (and WAL
/// metadata derived from them) correctly identify DJI Mic 3, not the phone.
class DjiMicSource implements AudioSource {
  /// Fixed frame size: 10ms at 16kHz, 16-bit mono = 320 bytes.
  static const int frameSize = 320;

  @override
  BleAudioCodec get codec => BleAudioCodec.pcm16;

  @override
  final String deviceId;

  @override
  final String deviceModel;

  DjiMicSource({this.deviceId = 'dji-mic-3', this.deviceModel = 'DJI Mic 3'});

  final List<int> _buffer = [];
  int _frameIndex = 0;

  @override
  List<WalFrame> processBytes(List<int> rawBytes) {
    _buffer.addAll(rawBytes);
    final frames = <WalFrame>[];

    while (_buffer.length >= frameSize) {
      final payload = _buffer.sublist(0, frameSize);
      _buffer.removeRange(0, frameSize);

      frames.add(WalFrame(
        payload: payload,
        syncKey: FrameSyncKey.fromIndex(_frameIndex),
      ));
      // 1-byte index wraps at 256, mirroring PhoneMicSource (see there for why
      // this is safe: markFrameSynced reverse-scans, and frames drain well
      // within the 256-frame window).
      _frameIndex = (_frameIndex + 1) & 0xFF;
    }

    return frames;
  }

  @override
  List<int> getSocketPayload(List<int> rawBytes) {
    return rawBytes;
  }

  @override
  List<WalFrame> flush() {
    if (_buffer.isEmpty) return [];

    final padded = List<int>.filled(frameSize, 0);
    for (int i = 0; i < _buffer.length; i++) {
      padded[i] = _buffer[i];
    }
    _buffer.clear();

    final frame = WalFrame(
      payload: padded,
      syncKey: FrameSyncKey.fromIndex(_frameIndex),
    );
    _frameIndex = (_frameIndex + 1) & 0xFF;
    return [frame];
  }
}
