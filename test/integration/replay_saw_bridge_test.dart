import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/bengle_saw_bridge.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/shot_sequencer.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/data/workflow_context.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_virtual_scale.dart';
import 'package:reaprime/src/models/device/impl/replay/mock_replay_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/services/database/database.dart' hide Workflow;
import 'package:reaprime/src/services/simulated_shot_library.dart';
import 'package:reaprime/src/services/storage/drift_storage_service.dart';

class _EmptyDiscovery extends DeviceDiscoveryService {
  @override
  Stream<List<Device>> get devices => const Stream.empty();
  @override
  Future<void> initialize() async {}
  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}
}

Profile _milkyProfile() => Profile(
  version: '2',
  title: 'Flow profile for milky drinks',
  notes: '',
  author: 'test',
  beverageType: BeverageType.espresso,
  targetVolumeCountStart: 0,
  tankTemperature: 92,
  targetWeight: 3,
  steps: [
    ProfileStepFlow(
      name: 'Pour',
      transition: TransitionType.fast,
      volume: 0,
      seconds: 30,
      temperature: 92,
      sensor: TemperatureSensor.coffee,
      flow: 4,
    ),
  ],
);

Workflow _workflow(Profile profile, double targetYield) => Workflow(
  id: 'replay-saw-test',
  name: profile.title,
  profile: profile,
  context: WorkflowContext(targetDoseWeight: 18, targetYield: targetYield),
  steamSettings: SteamSettings.defaults(),
  hotWaterData: HotWaterData.defaults(),
  rinseData: RinseData.defaults(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Exercises the real target-weight path: the workflow's target yield flows
  // through the BengleSawBridge to ReplayDE1's autonomous SAW, the integrated
  // scale feeds the ShotSequencer, and the shot stops. Also asserts weight is
  // zero during the synthetic pre-shot phase.
  test('workflow target yield stops a replayed shot via the SAW bridge, '
      'with zero pre-shot weight', () async {
    final library = SimulatedShotLibrary();
    await library.ensureLoaded();

    final database = AppDatabase(NativeDatabase.memory());
    final persistence = PersistenceController(
      storageService: DriftStorageService(database),
    );
    final de1Controller = De1Controller(
      controller: DeviceController([_EmptyDiscovery()]),
    );
    final scaleController = ScaleController();
    final workflowController = WorkflowController();
    final profile = _milkyProfile();
    final machine = MockReplayDe1(library: library);

    BengleSawBridge? bridge;
    ShotSequencer? sequencer;
    try {
      await machine.setProfile(profile);

      // Bridge subscribes before connect so it sees the machine appear.
      bridge = BengleSawBridge(
        workflowController: workflowController,
        de1Controller: de1Controller,
        debounce: const Duration(milliseconds: 10),
      );
      await de1Controller.connectToDe1(machine);

      // Integrated scale -> virtual scale -> scale controller.
      final virtualScale = BengleVirtualScale(machine);
      await scaleController.connectToScale(virtualScale);
      await scaleController.connectionState
          .firstWhere((s) => s == ConnectionState.connected)
          .timeout(const Duration(seconds: 2));

      // The workflow target yield propagates to the device via the bridge.
      workflowController.setWorkflow(_workflow(profile, 3));
      await Future.doWhile(() async {
        await Future.delayed(const Duration(milliseconds: 25));
        return (await machine.getStopAtWeightTarget()) != 3.0;
      }).timeout(const Duration(seconds: 3));
      expect(await machine.getStopAtWeightTarget(), 3.0);

      sequencer = ShotSequencer(
        scaleController: scaleController,
        de1controller: de1Controller,
        persistenceController: persistence,
        targetProfile: profile,
        targetYield: profile.targetWeight ?? 0,
        bypassSAW: false,
        blockOnNoScale: false,
        weightFlowMultiplier: 0,
        volumeFlowMultiplier: 0,
        stepExitArbiterEnabled: true,
      );

      await machine.requestState(MachineState.espresso);

      // Pre-shot phase: the integrated scale reads 0.
      final preShotWeights = await machine.weightSnapshot
          .map((s) => s.weight)
          .take(2)
          .toList()
          .timeout(const Duration(seconds: 2));
      expect(
        preShotWeights.every((w) => w == 0.0),
        isTrue,
        reason: 'pre-shot weight must be 0, got $preShotWeights',
      );

      // The device's autonomous SAW stops the shot at the target.
      final idle = await machine.currentSnapshot
          .firstWhere((s) => s.state.state == MachineState.idle)
          .timeout(const Duration(seconds: 20));
      expect(idle.state.state, MachineState.idle);
    } finally {
      bridge?.dispose();
      sequencer?.dispose();
      scaleController.dispose();
      persistence.dispose();
      await machine.disconnect();
      await database.close();
    }
  });
}
