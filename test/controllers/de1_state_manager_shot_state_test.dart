import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/de1_state_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/shot_state_event.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/data/workflow_context.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/recovering_firmware_transport.dart';
import '../helpers/test_de1.dart';
import '../helpers/test_scale.dart';

class _TestDe1Controller extends De1Controller {
  final BehaviorSubject<De1Interface?> de1Subject = BehaviorSubject.seeded(
    null,
  );
  De1Interface? current;
  int connectedLookupCount = 0;
  int? failConnectedLookupAt;

  _TestDe1Controller({required super.controller});

  @override
  Stream<De1Interface?> get de1 => de1Subject.stream;

  @override
  De1Interface connectedDe1() {
    connectedLookupCount++;
    if (connectedLookupCount == failConnectedLookupAt) {
      throw 'machine info unavailable';
    }
    final de1 = current;
    if (de1 == null) throw 'no de1 connected';
    return de1;
  }

  void connect(De1Interface de1) {
    current = de1;
    de1Subject.add(de1);
  }

  void disconnect() {
    current = null;
    de1Subject.add(null);
  }
}

class _UnknownCalibrationDe1 extends TestDe1 {
  @override
  double? get cachedFlowEstimation => null;
}

class _MutableCalibrationDe1 extends TestDe1 {
  double? calibration = 1.0;

  @override
  double? get cachedFlowEstimation => calibration;
}

class _RecoveredCacheDe1 extends TestDe1 {
  _RecoveredCacheDe1(this.device);

  final UnifiedDe1 device;

  @override
  double? get cachedFlowEstimation => device.cachedFlowEstimation;
}

Future<void> _pumpUntil(bool Function() condition, String label) async {
  for (var turn = 0; turn < 500; turn++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition not met: $label');
}

class _CapturingStorageService implements StorageService {
  final List<ShotRecord> storedShots = [];

  @override
  Future<void> storeShot(ShotRecord record) async => storedShots.add(record);
  @override
  Future<void> updateShot(ShotRecord record) async {}
  @override
  Future<void> deleteShot(String id) async {}
  @override
  Future<List<String>> getShotIds() async => [];
  @override
  Future<List<ShotRecord>> getAllShots() async => [];
  @override
  Future<ShotRecord?> getShot(String id) async => null;
  @override
  Future<void> storeCurrentWorkflow(Workflow workflow) async {}
  @override
  Future<Workflow?> loadCurrentWorkflow() async => null;
  @override
  Future<List<ShotRecord>> getShotsPaginated({
    int limit = 20,
    int offset = 0,
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
    double? minEnjoyment,
    bool ascending = false,
  }) async => [];
  @override
  Future<int> countShots({
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
    double? minEnjoyment,
  }) async => 0;
  @override
  Future<ShotRecord?> getLatestShot() async => null;
  @override
  Future<ShotRecord?> getLatestShotMeta() async => null;
  @override
  Future<void> storeSteam(SteamRecord record) async {}
  @override
  Future<void> updateSteam(SteamRecord record) async {}
  @override
  Future<void> deleteSteam(String id) async {}
  @override
  Future<List<String>> getSteamIds() async => [];
  @override
  Future<List<SteamRecord>> getAllSteams() async => [];
  @override
  Future<SteamRecord?> getSteam(String id) async => null;
  @override
  Future<SteamRecord?> getLatestSteam() async => null;
  @override
  Future<SteamRecord?> getLatestSteamMeta() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestDe1 testDe1;
  late _TestDe1Controller de1Controller;
  late ScaleController scaleController;
  late _CapturingStorageService storage;
  late WorkflowController workflowController;
  late De1StateManager manager;
  late MockSettingsService settingsService;
  late SettingsController settingsController;
  late List<ShotStateEvent> events;
  late StreamSubscription<ShotStateEvent> eventsSub;

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    testDe1 = TestDe1();
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = _TestDe1Controller(controller: deviceController);
    scaleController = ScaleController();
    storage = _CapturingStorageService();
    workflowController = WorkflowController();

    settingsService = MockSettingsService();
    await settingsService.updateGatewayMode(GatewayMode.tracking);
    settingsController = SettingsController(settingsService);
    await settingsController.loadSettings();

    final connectionManager = ConnectionManager(
      deviceScanner: deviceController,
      de1Controller: de1Controller,
      scaleController: scaleController,
      settingsController: settingsController,
    );

    manager = De1StateManager(
      de1Controller: de1Controller,
      scaleController: scaleController,
      workflowController: workflowController,
      persistenceController: PersistenceController(storageService: storage),
      settingsController: settingsController,
      connectionManager: connectionManager,
      navigatorKey: GlobalKey<NavigatorState>(),
    );

    events = [];
    eventsSub = de1Controller.shotState.listen(events.add);

    de1Controller.connect(testDe1);
    await pump();
  });

  tearDown(() async {
    await eventsSub.cancel();
    manager.dispose();
    await testDe1.dispose();
  });

  Future<void> driveShotOn(TestDe1 device) async {
    device.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.preparingForShot,
    );
    await pump();
    device.emitStateAndSubstate(MachineState.espresso, MachineSubstate.pouring);
    await pump();
    device.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.pouringDone,
    );
    await pump();
  }

  Future<void> driveShot() => driveShotOn(testDe1);

  test('forwards a full shot lifecycle onto De1Controller.shotState and '
      'persists a matching record', () async {
    await driveShot();

    final states = events
        .where((e) => e.event == 'state')
        .map((e) => e.state)
        .toList();
    expect(states, contains(ShotState.preheating));
    expect(states, contains(ShotState.pouring));
    expect(states, contains(ShotState.finished));
    expect(
      states.last,
      ShotState.idle,
      reason: 'the feed re-seeds idle after cleanup',
    );

    final decision = events.singleWhere((e) => e.event == 'decision');
    expect(decision.decision?.kind, ShotDecisionKind.stop);
    expect(decision.decision?.reason, ShotDecisionReason.machineEnded);
    expect(decision.shotId, isNotNull);
    expect(
      decision.timestamp,
      DateTime(2026, 1, 15, 8, 0),
      reason:
          'frames carry the triggering snapshot timestamp (TestDe1 stamps '
          'all snapshots with this fixed time), not publish wall clock, so '
          'clients can align decisions with snapshot telemetry',
    );

    expect(storage.storedShots, hasLength(1));
    final record = storage.storedShots.single;
    expect(record.stopReason, 'machineEnded');
    expect(record.workflow.machine?.flowCalibration, 1.0);
    expect(
      record.workflow.machine?.provenanceStatus,
      WorkflowMachineProvenanceStatus.captured,
    );
    expect(record.workflow.machine?.serialNumber, '1');
    expect(record.workflow.machine?.model, '1');
    expect(record.workflow.machine?.firmwareVersion, '1');
    expect(
      record.id,
      decision.shotId,
      reason:
          'the persisted record id must match the live shotId so '
          'clients can correlate the stream to the saved shot',
    );
  });

  test('shot provenance keeps an unknown flow calibration unknown', () async {
    final unknown = _UnknownCalibrationDe1();
    addTearDown(unknown.dispose);
    de1Controller.connect(unknown);
    await pump();

    unknown.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.preparingForShot,
    );
    await pump();
    unknown.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.pouring,
    );
    await pump();
    unknown.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.pouringDone,
    );
    await pump();
    unknown.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    await pump();

    final record = storage.storedShots.single;
    expect(record.workflow.machine?.flowCalibration, isNull);
    expect(
      record.workflow.machine?.provenanceStatus,
      WorkflowMachineProvenanceStatus.captured,
    );
  });

  test('shot provenance captures the live session multiplier, not the '
      'connect-time value', () async {
    final mutable = _MutableCalibrationDe1();
    addTearDown(mutable.dispose);
    de1Controller.connect(mutable);
    await pump();

    mutable.calibration = 1.5;
    await driveShotOn(mutable);

    final record = storage.storedShots.single;
    expect(record.workflow.machine?.flowCalibration, 1.5);
    expect(
      record.workflow.machine?.provenanceStatus,
      WorkflowMachineProvenanceStatus.captured,
    );
  });

  test('shot provenance records the multiplier refreshed after a transport '
      'recovery', () async {
    final transport = RecoveringFirmwareTransport()
      ..machineRawCalFlowEst = 1000;
    final device = UnifiedDe1(
      transport: transport,
      calibrationTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(device.dispose);
    await device.onConnect();

    transport.machineRawCalFlowEst = 800;
    transport.timeoutNextMmrWrite();
    await device.setFanThreshhold(20);
    await _pumpUntil(
      () => device.cachedFlowEstimation != null,
      'the multiplier refreshed after recovery',
    );
    expect(device.cachedFlowEstimation, closeTo(0.8, 1e-9));
    expect(transport.calFlowEstWrites, isEmpty);

    final proxied = _RecoveredCacheDe1(device);
    addTearDown(proxied.dispose);
    de1Controller.connect(proxied);
    await pump();
    await driveShotOn(proxied);

    final record = storage.storedShots.single;
    expect(record.workflow.machine?.flowCalibration, closeTo(0.8, 1e-9));
    expect(
      record.workflow.machine?.provenanceStatus,
      WorkflowMachineProvenanceStatus.captured,
    );
  });

  test(
    'shot completion stores each complete grinder workflow snapshot',
    () async {
      workflowController.setWorkflow(
        workflowController.currentWorkflow.copyWith(
          id: workflowController.currentWorkflow.id,
          context: const WorkflowContext(
            grinderId: 'grinder-1',
            grinderModel: 'EG1',
            grinderBurrs: 'Core',
            grinderSetting: '12.5',
            grinderRpm: 1200,
            extras: {
              'plugin.grinder': {
                'feedingRate': 4.5,
                'rpmProfile': [900, 1200],
              },
            },
          ),
        ),
      );

      await driveShot();
      final first = storage.storedShots.single;

      workflowController.setWorkflow(
        workflowController.currentWorkflow.copyWith(
          id: workflowController.currentWorkflow.id,
          context: const WorkflowContext(
            grinderId: 'grinder-1',
            grinderModel: 'EG1',
            grinderBurrs: 'Core',
            grinderSetting: '13.0',
            grinderRpm: 1300,
            extras: {
              'plugin.grinder': {
                'feedingRate': 5.5,
                'rpmProfile': [1000, 1300],
              },
            },
          ),
        ),
      );
      testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
      await pump();
      events.clear();
      await driveShot();

      expect(storage.storedShots, hasLength(2));
      expect(first.workflow.context?.grinderSetting, '12.5');
      expect(first.workflow.context?.grinderRpm, 1200);
      expect(first.workflow.context?.extras, {
        'plugin.grinder': {
          'feedingRate': 4.5,
          'rpmProfile': [900, 1200],
        },
      });
      final second = storage.storedShots[1];
      expect(second.workflow.context?.grinderSetting, '13.0');
      expect(second.workflow.context?.grinderRpm, 1300);
      expect(second.workflow.context?.extras, {
        'plugin.grinder': {
          'feedingRate': 5.5,
          'rpmProfile': [1000, 1300],
        },
      });
    },
  );

  test(
    'failed machine capture persists unavailable instead of stale identity',
    () async {
      workflowController.setWorkflow(
        workflowController.currentWorkflow.copyWith(
          machine: const WorkflowMachine(serialNumber: 'stale-machine'),
        ),
      );
      de1Controller.failConnectedLookupAt =
          de1Controller.connectedLookupCount + 3;

      await driveShot();

      expect(storage.storedShots, hasLength(1));
      expect(storage.storedShots.single.workflow.machine?.toJson(), {
        'provenanceStatus': 'unavailable',
      });
    },
  );

  test('keeps forwarding across consecutive shots (per-shot sequencer '
      'recreation)', () async {
    await driveShot();
    final firstShotId = events.singleWhere((e) => e.event == 'decision').shotId;

    testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    await pump();

    events.clear();
    await driveShot();

    final decision = events.singleWhere((e) => e.event == 'decision');
    expect(decision.decision?.reason, ShotDecisionReason.machineEnded);
    expect(
      decision.shotId,
      isNot(firstShotId),
      reason: 'each shot gets its own id',
    );
    expect(storage.storedShots, hasLength(2));
  });

  test('aborting during preheat tears the sequencer down without persisting, '
      'and the next shot gets a fresh id', () async {
    testDe1.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.preparingForShot,
    );
    await pump();
    testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    await pump();

    expect(
      events.any(
        (e) =>
            e.event == 'decision' && e.decision?.kind == ShotDecisionKind.abort,
      ),
      isTrue,
      reason:
          'the aborted preheat emits an abort decision, not a stuck '
          'preheating frame',
    );
    expect(
      events.where((e) => e.event == 'terminal'),
      isEmpty,
      reason:
          'the abort decision is the terminal signal; no duplicate '
          'disconnected frame',
    );
    expect(events.last.state, ShotState.idle);
    expect(events.last.shotId, isNull, reason: 'feed re-seeds idle');
    expect(storage.storedShots, isEmpty);

    events.clear();
    await driveShot();

    expect(storage.storedShots, hasLength(1));
    final decision = events.singleWhere((e) => e.event == 'decision');
    expect(storage.storedShots.single.id, decision.shotId);
    expect(storage.storedShots.single.stopReason, 'machineEnded');
  });

  test(
    'publishes a terminal frame when the machine disconnects mid-shot',
    () async {
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.preparingForShot,
      );
      await pump();
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.pouring,
      );
      await pump();

      de1Controller.disconnect();
      await pump();

      final terminal = events.singleWhere((e) => e.event == 'terminal');
      expect(terminal.decision?.reason, ShotDecisionReason.disconnected);
      expect(
        events.last.state,
        ShotState.idle,
        reason:
            'the feed re-seeds idle so late joiners never see a stale '
            'pouring frame',
      );
      expect(
        storage.storedShots,
        isEmpty,
        reason: 'a disconnected shot is torn down, not persisted',
      );
    },
  );

  group('pour tare confirmation', () {
    final shotTime = DateTime(2026, 1, 15, 8, 0);
    late TestScale scale;

    setUp(() async {
      scale = TestScale();
      await scaleController.connectToScale(scale);
      await scaleController.connectionState.firstWhere(
        (s) => s == device.ConnectionState.connected,
      );
    });

    tearDown(() => scale.dispose());

    void emitScale(double weight) {
      scale.emitSnapshot(
        ScaleSnapshot(timestamp: shotTime, weight: weight, batteryLevel: 90),
      );
    }

    Future<void> startShotOnStuckScale() async {
      emitScale(170.7);
      await pump();
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.preparingForShot,
      );
      await pump();
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.pouring,
      );
      await pump();
    }

    test('an unconfirmed tare aborts a blockOnNoScale shot without saving it, '
        'and the next shot is unaffected', () async {
      await settingsService.setBlockOnNoScale(true);
      await settingsController.loadSettings();

      await startShotOnStuckScale();
      await Future<void>.delayed(const Duration(milliseconds: 3300));

      final aborts = events.where(
        (e) =>
            e.event == 'decision' && e.decision?.kind == ShotDecisionKind.abort,
      );
      expect(aborts, hasLength(1));
      expect(
        aborts.single.decision?.reason,
        ShotDecisionReason.tareUnconfirmed,
      );
      expect(testDe1.requestedStates, contains(MachineState.idle));
      expect(events.where((e) => e.event == 'terminal'), isEmpty);
      expect(events.last.state, ShotState.idle);
      expect(events.last.shotId, isNull);
      expect(storage.storedShots, isEmpty);

      testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
      await pump();
      events.clear();

      emitScale(0.0);
      await pump();
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.preparingForShot,
      );
      await pump();
      emitScale(0.0);
      await pump();
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.pouring,
      );
      await pump();
      emitScale(0.0);
      await pump();
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.pouringDone,
      );
      await pump();

      expect(storage.storedShots, hasLength(1));
      expect(storage.storedShots.single.stopReason, 'machineEnded');
      expect(
        events.where(
          (e) => e.decision?.reason == ShotDecisionReason.tareUnconfirmed,
        ),
        isEmpty,
      );
    });

    test('an unconfirmed tare without blockOnNoScale keeps the shot running '
        'and saves it', () async {
      await startShotOnStuckScale();
      await Future<void>.delayed(const Duration(milliseconds: 3300));

      expect(
        events.where((e) => e.decision?.kind == ShotDecisionKind.abort),
        isEmpty,
      );
      expect(testDe1.requestedStates, isNot(contains(MachineState.idle)));

      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.pouringDone,
      );
      await pump();

      expect(storage.storedShots, hasLength(1));
      expect(storage.storedShots.single.stopReason, 'machineEnded');
      expect(
        events.any((e) => e.scaleLost),
        isTrue,
        reason: 'stop-at-weight is disabled for the rest of the shot',
      );
    });
  });
}
