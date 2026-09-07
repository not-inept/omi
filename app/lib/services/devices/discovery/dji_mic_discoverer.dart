import 'dart:io';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/dji_mic_pigeon.g.dart';
import 'package:omi/services/devices/discovery/device_discoverer.dart';
import 'package:omi/services/devices/discovery/device_locator.dart';
import 'package:omi/utils/logger.dart';

/// Discovers communication-device microphone inputs, of both kinds DJI
/// hardware offers: a transmitter paired straight to the phone in DJI's
/// Bluetooth mode, and the receiver plugged into USB-C (a USB audio class
/// input). Per DjiMicHostApi's own contract this lists whatever such inputs
/// the OS reports, not only DJI-named ones (there is no DJI-specific pairing
/// protocol to discover against — see lib/dji_mic_interface.dart).
/// [looksLikeDjiMic3] is used only to sort a likely match first, never to
/// filter the list, so a user who renamed their transmitter (or is using a
/// different mic on purpose) can still find and pick it.
///
/// Android-only for now — see lib/dji_mic_interface.dart and
/// lib/services/devices/transports/dji_mic_transport.dart.
/// Key under which a discovered DJI input records how it is attached, on
/// [DeviceLocator.extras]. Kept there rather than on [BtDevice] itself so it
/// rides along through the existing device serialization untouched — the
/// value is purely for display ("over USB-C" vs "over Bluetooth") and for the
/// caveats the UI needs to state; routing is decided by the uid alone.
const String djiMicLinkKindExtra = 'djiMicLinkKind';

const String djiMicLinkKindBluetooth = 'bluetooth';
const String djiMicLinkKindUsb = 'usb';

String djiMicLinkKindValue(BluetoothMicInputKind kind) =>
    kind == BluetoothMicInputKind.usb ? djiMicLinkKindUsb : djiMicLinkKindBluetooth;

/// How a stored device says it was attached, or null when the device predates
/// this field or is not a DJI input.
String? djiMicLinkKindOf(BtDevice device) {
  final value = device.locator?.extras[djiMicLinkKindExtra];
  return value is String && value.isNotEmpty ? value : null;
}

/// One short line for the device list saying how a DJI input is attached, or
/// null for anything that is not a DJI input (every other device type renders
/// exactly as it did before).
///
/// The Bluetooth caveat is DJI's own: the Mic 3 FAQ states that a transmitter
/// linked straight to a phone carries audio at up to 16 kHz / 16-bit, "similar
/// to Bluetooth headsets", where the receiver path is 48 kHz / 24-bit. Both
/// still arrive at Omi as 16 kHz mono, so the practical difference is what the
/// microphone put into the link, not what the app does with it.
String? djiMicLinkLabel(BtDevice device) {
  if (device.type != DeviceType.djiMic3) return null;
  switch (djiMicLinkKindOf(device)) {
    case djiMicLinkKindUsb:
      return 'Connected by USB-C';
    case djiMicLinkKindBluetooth:
      return 'Paired over Bluetooth · 16 kHz link';
    default:
      return null;
  }
}

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
              locator: DeviceLocator.bluetoothCommDevice(
                extras: {djiMicLinkKindExtra: djiMicLinkKindValue(input.kind)},
              ),
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
