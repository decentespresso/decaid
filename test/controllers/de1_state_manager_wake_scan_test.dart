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
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_device_scanner.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_de1.dart';

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
}

class _NoopStorageService implements StorageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<dynamic>.value(null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestDe1 testDe1;
  late _TestDe1Controller de1Controller;
  late ScaleController scaleController;
  late MockDeviceScanner mockScanner;
  late SettingsController settingsController;
  late ConnectionManager connectionManager;
  late De1StateManager manager;

  Future<void> pump([int n = 3]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() async {
    testDe1 = TestDe1();
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = _TestDe1Controller(controller: deviceController);
    scaleController = ScaleController();
    mockScanner = MockDeviceScanner();

    final settingsService = MockSettingsService();
    settingsController = SettingsController(settingsService);
    await settingsController.loadSettings();

    connectionManager = ConnectionManager(
      deviceScanner: mockScanner,
      de1Controller: de1Controller,
      scaleController: scaleController,
      settingsController: settingsController,
    );

    manager = De1StateManager(
      de1Controller: de1Controller,
      scaleController: scaleController,
      workflowController: WorkflowController(),
      persistenceController: PersistenceController(
        storageService: _NoopStorageService(),
      ),
      settingsController: settingsController,
      connectionManager: connectionManager,
      navigatorKey: GlobalKey<NavigatorState>(),
    );
    manager.deferredScaleScanDelay = Duration.zero;
  });

  tearDown(() async {
    manager.dispose();
    await connectionManager.dispose();
    await testDe1.dispose();
    mockScanner.dispose();
  });

  Future<void> wakeMachine() async {
    testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    await pump();
    testDe1.emitStateAndSubstate(MachineState.sleeping, MachineSubstate.idle);
    await pump();
    testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    await pump(6);
  }

  test('wake with watch support and a preferred scale skips the '
      'scale-only burst scan', () async {
    mockScanner.supportsWatch = true;
    await settingsController.setPreferredScaleId('pref-scale');
    de1Controller.connect(testDe1);
    await pump();

    await wakeMachine();

    expect(
      mockScanner.scanCallCount,
      0,
      reason:
          'the persistent watch covers reacquisition — a wake burst '
          'would starve the freshly woken DE1 link',
    );
    expect(
      mockScanner.startWatchCallCount,
      greaterThan(0),
      reason: 'the watch (not the burst) must be handling reacquisition',
    );
  });

  test('wake with no preferred scale still runs the discovery burst', () async {
    mockScanner.supportsWatch = true;
    de1Controller.connect(testDe1);
    await pump();

    await wakeMachine();

    expect(
      mockScanner.scanCallCount,
      1,
      reason:
          'without a preferred scale the watch cannot help — the '
          'burst feeds discovery/picker',
    );
  });

  test('wake without watch support runs the legacy burst', () async {
    mockScanner.supportsWatch = false;
    await settingsController.setPreferredScaleId('pref-scale');
    de1Controller.connect(testDe1);
    await pump();

    await wakeMachine();

    expect(
      mockScanner.scanCallCount,
      1,
      reason: 'non-watch platforms keep the legacy wake reconnect',
    );
  });
}
