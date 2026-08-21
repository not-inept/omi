import 'dart:async';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/connectors/device_connection.dart';
import 'package:omi/services/devices/models.dart';
import 'package:omi/services/devices/transports/dji_mic_transport.dart';
import 'package:omi/utils/logger.dart';

const String djiMicAudioServiceUuid = 'dji-mic-audio-service';
const String djiMicAudioDataCharacteristicUuid = 'dji-mic-audio-data';

/// DJI Mic 3 as an Omi capture device: audio only, no camera/storage/button
/// analogs — those `perform*` overrides honestly report unavailable rather
/// than faking success. Adapter over [DjiMicTransport]: audio arrives as
/// PCM16 mono @16kHz frames from the transmitter's Bluetooth
/// SCO/communication-device route. Mirrors RayBanMetaDeviceConnection's
/// shape, trimmed to the audio-only slice — see that class for the full
/// pattern this is a leaner sibling of.
class DjiMicDeviceConnection extends DeviceConnection {
  DjiMicDeviceConnection(super.device, super.transport);

  DjiMicTransport get _djiTransport => transport as DjiMicTransport;

  @override
  Future<void> connect({Function(String deviceId, DeviceConnectionState state)? onConnectionStateChanged}) async {
    await super.connect(onConnectionStateChanged: onConnectionStateChanged);
  }

  @override
  Future<bool> isConnected() async {
    return await transport.isConnected();
  }

  @override
  Future<void> disconnect() async {
    await transport.disconnect();
    connectionState = DeviceConnectionState.disconnected;
  }

  /// DJI Mic 3 has no battery-level API exposed over this route.
  @override
  Future<int> performRetrieveBatteryLevel() async {
    return -1;
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int p1)? onBatteryLevelChange,
  }) async {
    return null;
  }

  @override
  Future<StreamSubscription?> performGetBleAudioBytesListener({
    required void Function(List<int> p1) onAudioBytesReceived,
  }) async {
    final stream = transport.getCharacteristicStream(djiMicAudioServiceUuid, djiMicAudioDataCharacteristicUuid);
    final subscription = stream.listen((bytes) {
      onAudioBytesReceived(bytes);
    });

    // The mic only flows once native capture starts; start it when the
    // capture pipeline attaches, so listening state == capturing state —
    // mirrors RayBanMetaDeviceConnection.performGetBleAudioBytesListener.
    try {
      await _djiTransport.startAudioCapture();
    } catch (e) {
      Logger.debug('DJI Mic 3: failed to start audio capture: $e');
    }

    return subscription;
  }

  @override
  Future<BleAudioCodec> performGetAudioCodec() async {
    return BleAudioCodec.pcm16;
  }

  @override
  Future performCameraStartPhotoController() async => null;

  @override
  Future performCameraStopPhotoController() async => null;

  @override
  Future<bool> performHasPhotoStreamingCharacteristic() async => false;

  @override
  Future<StreamSubscription?> performGetImageListener({
    required void Function(OrientedImage orientedImage) onImageReceived,
  }) async {
    return null;
  }

  @override
  Future<List<int>> performGetButtonState() async {
    return <int>[];
  }

  @override
  Future<StreamSubscription?> performGetBleButtonListener({
    required void Function(List<int> p1) onButtonReceived,
  }) async {
    return null;
  }

  @override
  Future<bool> performPlayToSpeakerHaptic(int mode) async {
    return false;
  }

  @override
  Future<List<int>> performGetStorageList() async {
    return <int>[];
  }

  @override
  Future<bool> performWriteToStorage(int numFile, int command, int offset) async {
    return false;
  }

  @override
  Future<StreamSubscription?> performGetBleStorageBytesListener({
    required void Function(List<int> p1) onStorageBytesReceived,
  }) async {
    return null;
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetAccelListener({void Function(int p1)? onAccelChange}) async {
    return null;
  }

  @override
  Future<int> performGetFeatures() async {
    return 0;
  }

  @override
  Future<void> performSetLedDimRatio(int ratio) async {
    return;
  }

  @override
  Future<int?> performGetLedDimRatio() async {
    return null;
  }

  @override
  Future<void> performSetMicGain(int gain) async {
    return;
  }

  @override
  Future<int?> performGetMicGain() async {
    return null;
  }
}
