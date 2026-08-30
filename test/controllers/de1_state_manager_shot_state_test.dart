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
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_de1.dart';

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

class _ButtonScale implements Scale, ScaleButtonCapable {
  final _buttons = StreamController<ScaleButton>.broadcast();
  final _connection = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );
  int tareCount = 0;
  Completer<void>? tareCompleter;
  bool failTare = false;

  @override
  String get deviceId => 'button-scale';
  @override
  String get name => 'Button scale';
  @override
  DeviceType get type => DeviceType.scale;
  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;
  @override
  TransportType get transportType => TransportType.unknown;
  @override
  Stream<ConnectionState> get connectionState => _connection.stream;
  @override
  Stream<ScaleSnapshot> get currentSnapshot => const Stream.empty();
  @override
  Stream<ScaleButton> get buttonPresses => _buttons.stream;
  @override
  Future<void> onConnect() async {}
  @override
  Future<void> disconnect() async =>
      _connection.add(ConnectionState.disconnected);
  @override
  Future<void> tare() async {
    tareCount++;
    if (failTare) throw StateError('tare failed');
    final pending = tareCompleter;
    if (pending != null) await pending.future;
  }
  @override
  Future<void> sleepDisplay() async {}
  @override
  Future<void> wakeDisplay() async {}
  @override
  Future<void> startTimer() async {}
  @override
  Future<void> stopTimer() async {}
  @override
  Future<void> resetTimer() async {}

  void press(ScaleButton button) => _buttons.add(button);
  Future<void> close() async {
    await _buttons.close();
    await _connection.close();
  }
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
  late WorkflowController workflowController;
  late De1StateManager manager;
  late SettingsController settingsController;
  late _ButtonScale buttonScale;
  late List<ShotStateEvent> events;
  late StreamSubscription<ShotStateEvent> eventsSub;

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    testDe1 = TestDe1();
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = _TestDe1Controller(controller: deviceController);
    scaleController = ScaleController();
    buttonScale = _ButtonScale();
    await scaleController.connectToScale(buttonScale);
    storage = _CapturingStorageService();
    workflowController = WorkflowController();

    final settingsService = MockSettingsService();
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
    scaleController.dispose();
    await buttonScale.close();
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

  test('circle button tares and rapid actions serialize with recovery', () async {
    buttonScale.press(ScaleButton.circle);
    await pump();
    expect(buttonScale.tareCount, 1);

    final pending = Completer<void>();
    buttonScale.tareCompleter = pending;
    buttonScale.press(ScaleButton.circle);
    buttonScale.press(ScaleButton.circle);
    await pump();
    expect(buttonScale.tareCount, 2);
    pending.complete();
    await pump();

    buttonScale.tareCompleter = null;
    buttonScale.failTare = true;
    buttonScale.press(ScaleButton.circle);
    await pump();
    buttonScale.failTare = false;
    buttonScale.press(ScaleButton.circle);
    await pump();
    expect(buttonScale.tareCount, 4);
  });

  test('square button is off by default and starts only from idle when opted in', () async {
    buttonScale.press(ScaleButton.square);
    await pump();
    expect(testDe1.requestedStates, isEmpty);

    await settingsController.setScaleButtonStartsEspresso(true);
    testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    await pump();
    buttonScale.press(ScaleButton.square);
    await pump();
    expect(testDe1.requestedStates, [MachineState.espresso]);
  });

  test('square button stops espresso and records app stop intent', () async {
    await settingsController.setScaleButtonStartsEspresso(true);
    testDe1.emitStateAndSubstate(MachineState.espresso, MachineSubstate.pouring);
    await pump();
    buttonScale.press(ScaleButton.square);
    await pump();
    expect(testDe1.requestedStates, [MachineState.idle]);
    expect(de1Controller.consumeStopIntent(), ShotDecisionReason.appStop);
  });

  test('square button is ignored for non-action states, full gateway, and no machine', () async {
    await settingsController.setScaleButtonStartsEspresso(true);
    for (final state in MachineState.values) {
      if (state == MachineState.idle || state == MachineState.espresso) continue;
      testDe1.emitStateAndSubstate(state, MachineSubstate.idle);
      await pump();
      buttonScale.press(ScaleButton.square);
      await pump();
    }
    expect(testDe1.requestedStates, isEmpty);

    await settingsController.updateGatewayMode(GatewayMode.full);
    testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    await pump();
    buttonScale.press(ScaleButton.square);
    await pump();
    expect(testDe1.requestedStates, isEmpty);

    await settingsController.updateGatewayMode(GatewayMode.disabled);
    de1Controller.disconnect();
    await pump();
    buttonScale.press(ScaleButton.square);
    await pump();
    expect(testDe1.requestedStates, isEmpty);
  });

  test('does not act on a stale pending action after machine replacement', () async {
    await settingsController.setScaleButtonStartsEspresso(true);
    testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    await pump();
    final gate = Completer<void>();
    testDe1.requestStateGate = gate;
    buttonScale.press(ScaleButton.square);
    await pump();
    expect(testDe1.requestedStates, [MachineState.espresso]);

    final replacement = TestDe1(deviceId: 'replacement-de1');
    de1Controller.connect(replacement);
    await pump();
    gate.complete();
    await pump();
    buttonScale.press(ScaleButton.square);
    await pump();
    expect(replacement.requestedStates, isEmpty);
    await replacement.dispose();
  });

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
}
