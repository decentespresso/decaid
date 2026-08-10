import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_scale/mock_scale.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/simulated_device_service.dart';
import 'package:reaprime/src/settings/settings_service.dart';

Profile _pourProfile() => Profile(
  version: '1.0',
  title: 'pour',
  notes: '',
  author: 'test',
  beverageType: BeverageType.espresso,
  targetVolumeCountStart: 0,
  tankTemperature: 92.0,
  steps: [
    ProfileStepFlow(
      name: 'pour',
      flow: 4.0,
      seconds: 30,
      temperature: 92,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.fast,
      volume: 0,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SimulatedDeviceService', () {
    test('emits a MockBengle when bengle is enabled', () async {
      final service = SimulatedDeviceService();
      service.enabledDevices = {SimulatedDevicesTypes.bengle};

      final emission = service.devices.first;
      await service.scanForDevices();
      final devices = await emission;

      expect(devices.whereType<MockBengle>(), hasLength(1));
    });

    test('does not emit MockBengle when only machine is enabled', () async {
      final service = SimulatedDeviceService();
      service.enabledDevices = {SimulatedDevicesTypes.machine};

      final emission = service.devices.first;
      await service.scanForDevices();
      final devices = await emission;

      expect(devices.whereType<MockDe1>(), hasLength(1));
      expect(devices.whereType<MockBengle>(), isEmpty);
    });

    test('emits both MockDe1 and MockBengle when both enabled', () async {
      final service = SimulatedDeviceService();
      service.enabledDevices = {
        SimulatedDevicesTypes.machine,
        SimulatedDevicesTypes.bengle,
      };

      final emission = service.devices.first;
      await service.scanForDevices();
      final devices = await emission;

      // MockBengle extends MockDe1, so the type filter matches both —
      // count by deviceId instead.
      final ids = devices.map((d) => d.deviceId).toSet();
      expect(ids, containsAll(['MockDe1', 'MockBengle']));
    });

    test('reuses the same device instances across repeated scans', () async {
      final service = SimulatedDeviceService();
      service.enabledDevices = {
        SimulatedDevicesTypes.machine,
        SimulatedDevicesTypes.scale,
      };

      final firstEmission = service.devices.first;
      await service.scanForDevices();
      final first = await firstEmission;

      final secondEmission = service.devices.first;
      await service.scanForDevices();
      final second = await secondEmission;

      final firstMachine = first.firstWhere((d) => d.deviceId == 'MockDe1');
      final secondMachine = second.firstWhere((d) => d.deviceId == 'MockDe1');
      expect(
        identical(firstMachine, secondMachine),
        isTrue,
        reason: 'rescan must not replace the existing MockDe1 instance',
      );

      final firstScale = first.firstWhere((d) => d.deviceId == 'MockScale');
      final secondScale = second.firstWhere((d) => d.deviceId == 'MockScale');
      expect(
        identical(firstScale, secondScale),
        isTrue,
        reason: 'rescan must not replace the existing MockScale instance',
      );
    });

    test('keeps a connected device connected across a rescan', () async {
      final service = SimulatedDeviceService();
      service.enabledDevices = {SimulatedDevicesTypes.scale};

      final firstEmission = service.devices.first;
      await service.scanForDevices();
      final first = await firstEmission;
      final scale = first.firstWhere((d) => d.deviceId == 'MockScale');
      await scale.onConnect();
      expect(await scale.connectionState.first, ConnectionState.connected);

      // A subsequent scan (e.g. the preferred-scale reconnect retry) must
      // not clobber the connected instance with a fresh `discovered` one.
      final secondEmission = service.devices.first;
      await service.scanForDevices();
      final second = await secondEmission;
      final scaleAfter = second.firstWhere((d) => d.deviceId == 'MockScale');
      expect(
        await scaleAfter.connectionState.first,
        ConnectionState.connected,
        reason: 'rescan replaced the connected scale with a discovered one',
      );
    });

    test('wires MockScale weight to the MockDe1 simulation, even when the '
        'machine is enabled after the scale', () async {
      final service = SimulatedDeviceService();

      // Scale first — no machine to follow yet.
      service.enabledDevices = {SimulatedDevicesTypes.scale};
      await service.scanForDevices();

      // Machine enabled later; the rescan must attach the existing scale.
      service.enabledDevices = {
        SimulatedDevicesTypes.machine,
        SimulatedDevicesTypes.scale,
      };
      final emission = service.devices.first;
      await service.scanForDevices();
      final devices = await emission;

      final de1 = devices.firstWhere((d) => d.deviceId == 'MockDe1') as MockDe1;
      final scale =
          devices.firstWhere((d) => d.deviceId == 'MockScale') as MockScale;

      await de1.onConnect();
      await scale.onConnect();
      await de1.setProfile(_pourProfile());

      // Idle machine: the scale must read ~0, not drift upward on its own.
      final idle = await scale.currentSnapshot.first.timeout(
        const Duration(seconds: 2),
      );
      expect(
        idle.weight.abs(),
        lessThan(0.2),
        reason: 'no weight before the shot starts',
      );

      await de1.requestState(MachineState.espresso);
      await Future.delayed(const Duration(seconds: 4));
      await de1.requestState(MachineState.idle);

      final snapshot = await scale.currentSnapshot.first.timeout(
        const Duration(seconds: 2),
      );
      expect(
        snapshot.weight,
        greaterThan(1.0),
        reason: 'the simulated scale must follow the simulated shot',
      );

      scale.simulateDisconnect();
      await de1.disconnect();
    });

    test('MockScale stays flat at ~0 when no machine is enabled', () async {
      final service = SimulatedDeviceService();
      service.enabledDevices = {SimulatedDevicesTypes.scale};

      final emission = service.devices.first;
      await service.scanForDevices();
      final devices = await emission;
      final scale =
          devices.firstWhere((d) => d.deviceId == 'MockScale') as MockScale;
      await scale.onConnect();

      final samples = await scale.currentSnapshot
          .take(5)
          .toList()
          .timeout(const Duration(seconds: 5));
      for (final s in samples) {
        expect(s.weight.abs(), lessThan(0.2));
      }
      scale.simulateDisconnect();
    });

    test('by default (Replay simulator off) the MockDe1 uses the synthetic '
        'model', () async {
      final service = SimulatedDeviceService();
      // Replay defaults off.
      service.enabledDevices = {SimulatedDevicesTypes.machine};

      final emission = service.devices.first;
      await service.scanForDevices();
      final devices = await emission;
      final de1 = devices.firstWhere((d) => d.deviceId == 'MockDe1') as MockDe1;

      await de1.onConnect();
      await de1.setProfile(_pourProfile());
      await de1.requestState(MachineState.espresso);
      await Future.delayed(const Duration(seconds: 1));

      // The synthetic path never populates the recorded-weight seam.
      expect(
        de1.replayWeightGrams,
        isNull,
        reason: 'synthetic simulator must not expose a recorded weight',
      );
      await de1.disconnect();
    });

    test(
      'with Replay simulator enabled the MockDe1 replays a recorded shot',
      () async {
        final service = SimulatedDeviceService();
        service.setReplayHistoricalShots(true);
        service.enabledDevices = {SimulatedDevicesTypes.machine};

        final emission = service.devices.first;
        await service.scanForDevices();
        final devices = await emission;
        final de1 =
            devices.firstWhere((d) => d.deviceId == 'MockDe1') as MockDe1;

        await de1.onConnect();
        await de1.setProfile(_pourProfile());
        await de1.requestState(MachineState.espresso);
        await Future.delayed(const Duration(seconds: 2));

        // Replay surfaces the recording's real scale weight through this seam.
        expect(
          de1.replayWeightGrams,
          isNotNull,
          reason: 'replay must expose the recorded weight',
        );
        await de1.disconnect();
      },
    );

    test('toggling replay at runtime affects the next shot without recreating '
        'the device', () async {
      final service = SimulatedDeviceService();
      service.enabledDevices = {SimulatedDevicesTypes.machine};
      final emission = service.devices.first;
      await service.scanForDevices();
      final devices = await emission;
      final de1 = devices.firstWhere((d) => d.deviceId == 'MockDe1') as MockDe1;
      await de1.onConnect();
      await de1.setProfile(_pourProfile());

      // Replay off: synthetic path, no recorded weight.
      await de1.requestState(MachineState.espresso);
      await Future.delayed(const Duration(seconds: 1));
      expect(de1.replayWeightGrams, isNull);
      await de1.requestState(MachineState.idle);

      // Enable replay on the SAME instance; the next shot replays.
      service.setReplayHistoricalShots(true);
      await de1.requestState(MachineState.espresso);
      await Future.delayed(const Duration(seconds: 2));
      expect(
        de1.replayWeightGrams,
        isNotNull,
        reason: 'runtime toggle must take effect on the next shot',
      );
      await de1.disconnect();
    });

    test('removes MockBengle when bengle becomes disabled', () async {
      final service = SimulatedDeviceService();
      service.enabledDevices = {SimulatedDevicesTypes.bengle};
      await service.scanForDevices();

      // Switching to a different non-empty set so the next scan still
      // emits (empty enabledDevices early-returns without emission).
      service.enabledDevices = {SimulatedDevicesTypes.machine};
      final emission = service.devices.first;
      await service.scanForDevices();
      final devices = await emission;

      expect(devices.whereType<MockBengle>(), isEmpty);
    });
  });
}
