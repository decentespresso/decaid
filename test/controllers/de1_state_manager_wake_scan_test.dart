import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/de1_state_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:rxdart/rxdart.dart';
import 'package:reaprime/src/plugins/plugin_scale.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_device_contract.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_device_scanner.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_de1.dart';

class _SpyConnectionManager extends ConnectionManager {
  _SpyConnectionManager({
    required super.deviceScanner,
    required super.de1Controller,
    required super.scaleController,
    required super.settingsController,
  });

  int scaleSleepMarks = 0;

  @override
  void markScaleSleeping(String deviceId) {
    scaleSleepMarks++;
    super.markScaleSleeping(deviceId);
  }
}

class _ControllerBleTransport extends BLETransport {
  final BehaviorSubject<ConnectionState> _state = BehaviorSubject.seeded(
    ConnectionState.disconnected,
  );
  ConnectionState nativeState = ConnectionState.disconnected;
  final writes = <Uint8List>[];
  void Function(Uint8List)? callback;
  int disconnectCalls = 0;

  @override
  String get id => 'decent-controller-scale';

  @override
  String get name => 'Decent Controller Scale';

  @override
  Stream<ConnectionState> get connectionState => _state.stream;

  @override
  Future<ConnectionState> getConnectionState() async => nativeState;

  @override
  Future<void> connect() async {
    nativeState = ConnectionState.connected;
    _state.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    nativeState = ConnectionState.disconnected;
    _state.add(ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async => [
    DecentScale.serviceIdentifier.long,
  ];

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) handler,
  ) async {
    callback = handler;
  }

  @override
  Future<void> resetSubscription(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) handler,
  ) => subscribe(serviceUUID, characteristicUUID, handler);

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    final frame = Uint8List.fromList(data);
    writes.add(frame);
    if (frame.length == 7 && frame[1] == 0x0A && frame[2] == 0x01) {
      scheduleMicrotask(
        () => callback?.call(
          Uint8List.fromList([0x03, 0x0A, 0x00, 0x00, 0x64, 0x02, 0x00]),
        ),
      );
    }
  }

  @override
  Future<void> dispose() async {
    await _state.close();
  }
}

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
  late _SpyConnectionManager connectionManager;
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

    connectionManager = _SpyConnectionManager(
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

  test('plugin display-off disconnect sleeps until machine wake', () async {
    mockScanner.supportsWatch = true;
    await settingsController.setPreferredScaleId('plugin-scale');
    await settingsController.setScalePowerMode(ScalePowerMode.displayOff);
    final operations = <PluginDeviceOperation>[];
    late PluginScale scale;
    scale = PluginScale(
      deviceId: 'plugin-scale',
      name: 'Scale',
      capabilities: {PluginScaleCapability.disconnectToSleep},
      invoke: (operation, payload) async {
        operations.add(operation);
        if (operation == PluginDeviceOperation.connect) {
          scale.publish({'weight': 1}, session: payload['session'] as String);
        }
        return {};
      },
    );
    addTearDown(scale.dispose);
    await scaleController.connectToScale(scale);
    de1Controller.connect(testDe1);
    await pump();
    testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    await pump();
    testDe1.emitStateAndSubstate(MachineState.sleeping, MachineSubstate.idle);
    await pump(6);
    expect(operations, contains(PluginDeviceOperation.disconnect));
    expect(mockScanner.scanCallCount, 0);
    final watchStarts = mockScanner.startWatchCallCount;
    await pump(6);
    expect(mockScanner.startWatchCallCount, watchStarts);
    testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    await pump(6);
    expect(mockScanner.startWatchCallCount, greaterThan(watchStarts));
  });

  test(
    'decent scale displayOff keeps the connection through machine sleep',
    () async {
      mockScanner.supportsWatch = true;
      await settingsController.setScalePowerMode(ScalePowerMode.displayOff);
      final transport = _ControllerBleTransport();
      final scale = DecentScale(transport: transport);
      await scaleController.connectToScale(scale);
      de1Controller.connect(testDe1);
      await pump();
      expect(transport.nativeState, ConnectionState.connected);

      testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
      await pump();
      transport.writes.clear();
      transport.disconnectCalls = 0;

      testDe1.emitStateAndSubstate(MachineState.sleeping, MachineSubstate.idle);
      await pump(6);

      expect(connectionManager.scaleSleepMarks, 0);
      expect(transport.disconnectCalls, 0);
      expect(transport.nativeState, ConnectionState.connected);
      expect(scale, isNot(isA<DisconnectToSleepScale>()));
      expect(
        transport.writes.any(
          (data) => data.length == 7 && data[1] == 0x0A && data[2] == 0x00,
        ),
        isTrue,
      );
      expect(
        transport.writes.any(
          (data) => data.length == 7 && data[1] == 0x0A && data[2] == 0x04,
        ),
        isFalse,
      );

      await scale.disconnectForHandoff();
      await transport.dispose();
    },
  );

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
