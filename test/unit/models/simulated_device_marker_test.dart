import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/services/simulated_device_service.dart';
import 'package:reaprime/src/settings/settings_service.dart';

void main() {
  test('every device SimulatedDeviceService produces implements the '
      'SimulatedDevice marker', () async {
    // Forcing function: a mock added to the simulate service WITHOUT the marker
    // would be wrongly eligible for the remembered registry — fromDevice only
    // skips devices that are `is SimulatedDevice`. Driving the real service
    // (rather than a hand-maintained list) keeps this honest as mocks are added.
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

    // Only MockScale starts a Timer in its constructor; stop it so the test
    // zone has no pending timers. (Machines/sensors are timer-free until
    // onConnect, which the service never calls.)
    for (final d in devices) {
      if (d.type == DeviceType.scale) await d.disconnect();
    }
  });
}
