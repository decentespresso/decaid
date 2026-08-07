import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/serial/serial_service.dart';

void main() {
  group('NoOpSerialService contract', () {
    test('initialize() completes without throwing', () async {
      final service = NoOpSerialService();
      await expectLater(service.initialize(), completes);
    });

    test('scanForDevices() completes without throwing', () async {
      final service = NoOpSerialService();
      await expectLater(service.scanForDevices(), completes);
    });

    test('stopScan() is a no-op', () {
      final service = NoOpSerialService();
      expect(service.stopScan, returnsNormally);
    });

    test(
      'devices stream emits an empty list synchronously on subscribe',
      () async {
        final service = NoOpSerialService();
        final first = await service.devices.first.timeout(
          const Duration(seconds: 2),
        );
        expect(
          first,
          isEmpty,
          reason:
              'DeviceController seeds its per-service device map from '
              'the first emission — a silent stream stalls the controller',
        );
      },
    );
  });
}
