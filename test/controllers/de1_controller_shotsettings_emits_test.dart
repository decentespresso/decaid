import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/home_feature/forms/hot_water_form.dart';
import 'package:reaprime/src/home_feature/forms/steam_form.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';

import '../helpers/mock_device_discovery_service.dart';

/// Counts every event that crosses `MockDe1.shotSettings` — the same
/// stream `/ws/v1/machine/shotSettings` delivers to clients. These
/// tests pin the emit-count contract per De1Controller write op so we
/// catch regressions in the number of WS messages per workflow change.
///
/// Context: the original redundant-writes report observed 5 WS emits
/// per single steam-duration PUT. After adding value equality on the
/// workflow data classes, awaiting individual settings writes in
/// WorkflowHandler, dropping the `setXFlow` nudge re-emit in
/// MockDe1/UnifiedDe1, and applying `.distinct()` on the shotSettings
/// getter, the count is 1 per changed field.
void main() {
  late MockDe1 mockDe1;
  late DeviceController deviceController;
  late De1Controller de1Controller;
  late List<De1ShotSettings> observedEmits;
  late StreamSubscription<De1ShotSettings> sub;

  setUp(() async {
    mockDe1 = MockDe1();
    deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = De1Controller(controller: deviceController);
    await de1Controller.connectToDe1(mockDe1);

    observedEmits = [];
    sub = mockDe1.shotSettings.listen(observedEmits.add);

    // Let the De1Controller initialization + its internal 100 ms
    // shot-settings debounce settle before the test body runs.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    observedEmits.clear();
  });

  tearDown(() async {
    await sub.cancel();
  });

  group('updateSteamSettings — shotSettings emit count', () {
    test('exactly one emit per steam change', () async {
      await de1Controller.updateSteamSettings(
        SteamFormSettings(
          steamEnabled: true,
          targetTemp: 150,
          targetDuration: 30,
          targetFlow: 2.5,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        observedEmits.length,
        equals(1),
        reason:
            'nudge re-emits are gone and `.distinct()` on the '
            'getter collapses firmware echoes — only the actual '
            'updateShotSettings write should reach the WS stream',
      );
      expect(observedEmits.single.targetSteamDuration, equals(30));
    });

    test(
      'multi-field De1Controller sequence: one emit per updateShotSettings',
      () async {
        // Mirrors what WorkflowHandler does for a multi-field PUT that
        // touches steam + hot-water + rinse (the original 5-emit
        // report). With value equality + sequential awaits + nudge
        // removal + distinct, the expected output is one emit per
        // path that actually performs an updateShotSettings write.
        await de1Controller.updateFlushSettings(
          RinseData(targetTemperature: 91, duration: 11, flow: 6.5),
        );
        await de1Controller.updateSteamSettings(
          SteamFormSettings(
            steamEnabled: true,
            targetTemp: 150,
            targetDuration: 44,
            targetFlow: 2.5,
          ),
        );
        await de1Controller.updateHotWaterSettings(
          HotWaterFormSettings(
            targetTemperature: 76,
            flow: 10.0,
            volume: 50,
            duration: 55,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // rinse  : no updateShotSettings call (only MMR writes).
        // steam  : 1 updateShotSettings with new steam fields.
        // hw     : 1 updateShotSettings with new hw fields.
        expect(
          observedEmits.length,
          equals(2),
          reason:
              '1 steam write + 1 hot-water write. Regression guard:'
              ' nudge leaks or race-induced duplicates would push this '
              'higher.',
        );
        expect(observedEmits.last.targetSteamDuration, equals(44));
        expect(observedEmits.last.targetHotWaterDuration, equals(55));
      },
    );

    test('flow-only change via De1Controller.setSteamFlow emits no '
        'shotSettings event but does broadcast steamData', () async {
      final steamDataEmits = <SteamSettings>[];
      final steamSub = de1Controller.steamData.listen(steamDataEmits.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      steamDataEmits.clear();

      await de1Controller.setSteamFlow(3.3);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        observedEmits,
        isEmpty,
        reason:
            'flow is not part of the shotSettings characteristic, '
            'so setSteamFlow must not cause a shotSettings emit',
      );
      expect(
        steamDataEmits.map((s) => s.flow).toList(),
        contains(3.3),
        reason:
            'steamData subscribers must receive the new flow so '
            'UI (status tile, live slider) refreshes',
      );

      await steamSub.cancel();
    });
  });
}
