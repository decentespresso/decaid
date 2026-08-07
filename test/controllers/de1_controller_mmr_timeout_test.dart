import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/errors.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/test_de1.dart';

/// Regression coverage for Crashlytics issue `a2aee0d1…` — a
/// `MmrTimeoutException` thrown from the shot-settings readback (e.g.
/// `getFlushFlow`) used to bubble out of the debounce Timer callback as
/// an uncaught async error → Flutter error zone → Crashlytics fatal.
///
/// Fix: `_processShotSettingsUpdate`'s caller now catches
/// `MmrTimeoutException` alongside `DeviceNotConnectedException` and
/// logs it at warning level instead.

class _MmrTimingOutDe1 extends TestDe1 {
  _MmrTimingOutDe1()
    : super(deviceId: 'mmr-timeout-de1', name: 'MmrTimeoutDe1');

  @override
  Future<double> getFlushFlow() async {
    throw const MmrTimeoutException('flushFlowRate', Duration(seconds: 2));
  }
}

De1ShotSettings _emptyShotSettings() => De1ShotSettings(
  steamSetting: 0,
  targetSteamTemp: 0,
  targetSteamDuration: 0,
  targetHotWaterTemp: 0,
  targetHotWaterVolume: 0,
  targetHotWaterDuration: 0,
  targetShotVolume: 0,
  groupTemp: 0,
);

void main() {
  test('MmrTimeoutException from shot-settings readback does not leak as '
      'an uncaught async error', () async {
    final uncaughtErrors = <Object>[];

    await runZonedGuarded(
      () async {
        final deviceController = DeviceController([
          MockDeviceDiscoveryService(),
        ]);
        await deviceController.initialize();
        final de1Controller = De1Controller(controller: deviceController);
        final testDe1 = _MmrTimingOutDe1();

        await de1Controller.connectToDe1(testDe1);
        testDe1.emitShotSettings(_emptyShotSettings());

        await Future<void>.delayed(const Duration(milliseconds: 200));

        testDe1.dispose();
      },
      (error, stack) {
        uncaughtErrors.add(error);
      },
    );

    expect(
      uncaughtErrors,
      isEmpty,
      reason:
          'MMR timeouts inside the debounce callback must be caught by '
          'the controller, not escalate to the Flutter error zone',
    );
  });
}
