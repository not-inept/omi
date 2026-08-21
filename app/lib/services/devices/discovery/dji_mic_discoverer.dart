import 'dart:io';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/dji_mic_pigeon.g.dart';
import 'package:omi/services/devices/discovery/device_discoverer.dart';
import 'package:omi/services/devices/discovery/device_locator.dart';
import 'package:omi/utils/logger.dart';

/// Discovers Bluetooth communication-device (HFP/SCO) microphone inputs — DJI
/// Mic 3 is the supported one, but per DjiMicHostApi's own contract this
/// lists whatever paired Bluetooth mic inputs the OS reports, not only
/// DJI-named ones (there is no DJI-specific pairing protocol to discover
/// against — see lib/dji_mic_interface.dart). [looksLikeDjiMic3] is used only
/// to sort a likely match first, never to filter the list, so a user who
/// renamed their transmitter (or is pairing a different Bluetooth mic
/// on purpose) can still find and pick it.
///
/// Android-only for now — see lib/dji_mic_interface.dart and
/// lib/services/devices/transports/dji_mic_transport.dart.
class DjiMicDiscoverer extends DeviceDiscoverer {
  @override
  String get name => 'DJI Mic 3';

  @override
  bool get isSupported => Platform.isAndroid;

  @override
  Future<DeviceDiscoveryResult> discover({int timeout = 5}) async {
    try {
      final host = DjiMicHostApi();
      final inputs = await host.getAvailableInputs();
      final devices = inputs
          .map(
            (input) => BtDevice(
              name: input.name,
              id: input.uid,
              type: DeviceType.djiMic3,
              rssi: 0,
              locator: DeviceLocator.bluetoothCommDevice(),
            ),
          )
          .toList()
        ..sort((a, b) {
          final aMatch = looksLikeDjiMic3(a.name) ? 0 : 1;
          final bMatch = looksLikeDjiMic3(b.name) ? 0 : 1;
          return aMatch.compareTo(bMatch);
        });
      return DeviceDiscoveryResult(devices: devices);
    } catch (e) {
      Logger.debug('DJI Mic 3 discovery error: $e');
      return const DeviceDiscoveryResult(devices: []);
    }
  }

  /// Name-based convenience match for sorting only — DJI's Bluetooth product
  /// names have consistently included "DJI MIC" across the Mic/Mic 2/Mic 3
  /// line as observed in the field.
  static bool looksLikeDjiMic3(String portName) {
    final lower = portName.toLowerCase();
    return lower.contains('dji mic') || lower.contains('dji_mic') || lower.contains('djimic');
  }

  @override
  Future<void> stop() async {
    // Discovery is a stateless snapshot of the currently available inputs.
  }
}
