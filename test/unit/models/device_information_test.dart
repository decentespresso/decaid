import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';

void main() {
  test('serializes manual USB power provenance', () {
    expect(
      const DeviceInformation(
        batteryLevel: 82,
        powerSource: DevicePowerSource.usb,
        powerSourceProvenance: DevicePowerSourceProvenance.manualOverride,
      ).toJson(),
      {
        'batteryLevel': 82,
        'powerSource': 'usb',
        'powerSourceProvenance': 'manualOverride',
      },
    );
  });
}
