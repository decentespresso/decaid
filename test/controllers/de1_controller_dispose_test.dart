import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';

import '../helpers/mock_device_discovery_service.dart';

/// Regression tests for De1Controller.dispose().
///
/// dispose() must cancel the listeners it registered in connectToDe1()
/// (`ready` + `connectionState`) and the pending shot-settings debounce
/// timer. It cannot rely on `_onDisconnect()` to do that: _de1.dispose()
/// closes the transport subjects, which delivers `onDone` to the
/// connectionState listener rather than a `disconnected` event, so
/// `_onDisconnect()` never runs.
void main() {
  late MockDe1 mockDe1;
  late DeviceController deviceController;
  late De1Controller de1Controller;

  setUp(() async {
    mockDe1 = MockDe1();
    deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = De1Controller(controller: deviceController);
    await de1Controller.connectToDe1(mockDe1);

    await Future<void>.delayed(const Duration(milliseconds: 200));
  });

  test(
    'dispose cancels the connectionState listener (no events after)',
    () async {
      await de1Controller.dispose();

      Object? uncaught;
      await runZonedGuarded(
        () async {
          mockDe1.simulateDisconnect();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        },
        (error, _) {
          uncaught = error;
        },
      );

      expect(
        uncaught,
        isNull,
        reason: 'disconnected event reached a leaked listener after dispose',
      );
    },
  );

  test('dispose closes the de1 stream', () async {
    final done = expectLater(de1Controller.de1, emitsThrough(emitsDone));
    await de1Controller.dispose();
    await done;
  });

  test('dispose is safe to call more than once', () async {
    await de1Controller.dispose();
    // Second call must not throw (subjects already closed, _de1 null).
    await expectLater(de1Controller.dispose(), completes);
  });
}
