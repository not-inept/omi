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
/// Both are exposed through the same synthetic characteristic-stream
/// vocabulary the rest of the device layer speaks, mirroring
/// RayBanMetaTransport/WatchTransport.
class DjiMicTransport extends DeviceTransport {
  final String _deviceId;
  final DjiMicHostApi _hostAPI = DjiMicHostApi();
  final StreamController<DeviceTransportState> _connectionStateController;
  final Map<String, StreamController<List<int>>> _streamControllers = {};

  DeviceTransportState _state = DeviceTransportState.disconnected;

  // Dart-minted, monotonically increasing per instance — mirrors
  // NativeMicRecorderService's _sessionId. Native echoes it on every event so
  // a stale event (from a session this instance already moved past) is
  // dropped rather than misapplied.
  int _sessionId = 0;

  static DjiMicFlutterBridge? _bridge;
  static final List<StreamController<List<int>>> _audioControllers = [];
  static final List<DjiMicTransport> _instances = [];

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
          for (final transport in _instances) {
            if (transport._sessionId != sessionId) continue;
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

  @override
  Future<void> connect() async {
    if (_state == DeviceTransportState.connected) {
      return;
    }
    _updateState(DeviceTransportState.connecting);
    final sessionId = ++_sessionId;
    try {
      await _hostAPI.start(_deviceId, sessionId);
      _updateState(DeviceTransportState.connected);
    } catch (e) {
      _updateState(DeviceTransportState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    if (_state == DeviceTransportState.disconnected) {
      return;
    }
    _updateState(DeviceTransportState.disconnecting);

    try {
      await _hostAPI.stop();
    } catch (e) {
      Logger.debug('DjiMic Transport: Error stopping audio during disconnect: $e');
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
      return await _hostAPI.isRecording();
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
