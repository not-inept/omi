enum TransportKind { bluetooth, watchConnectivity, metaDat, bluetoothCommDevice }

class DeviceLocator {
  final TransportKind kind;

  // For bluetooth
  final String? bluetoothId;

  // Generic bag for future extensibility
  final Map<String, Object?> extras;

  const DeviceLocator._({required this.kind, this.bluetoothId, this.extras = const {}});

  factory DeviceLocator.bluetooth({required String deviceId, Map<String, Object?> extras = const {}}) {
    return DeviceLocator._(kind: TransportKind.bluetooth, bluetoothId: deviceId, extras: extras);
  }

  factory DeviceLocator.watchConnectivity({Map<String, Object?> extras = const {}}) {
    return DeviceLocator._(kind: TransportKind.watchConnectivity, extras: extras);
  }

  // Ray-Ban Meta glasses reached through the Meta Wearables Device Access
  // Toolkit; the DAT device identifier is carried on BtDevice.id.
  factory DeviceLocator.metaDat({Map<String, Object?> extras = const {}}) {
    return DeviceLocator._(kind: TransportKind.metaDat, extras: extras);
  }

  // A device reached through the OS's Bluetooth communication-device audio
  // route (Bluetooth Classic HFP/SCO) rather than a BLE GATT connection or a
  // vendor SDK — DJI Mic 3 today, and any future device with the same
  // "plain Bluetooth headset mic" profile. The stable HFP/SCO uid is carried
  // on BtDevice.id, mirroring how Ray-Ban Meta's audio-only fallback carries
  // its HFP uid there.
  factory DeviceLocator.bluetoothCommDevice({Map<String, Object?> extras = const {}}) {
    return DeviceLocator._(kind: TransportKind.bluetoothCommDevice, extras: extras);
  }

  // Serialization
  Map<String, dynamic> toJson() {
    return {'kind': kind.index, 'bluetoothId': bluetoothId, 'extras': extras};
  }

  factory DeviceLocator.fromJson(Map<String, dynamic> json) {
    // Persisted kind may be missing, corrupted, or from a newer app version
    // with more enum members — never throw during device deserialization.
    final rawKind = json['kind'];
    final kind = (rawKind is int && rawKind >= 0 && rawKind < TransportKind.values.length)
        ? TransportKind.values[rawKind]
        : TransportKind.bluetooth;
    final rawBluetoothId = json['bluetoothId'];
    final bluetoothId = rawBluetoothId is String && rawBluetoothId.trim().isNotEmpty ? rawBluetoothId : null;
    // Same defensiveness for extras: JSON decoding can yield Map<dynamic, dynamic>.
    final extras = (json['extras'] as Map?)?.map((k, v) => MapEntry(k.toString(), v as Object?)) ?? <String, Object?>{};
    switch (kind) {
      case TransportKind.bluetooth:
        return DeviceLocator._(kind: TransportKind.bluetooth, bluetoothId: bluetoothId, extras: extras);
      case TransportKind.watchConnectivity:
        return DeviceLocator.watchConnectivity(extras: extras);
      case TransportKind.metaDat:
        return DeviceLocator.metaDat(extras: extras);
      case TransportKind.bluetoothCommDevice:
        return DeviceLocator.bluetoothCommDevice(extras: extras);
    }
  }
}
