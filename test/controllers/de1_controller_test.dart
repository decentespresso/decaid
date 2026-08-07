import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/test_de1.dart';

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
  group('connectedDe1OrNull accessor', () {
    test('returns null when no machine connected', () async {
      final deviceController = DeviceController([MockDeviceDiscoveryService()]);
      await deviceController.initialize();
      final de1Controller = De1Controller(controller: deviceController);

      expect(de1Controller.connectedDe1OrNull, isNull);
    });

    test('returns the connected DE1 once connectToDe1 completes', () async {
      await runZonedGuarded(() async {
        final deviceController = DeviceController([
          MockDeviceDiscoveryService(),
        ]);
        await deviceController.initialize();
        final de1Controller = De1Controller(controller: deviceController);
        final testDe1 = TestDe1();

        await de1Controller.connectToDe1(testDe1);
        // Unblock _initializeData so it does not leak into the test zone.
        testDe1.emitShotSettings(_emptyShotSettings());
        await Future<void>.delayed(Duration.zero);

        expect(de1Controller.connectedDe1OrNull, same(testDe1));

        testDe1.dispose();
      }, (_, _) {});
    });

    test('returns null again after disconnect', () async {
      await runZonedGuarded(() async {
        final deviceController = DeviceController([
          MockDeviceDiscoveryService(),
        ]);
        await deviceController.initialize();
        final de1Controller = De1Controller(controller: deviceController);
        final testDe1 = TestDe1();

        await de1Controller.connectToDe1(testDe1);
        testDe1.emitShotSettings(_emptyShotSettings());
        await Future<void>.delayed(Duration.zero);
        expect(de1Controller.connectedDe1OrNull, isNotNull);

        testDe1.setConnectionState(ConnectionState.disconnected);
        await Future<void>.delayed(Duration.zero);

        expect(de1Controller.connectedDe1OrNull, isNull);

        testDe1.dispose();
      }, (_, _) {});
    });
  });

  group('initial shot settings', () {
    test(
      'missing initial settings do not block initialization',
      () async {
        final deviceController = DeviceController([
          MockDeviceDiscoveryService(),
        ]);
        await deviceController.initialize();
        final de1Controller = De1Controller(controller: deviceController);
        final testDe1 = TestDe1();

        await de1Controller.connectToDe1(testDe1);

        expect(
          await de1Controller.initSettled
              .firstWhere((generation) => generation != null)
              .timeout(const Duration(seconds: 3)),
          isNotNull,
        );
        expect(de1Controller.connectedDe1OrNull, same(testDe1));

        testDe1.dispose();
        de1Controller.dispose();
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );
  });

  group('shot-settings debounce race (comms-harden #5)', () {
    test(
      'disconnect during debounce does not leak an unhandled async error',
      () async {
        final uncaughtErrors = <Object>[];

        await runZonedGuarded(
          () async {
            final deviceController = DeviceController([
              MockDeviceDiscoveryService(),
            ]);
            await deviceController.initialize();
            final de1Controller = De1Controller(controller: deviceController);
            final testDe1 = TestDe1();

            // Kick off connect: TestDe1.onConnect is a no-op, so
            // connectToDe1 completes quickly. ready is Stream.value(true)
            // so _initializeData fires on the next microtask.
            await de1Controller.connectToDe1(testDe1);

            // Unblock _initializeData's `shotSettings.first` await +
            // trigger the first _shotSettingsUpdate, which schedules the
            // 100ms debounce timer.
            testDe1.emitShotSettings(_emptyShotSettings());
            await Future<void>.delayed(Duration.zero);

            // Force a disconnect while the debounce timer is still
            // pending. _onDisconnect bumps _connectionGeneration,
            // nulls _de1, cancels _shotSettingsDebounce, and cancels
            // the shotSettings subscription.
            testDe1.setConnectionState(ConnectionState.disconnected);
            await Future<void>.delayed(Duration.zero);

            // Wait past the 100ms debounce window. With the generation
            // fix, the timer body should find a stale generation (or
            // null _de1) and bail without touching connectedDe1().
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
              'debounce timer closure must bail on disconnect, not leak '
              'DeviceNotConnectedException into the zone',
        );
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );
  });
}
