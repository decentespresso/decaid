import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/shot_sequencer.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_scale/mock_scale.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/storage/drift_storage_service.dart';

class _EmptyDiscovery extends DeviceDiscoveryService {
  @override
  Stream<List<Device>> get devices => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}
}

Profile _targetWeightProfile() => Profile(
  version: '2',
  title: 'Target weight',
  notes: '',
  author: 'test',
  beverageType: BeverageType.espresso,
  targetVolumeCountStart: 0,
  tankTemperature: 92,
  targetWeight: 1,
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

void main() {
  test('simulated shot stops at the configured target weight', () async {
    final database = AppDatabase(NativeDatabase.memory());
    final persistence = PersistenceController(
      storageService: DriftStorageService(database),
    );
    final de1Controller = De1Controller(
      controller: DeviceController([_EmptyDiscovery()]),
    );
    final scaleController = ScaleController();
    final machine = MockDe1();
    final scale = MockScale();
    ShotSequencer? sequencer;

    try {
      await de1Controller.connectToDe1(machine);
      scale.attachMachine(machine);
      await scaleController.connectToScale(scale);
      await scaleController.connectionState
          .firstWhere((state) => state == ConnectionState.connected)
          .timeout(const Duration(seconds: 2));
      await scaleController.weightSnapshot.first.timeout(
        const Duration(seconds: 2),
      );

      final profile = _targetWeightProfile();
      await machine.setProfile(profile);
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

      final stopped = sequencer.decisions.firstWhere(
        (decision) => decision.reason == ShotDecisionReason.targetWeight,
      );
      await machine.requestState(MachineState.espresso);

      final decision = await stopped.timeout(const Duration(seconds: 12));
      expect(decision.kind, ShotDecisionKind.stop);
      expect(decision.data?['targetYield'], profile.targetWeight);
      await machine.currentSnapshot
          .firstWhere((snapshot) => snapshot.state.state == MachineState.idle)
          .timeout(const Duration(seconds: 2));
    } finally {
      sequencer?.dispose();
      scaleController.dispose();
      persistence.dispose();
      scale.simulateDisconnect();
      await machine.disconnect();
      await database.close();
    }
  });
}
