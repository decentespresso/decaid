import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection/connection_timings.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/errors.dart';

import '../helpers/fake_ble_transport.dart';
import '../helpers/fake_time.dart';
import '../helpers/mock_device_discovery_service.dart';
import '../helpers/test_de1.dart';

final class _SettingsReadDe1 extends TestDe1 {
  _SettingsReadDe1(this.transport);

  final UnifiedDe1Transport transport;

  @override
  Stream<bool> get ready => Stream.value(false);

  @override
  Stream<De1ShotSettings> get shotSettings => transport.shotSettings.map(
    (_) => De1ShotSettings(
      steamSetting: 0,
      targetSteamTemp: 150,
      targetSteamDuration: 30,
      targetHotWaterTemp: 75,
      targetHotWaterVolume: 50,
      targetHotWaterDuration: 30,
      targetShotVolume: 36,
      groupTemp: 94,
    ),
  );

  @override
  Future<void> dispose() async {
    await transport.dispose();
    await super.dispose();
  }
}

void main() {
  late DeviceController devices;
  late De1Controller controller;
  late UnifiedDe1Transport transport;
  late FakeTime time;

  setUp(() async {
    time = FakeTime();
    await time.run(() async {
      devices = DeviceController([MockDeviceDiscoveryService()]);
      await devices.initialize();
      transport = UnifiedDe1Transport(transport: FakeBleTransport());
      controller = De1Controller(controller: devices);
      await controller.connectToDe1(_SettingsReadDe1(transport));
    });
  });

  tearDown(() async {
    await controller.dispose();
    devices.dispose();
    expect(time.pendingTimers, isEmpty);
  });

  test(
    'timed-out controller settings reads release source listeners',
    () async {
      for (var index = 0; index < 3; index++) {
        final timedOut = expectLater(
          time.run(
            () => index.isEven
                ? controller.steamSettings()
                : controller.hotWaterSettings(),
          ),
          throwsA(isA<TimeoutException>()),
        );
        await time.elapse(Duration.zero);
        expect(transport.debugHasShotSettingsListener, isTrue);

        await time.elapse(ConnectionTimings.initialShotSettingsTimeout);
        await timedOut;

        expect(transport.debugHasShotSettingsListener, isFalse);
      }

      await transport.connect();
      expect((await controller.steamSettings()).targetTemp, 150);
      expect(transport.debugHasShotSettingsListener, isFalse);
    },
  );

  test('closed settings reads report the disconnected-machine error', () async {
    await transport.dispose();

    await expectLater(
      controller.hotWaterSettings(),
      throwsA(isA<DeviceNotConnectedException>()),
    );
    expect(transport.debugHasShotSettingsListener, isFalse);
  });
}
