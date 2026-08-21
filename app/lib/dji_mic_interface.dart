import 'package:pigeon/pigeon.dart';

// Dedicated contract for DJI Mic 3 (and, incidentally, any other Bluetooth
// communication-device microphone) capture. Kept separate from
// pigeon_interfaces.dart so the module owns its generated files end to end,
// mirroring phone_mic_interface.dart.
// Regenerate with: dart run pigeon --input lib/dji_mic_interface.dart
//
// DJI Mic 3 has no BLE GATT audio characteristic and no public SDK: the
// transmitter pairs with the phone as a plain Bluetooth Classic HFP/SCO
// device, the same route a Bluetooth headset mic uses (confirmed by DJI's own
// Android third-party app compatibility list — it works in apps like Filmic
// Pro/WeChat/Zoom/Twitter that explicitly route audio through the
// communication device, and fails in apps like Instagram/YouTube that don't).
// This contract is therefore intentionally generic over "a Bluetooth
// communication-device mic", following the same shape as
// RayBanMetaHostAPI.getBluetoothHfpInputs()/startAudioCapture() in
// pigeon_interfaces.dart — DJI Mic 3 is just the input the app's UI expects
// the user to pick.
//
// Android-only for now (Kotlin implementation backs this host API; there is
// no Swift implementation, so iOS builds generate but never call into this
// file). See lib/services/devices/transports/dji_mic_transport.dart.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/gen/dji_mic_pigeon.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'ios/Runner/DjiMic/DjiMicPigeon.g.swift',
    // The shared PigeonCommunicator.g.swift already defines `PigeonError`; a
    // second generated file with the default error class name would collide.
    swiftOptions: SwiftOptions(errorClassName: 'DjiMicPigeonError'),
    kotlinOut: 'android/app/src/main/kotlin/com/friend/ios/djimic/DjiMicPigeon.g.kt',
    // PigeonCommunicator.g.kt (package com.friend.ios) already declares the default
    // FlutterError; an own package + error class keeps the two generated files disjoint.
    kotlinOptions: KotlinOptions(package: 'com.friend.ios.djimic', errorClassName: 'DjiMicPigeonError'),
    dartPackageName: 'omi_dji_mic',
  ),
)

/// Native capture state machine, mirrored to Dart on every transition.
/// Mirrors PhoneMicCaptureState (see phone_mic_interface.dart) — same shape,
/// different engine underneath (Bluetooth SCO/communication-device instead
/// of the built-in mic).
enum DjiMicCaptureState { idle, starting, running, interrupted, rebuilding }

/// One Bluetooth communication-device input the OS currently reports as
/// available (paired, and either connected or connectable). [uid] is the
/// stable device address — the authoritative identity a caller should store
/// and reconnect with. [name] is the user-visible Bluetooth device name and
/// is only for display; it is renameable and must not be used as an
/// identity key (mirrors BluetoothHfpInput in pigeon_interfaces.dart).
class BluetoothMicInput {
  final String uid;
  final String name;

  BluetoothMicInput({required this.uid, required this.name});
}

/// Dart -> native. getAvailableInputs() lists paired Bluetooth
/// communication-device inputs (not DJI-specific — any Bluetooth headset/mic
/// shows up here too; the UI is responsible for helping the user identify
/// their DJI Mic 3 by name). start() resolves once audio is actually
/// flowing, or throws a PlatformException with one of: permission_denied
/// (BLUETOOTH_CONNECT or RECORD_AUDIO not granted), input_unavailable (uid
/// no longer among the available inputs), route_failed (the OS would not
/// switch the communication device to this input), engine_start_failed.
///
/// `sessionId` is a Dart-minted, monotonically increasing identity for this
/// capture session, mirroring PhoneMicHostApi.start's sessionId — every
/// DjiMicFlutterApi event carries the id of the session it belongs to; Dart
/// drops any event whose id does not match its current session.
///
/// stop() resolves only after teardown is fully drained — no frames or
/// events arrive after it. stop() is safe to call regardless of session
/// state (it resolves harmlessly when idle).
@HostApi()
abstract class DjiMicHostApi {
  @async
  List<BluetoothMicInput> getAvailableInputs();

  @async
  void start(String inputUid, int sessionId);

  @async
  void stop();

  bool isRecording();
}

/// Native -> Dart. Every method carries the `sessionId` of the session the
/// event belongs to; Dart drops any event whose id does not match its
/// current session.
@FlutterApi()
abstract class DjiMicFlutterApi {
  /// PCM16 little-endian mono @16kHz. Resampled natively so Dart never sees
  /// Bluetooth SCO's native 8kHz (CVSD/narrowband) or 16kHz (mSBC/wideband)
  /// variability — the OS/link picks the codec, not this app.
  void onAudioFrame(Uint8List pcm16leMono16k, int sessionId);

  void onStateChanged(DjiMicCaptureState state, int sessionId);

  /// Non-fatal runtime failures (capture attempts to self-heal, mirroring
  /// PhoneMicFlutterApi.onCaptureError): route_lost (the Bluetooth
  /// communication device disconnected — e.g. transmitter powered off or out
  /// of range), rebuild_failed, resume_failed.
  void onCaptureError(String code, String message, int sessionId);
}
