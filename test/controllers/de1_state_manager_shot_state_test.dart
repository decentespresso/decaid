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
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_de1.dart';

/// De1Controller whose `de1` stream and `connectedDe1()` are test-driven.
class _TestDe1Controller extends De1Controller {
  final BehaviorSubject<De1Interface?> de1Subject = BehaviorSubject.seeded(
    null,
  );
  De1Interface? current;

  _TestDe1Controller({required super.controller});

  @override
  Stream<De1Interface?> get de1 => de1Subject.stream;

  @override
  De1Interface connectedDe1() {
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

/// StorageService that records persisted shots and stores nothing else.
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
  late De1StateManager manager;
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

    final settingsService = MockSettingsService();
    await settingsService.updateGatewayMode(GatewayMode.tracking);
    final settingsController = SettingsController(settingsService);
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
      workflowController: WorkflowController(),
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

  Future<void> driveShot() async {
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
    testDe1.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.pouringDone,
    );
    await pump();
  }

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
    expect(
      record.id,
      decision.shotId,
      reason:
          'the persisted record id must match the live shotId so '
          'clients can correlate the stream to the saved shot',
    );
  });

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

    // A real shot afterwards must not inherit the aborted attempt's id.
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
}
