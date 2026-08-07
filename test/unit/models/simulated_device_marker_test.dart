import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/services/simulated_device_service.dart';
import 'package:reaprime/src/settings/settings_service.dart';

void main() {
  test('every device SimulatedDeviceService produces implements the '
      'SimulatedDevice marker', () async {
    final service = SimulatedDeviceService()
      ..enabledDevices = SimulatedDevicesTypes.values.toSet();

    final devices = <Device>[];
    final sub = service.devices.listen(devices.addAll);
    await service.scanForDevices();
    await Future.delayed(Duration.zero);
    await sub.cancel();

    expect(devices, isNotEmpty);
    expect(
      devices.length,
      greaterThanOrEqualTo(5),
      reason: 'expected all simulated device types to be produced',
    );
    for (final d in devices) {
      expect(
        d,
        isA<SimulatedDevice>(),
        reason: '${d.deviceId} must implement SimulatedDevice',
      );
    }

    for (final d in devices) {
      if (d.type == DeviceType.scale) await d.disconnect();
    }
  });
}
