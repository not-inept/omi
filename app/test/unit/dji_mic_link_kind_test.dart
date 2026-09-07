import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/dji_mic_pigeon.g.dart';
import 'package:omi/services/devices/discovery/device_locator.dart';
import 'package:omi/services/devices/discovery/dji_mic_discoverer.dart';

BtDevice _device({
  DeviceType type = DeviceType.djiMic3,
  String? linkKind,
  String name = 'DJI MIC 3',
  String id = 'A1:B2:C3:D4:E5:F6',
}) {
  return BtDevice(
    name: name,
    id: id,
    type: type,
    rssi: 0,
    locator: DeviceLocator.bluetoothCommDevice(
      extras: linkKind == null ? const {} : {djiMicLinkKindExtra: linkKind},
    ),
  );
}

void main() {
  group('DJI link kind', () {
    test('maps the pigeon enum to the persisted value', () {
      expect(djiMicLinkKindValue(BluetoothMicInputKind.bluetooth), djiMicLinkKindBluetooth);
      expect(djiMicLinkKindValue(BluetoothMicInputKind.usb), djiMicLinkKindUsb);
    });

    test('reads the kind back off a device', () {
      expect(djiMicLinkKindOf(_device(linkKind: djiMicLinkKindUsb)), djiMicLinkKindUsb);
      expect(djiMicLinkKindOf(_device(linkKind: djiMicLinkKindBluetooth)), djiMicLinkKindBluetooth);
    });

    test('a device saved before this field existed has no kind, not a wrong one', () {
      expect(djiMicLinkKindOf(_device()), isNull);
      expect(djiMicLinkLabel(_device()), isNull);
    });

    test('survives the locator round-tripping through JSON', () {
      final locator = DeviceLocator.fromJson(
        _device(linkKind: djiMicLinkKindUsb).locator!.toJson(),
      );
      expect(locator.extras[djiMicLinkKindExtra], djiMicLinkKindUsb);
    });

    test('labels each link, and says nothing about non-DJI devices', () {
      expect(djiMicLinkLabel(_device(linkKind: djiMicLinkKindUsb)), 'Connected by USB-C');
      expect(djiMicLinkLabel(_device(linkKind: djiMicLinkKindBluetooth)), contains('Bluetooth'));
      // Every other device type must render exactly as it did before.
      expect(djiMicLinkLabel(_device(type: DeviceType.omi, linkKind: djiMicLinkKindUsb)), isNull);
    });

    test('name matching sorts a likely DJI first but never filters', () {
      expect(DjiMicDiscoverer.looksLikeDjiMic3('DJI MIC 3 TX'), isTrue);
      expect(DjiMicDiscoverer.looksLikeDjiMic3('dji_mic'), isTrue);
      expect(DjiMicDiscoverer.looksLikeDjiMic3('djimic'), isTrue);
      // A renamed transmitter — the reason the list is unfiltered.
      expect(DjiMicDiscoverer.looksLikeDjiMic3('MAGGY'), isFalse);
    });
  });
}
