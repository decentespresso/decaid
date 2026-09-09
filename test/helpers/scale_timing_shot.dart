import 'dart:async';

import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/shot_sequencer.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';

import 'test_de1.dart';
import 'test_scale.dart';

class _RecordedScaleController extends ScaleController {
  final samples = StreamController<WeightSnapshot>.broadcast();
  final scale = TestScale();
  WeightSnapshot? latest;
  @override
  Stream<WeightSnapshot> get weightSnapshot => samples.stream;
  @override
  WeightSnapshot? get currentWeightSnapshot => latest;
  @override
  ConnectionState get currentConnectionState => ConnectionState.connected;
  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);
  @override
  Scale connectedScale() => scale;
  @override
  int get connectionGeneration => 1;
}

class _MachineController extends De1Controller {
  final TestDe1 machine;
  _MachineController(this.machine) : super(controller: DeviceController([]));
  @override
  De1Interface connectedDe1() => machine;
  @override
  Future<void> requestMachineState(MachineState state) =>
      machine.requestState(state);
}

class _Storage implements StorageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<dynamic>.value(null);
}

Future<int?> scaleTimingStopIndex(
  List<WeightSnapshot> samples, {
  Duration deliveryAge = Duration.zero,
}) async {
  final controller = _RecordedScaleController();
  final machine = TestDe1();
  final de1 = _MachineController(machine);
  final persistence = PersistenceController(storageService: _Storage());
  controller.latest = samples.first;
  final sequencer = ShotSequencer(
    scaleController: controller,
    de1controller: de1,
    persistenceController: persistence,
    targetProfile: Profile(
      version: '2',
      title: 'Timing',
      notes: '',
      author: 'test',
      beverageType: BeverageType.espresso,
      targetVolumeCountStart: 0,
      tankTemperature: 0,
      targetWeight: 5.45,
      steps: [
        ProfileStepPressure(
          name: 'pour',
          transition: TransitionType.fast,
          volume: 0,
          seconds: 30,
          temperature: 93,
          sensor: TemperatureSensor.coffee,
          pressure: 9,
        ),
      ],
    ),
    targetYield: 5.45,
    bypassSAW: false,
    blockOnNoScale: false,
    weightFlowMultiplier: 1,
    volumeFlowMultiplier: 0,
    stepExitArbiterEnabled: true,
  );
  Future<void> emit(WeightSnapshot sample, MachineSubstate substate) async {
    controller.latest = sample;
    controller.samples.add(sample);
    await Future<void>.delayed(Duration.zero);
    machine.emitSnapshot(
      machine.snapshotSubject.value.copyWith(
        timestamp: sample.timestamp.add(deliveryAge),
        state: MachineStateSnapshot(
          state: MachineState.espresso,
          substate: substate,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }

  try {
    await emit(samples.first, MachineSubstate.preparingForShot);
    await emit(samples.first, MachineSubstate.pouring);
    for (var i = 1; i < samples.length; i++) {
      await emit(samples[i], MachineSubstate.pouring);
      if (machine.requestedStates.contains(MachineState.idle)) return i;
    }
    return null;
  } finally {
    sequencer.dispose();
    await controller.samples.close();
    controller.scale.dispose();
    controller.dispose();
    await de1.dispose();
    await machine.dispose();
    persistence.dispose();
  }
}
