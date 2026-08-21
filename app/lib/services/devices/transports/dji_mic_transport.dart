import 'dart:async';
import 'dart:typed_data';

import 'package:omi/gen/dji_mic_pigeon.g.dart';
import 'package:omi/services/bridges/dji_mic_bridge.dart';
import 'package:omi/utils/logger.dart';
import 'device_transport.dart';

/// Transport for DJI Mic 3 (and, incidentally, any other Bluetooth
/// communication-device mic — see lib/dji_mic_interface.dart). Audio comes
/// from the platform Bluetooth SCO/communication-device route, the same
/// shape as RayBanMetaTransport's audio-only mode, minus the camera and Meta
/// Wearables Device Access Toolkit registration complexity that mode also
/// carries — DJI Mic 3 has no comparable SDK to register against.
///
/// Mirrors RayBanMetaTransport's audio-only mode split between [connect]
/// (checks the route is available; does not start capture) and
/// [startAudioCapture] (called by DjiMicDeviceConnection once a listener is
/// actually attached — "so listening state == capturing state", per that
/// class's own comment). Both are exposed through the same synthetic
/// characteristic-stream vocabulary the rest of the device layer speaks.
///
/// The native DjiMicController is a process-wide singleton (one physical
/// Bluetooth route at a time), so the session-id counter that guards stale
/// events is a STATIC counter shared by every transport instance, not a
/// per-instance one — two instances minting independent counters could both
/// produce sessionId 1 and both match a native event meant for the other.
class DjiMicTransport extends DeviceTransport {
  final String _deviceId;
  final DjiMicHostApi _hostAPI = DjiMicHostApi();
  final StreamController<DeviceTransportState> _connectionStateController;
  final Map<String, StreamController<List<int>>> _streamControllers = {};

  DeviceTransportState _state = DeviceTransportState.disconnected;

  static DjiMicFlutterBridge? _bridge;
  static final List<StreamController<List<int>>> _audioControllers = [];
  static final List<DjiMicTransport> _instances = [];

  // Static: see class doc. 0 means "no session started yet" and never
  // matches a real native sessionId (native mints from 1).
  static int _sessionCounter = 0;
  static int _currentSessionId = 0;
  static String? _currentDeviceId;

  DjiMicTransport(this._deviceId)
      : _connectionStateController = StreamController<DeviceTransportState>.broadcast() {
    _ensureBridgeSetup();
    _instances.add(this);
  }

  @override
  String get deviceId => _deviceId;

  @override
  Stream<DeviceTransportState> get connectionStateStream => _connectionStateController.stream;

  void _updateState(DeviceTransportState newState) {
    if (_state != newState) {
      _state = newState;
      _connectionStateController.add(_state);
    }
  }

  static void _ensureBridgeSetup() {
    if (_bridge == null) {
      _bridge = DjiMicFlutterBridge(
        onAudioFrameCb: (Uint8List frame, int sessionId) {
          // Drop frames from a session this static counter has moved past —
          // mirrors phone_mic_interface.dart's documented contract, which
          // this Pigeon interface deliberately copies.
          if (sessionId != _currentSessionId) return;
          _audioControllers.removeWhere((controller) => controller.isClosed);
          for (final controller in _audioControllers) {
            try {
              controller.add(frame);
            } catch (e) {
              Logger.debug('DjiMic Transport: Error forwarding audio: $e');
            }
          }
        },
        onStateChangedCb: (DjiMicCaptureState state, int sessionId) {
          if (sessionId != _currentSessionId) return;
          final deviceId = _currentDeviceId;
          if (deviceId == null) return;
          for (final transport in _instances) {
            if (transport._deviceId != deviceId) continue;
            switch (state) {
              case DjiMicCaptureState.running:
                transport._updateState(DeviceTransportState.connected);
                break;
              case DjiMicCaptureState.starting:
              case DjiMicCaptureState.rebuilding:
                transport._updateState(DeviceTransportState.connecting);
                break;
              case DjiMicCaptureState.idle:
              case DjiMicCaptureState.interrupted:
                transport._updateState(DeviceTransportState.disconnected);
                break;
            }
          }
        },
        onCaptureErrorCb: (String code, String message, int sessionId) {
          Logger.debug('DjiMic Transport: native error $code: $message');
        },
      );
      DjiMicFlutterApi.setUp(_bridge!);
    }
  }

  /// Verifies [_deviceId] is currently a routable Bluetooth communication
  /// input. Does NOT start capture — mirrors RayBanMetaTransport's
  /// audio-only `connect()`, which only checks
  /// `getBluetoothHfpInputs().any((i) => i.uid == _deviceId)`. Capture starts
  /// in [startAudioCapture], called once a listener actually attaches.
  @override
  Future<void> connect() async {
    if (_state == DeviceTransportState.connected) {
      return;
    }
    _updateState(DeviceTransportState.connecting);
    try {
      final inputs = await _hostAPI.getAvailableInputs();
      if (!inputs.any((input) => input.uid == _deviceId)) {
        _updateState(DeviceTransportState.disconnected);
        throw Exception('DJI Mic 3 input not available over Bluetooth');
      }
      _updateState(DeviceTransportState.connected);
    } catch (e) {
      _updateState(DeviceTransportState.disconnected);
      rethrow;
    }
  }

  /// Starts native capture for this device. Safe to call only after
  /// [connect] has verified the input is available.
  Future<void> startAudioCapture() async {
    final sessionId = ++_sessionCounter;
    _currentSessionId = sessionId;
    _currentDeviceId = _deviceId;
    try {
      await _hostAPI.start(_deviceId, sessionId);
    } catch (e) {
      Logger.debug('DjiMic Transport: Error starting audio capture: $e');
      rethrow;
    }
  }

  Future<void> stopAudioCapture() async {
    try {
      await _hostAPI.stop();
    } catch (e) {
      Logger.debug('DjiMic Transport: Error stopping audio capture: $e');
    }
  }

  @override
  Future<void> disconnect() async {
    if (_state == DeviceTransportState.disconnected) {
      return;
    }
    _updateState(DeviceTransportState.disconnecting);

    await stopAudioCapture();
    if (_currentDeviceId == _deviceId) {
      _currentDeviceId = null;
    }

    for (final controller in _streamControllers.values) {
      _audioControllers.remove(controller);
      await controller.close();
    }
    _streamControllers.clear();

    _updateState(DeviceTransportState.disconnected);
  }

  @override
  Future<bool> isConnected() async {
    try {
      final inputs = await _hostAPI.getAvailableInputs();
      return inputs.any((input) => input.uid == _deviceId);
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> ping() async {
    return await isConnected();
  }

  @override
  Stream<List<int>> getCharacteristicStream(String serviceUuid, String characteristicUuid) {
    if (serviceUuid == 'dji-mic-audio-service' && characteristicUuid == 'dji-mic-audio-data') {
      return _getAudioStream();
    }
    return const Stream.empty();
  }

  Stream<List<int>> _getAudioStream() {
    const key = 'audio';

    if (!_streamControllers.containsKey(key)) {
      _streamControllers[key] = StreamController<List<int>>.broadcast();
      _audioControllers.add(_streamControllers[key]!);
    }

    return _streamControllers[key]!.stream;
  }

  @override
  Future<List<int>> readCharacteristic(String serviceUuid, String characteristicUuid) async {
    return [];
  }

  @override
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data) async {}

  @override
  Future<void> dispose() async {
    _instances.remove(this);

    for (final controller in _streamControllers.values) {
      _audioControllers.remove(controller);
      await controller.close();
    }
    _streamControllers.clear();

    await _connectionStateController.close();
  }
}
