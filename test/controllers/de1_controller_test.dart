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

  group('adoptDevice', () {
    test('replacing an already-adopted device does not emit an interim null '
        'on de1', () async {
      await runZonedGuarded(() async {
        final deviceController = DeviceController([
          MockDeviceDiscoveryService(),
        ]);
        await deviceController.initialize();
        final de1Controller = De1Controller(controller: deviceController);
        final first = TestDe1(deviceId: 'de1-a');
        final second = TestDe1(deviceId: 'de1-b');

        final emissions = <De1Interface?>[];
        final sub = de1Controller.de1.listen(emissions.add);

        de1Controller.adoptDevice(first);
        first.emitShotSettings(_emptyShotSettings());
        await Future<void>.delayed(Duration.zero);
        expect(de1Controller.connectedDe1OrNull, same(first));

        de1Controller.adoptDevice(second);
        second.emitShotSettings(_emptyShotSettings());
        await Future<void>.delayed(Duration.zero);

        expect(de1Controller.connectedDe1OrNull, same(second));
        expect(
          emissions,
          [null, first, second],
          reason:
              'adopting a replacement device must transition directly '
              'from the previous device to the new one — an interim '
              'null reads as an unexpected disconnect downstream',
        );

        await sub.cancel();
        await first.dispose();
        await second.dispose();
      }, (_, _) {});
    });
  });

  group('seenSerials', () {
    test('retains serials after the device disconnects', () async {
      await runZonedGuarded(() async {
        final deviceController = DeviceController([
          MockDeviceDiscoveryService(),
        ]);
        await deviceController.initialize();
        final de1Controller = De1Controller(controller: deviceController);
        final testDe1 = TestDe1(serialNumber: '123456');

        await de1Controller.connectToDe1(testDe1);
        testDe1.emitShotSettings(_emptyShotSettings());
        await Future<void>.delayed(Duration.zero);
        expect(de1Controller.seenSerials, contains('123456'));

        testDe1.setConnectionState(ConnectionState.disconnected);
        await Future<void>.delayed(Duration.zero);

        expect(de1Controller.seenSerials, contains('123456'));

        testDe1.dispose();
      }, (_, _) {});
    });

    test('accumulates serials across device switches', () async {
      await runZonedGuarded(() async {
        final deviceController = DeviceController([
          MockDeviceDiscoveryService(),
        ]);
        await deviceController.initialize();
        final de1Controller = De1Controller(controller: deviceController);

        final first = TestDe1(serialNumber: '111111');
        await de1Controller.connectToDe1(first);
        first.emitShotSettings(_emptyShotSettings());
        await Future<void>.delayed(Duration.zero);

        final second = TestDe1(serialNumber: '222222');
        await de1Controller.connectToDe1(second);
        second.emitShotSettings(_emptyShotSettings());
        await Future<void>.delayed(Duration.zero);

        expect(de1Controller.seenSerials, containsAll(['111111', '222222']));

        first.dispose();
        second.dispose();
      }, (_, _) {});
    });
  });

  group('initial shot settings', () {
    test('missing initial settings do not block initialization', () async {
      final deviceController = DeviceController([MockDeviceDiscoveryService()]);
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
    }, timeout: const Timeout(Duration(seconds: 5)));
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

            await de1Controller.connectToDe1(testDe1);

            testDe1.emitShotSettings(_emptyShotSettings());
            await Future<void>.delayed(Duration.zero);

            testDe1.setConnectionState(ConnectionState.disconnected);
            await Future<void>.delayed(Duration.zero);

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
