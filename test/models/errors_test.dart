import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/errors.dart';

import '../helpers/mock_device_discovery_service.dart';

void main() {
  group('DeviceNotConnectedException', () {
    test('machine constructor tags kind and message', () {
      const e = DeviceNotConnectedException.machine();
      expect(e.kind, DeviceKind.machine);
      expect(e.toString(), contains('machine not connected'));
    });

    test('scale constructor tags kind and message', () {
      const e = DeviceNotConnectedException.scale();
      expect(e.kind, DeviceKind.scale);
      expect(e.toString(), contains('scale not connected'));
    });
  });

  group('De1Controller.connectedDe1 when nothing connected', () {
    test('throws DeviceNotConnectedException with machine kind', () {
      final controller = De1Controller(
        controller: DeviceController([MockDeviceDiscoveryService()]),
      );
      expect(
        () => controller.connectedDe1(),
        throwsA(
          isA<DeviceNotConnectedException>().having(
            (e) => e.kind,
            'kind',
            DeviceKind.machine,
          ),
        ),
      );
    });
  });

  group('ScaleController.connectedScale when nothing connected', () {
    test('throws DeviceNotConnectedException with scale kind', () {
      final controller = ScaleController();
      expect(
        () => controller.connectedScale(),
        throwsA(
          isA<DeviceNotConnectedException>().having(
            (e) => e.kind,
            'kind',
            DeviceKind.scale,
          ),
        ),
      );
    });
  });

  group('MmrTimeoutException', () {
    test('records item name and timeout in toString', () {
      const e = MmrTimeoutException('fanThreshold', Duration(seconds: 2));
      expect(e.mmrItemName, 'fanThreshold');
      expect(e.timeout, const Duration(seconds: 2));
      expect(e.toString(), contains('fanThreshold'));
      expect(e.toString(), contains('0:00:02'));
    });
  });
}
