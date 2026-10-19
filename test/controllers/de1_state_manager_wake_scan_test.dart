import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/de1_state_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/remembered_devices_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
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
import '../helpers/test_scale.dart';

class _SpyConnectionManager extends ConnectionManager {
  _SpyConnectionManager({
    required super.deviceScanner,
    required super.de1Controller,
    required super.scaleController,
    required super.settingsController,
    super.rememberedDevices,
  });

  int scaleSleepMarks = 0;
  final connectCalls = <bool>[];

  @override
  Future<void> connect({bool scaleOnly = false}) {
    connectCalls.add(scaleOnly);
    return super.connect(scaleOnly: scaleOnly);
  }

  @override
  void markScaleSleeping(String deviceId) {
    scaleSleepMarks++;
    super.markScaleSleeping(deviceId);
  }
}

class _DisplayScale extends TestScale {
  int sleepDisplayCalls = 0;
  int wakeDisplayCalls = 0;

  @override
  Future<void> sleepDisplay() async {
    sleepDisplayCalls++;
  }

  @override
  Future<void> wakeDisplay() async {
    wakeDisplayCalls++;
  }
}

class _ControllerBleTransport extends BLETransport {
  _ControllerBleTransport({this.respondToVoltage = false});

  final bool respondToVoltage;
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
    if (frame.length == 7 && frame[1] == 0x22 && respondToVoltage) {
      scheduleMicrotask(
        () => callback?.call(
          Uint8List.fromList([0x03, 0x22, 0x01, 0x89, 0x00, 0x00, 0xA9]),
        ),
      );
    }
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

class _BlockingControllerBleTransport extends _ControllerBleTransport {
  _BlockingControllerBleTransport() : super(respondToVoltage: true);

  final discoveryStarted = Completer<void>();
  final continueDiscovery = Completer<void>();

  @override
  Future<List<String>> discoverServices() async {
    discoveryStarted.complete();
    await continueDiscovery.future;
    return super.discoverServices();
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
  late RememberedDevicesController rememberedDevices;
  late StreamController<RememberedDevice?> scaleConnections;
  late _SpyConnectionManager connectionManager;
  late De1StateManager manager;

  Future<void> pump([int n = 3]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  De1StateManager createStateManager() => De1StateManager(
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
    scaleConnections = StreamController<RememberedDevice?>.broadcast();
    rememberedDevices = RememberedDevicesController(
      machineConnections: const Stream.empty(),
      scaleConnections: scaleConnections.stream,
      settings: settingsService,
    );
    await rememberedDevices.initialize();

    connectionManager = _SpyConnectionManager(
      deviceScanner: mockScanner,
      de1Controller: de1Controller,
      scaleController: scaleController,
      settingsController: settingsController,
      rememberedDevices: rememberedDevices,
    );

    manager = createStateManager();
  });

  tearDown(() async {
    manager.dispose();
    await connectionManager.dispose();
    await rememberedDevices.dispose();
    await scaleConnections.close();
    await testDe1.dispose();
    mockScanner.dispose();
  });

  for (final connectedOnWake in [true, false]) {
    test(
      connectedOnWake
          ? 'wake only wakes the connected displayOff scale once'
          : 'wake with a disconnected scale does not wake or recover it',
      () async {
        manager.dispose();
        await connectionManager.dispose();
        final time = FakeAsync();
        Future<void> settle() async {
          for (var i = 0; i < 6; i++) {
            time.flushMicrotasks();
            await pump();
          }
        }

        final scale = _DisplayScale();
        addTearDown(scale.dispose);
        time.run((_) {
          de1Controller = _TestDe1Controller(controller: DeviceController([]));
          scaleController = ScaleController();
          connectionManager = _SpyConnectionManager(
            deviceScanner: mockScanner,
            de1Controller: _TestDe1Controller(controller: DeviceController([])),
            scaleController: scaleController,
            settingsController: settingsController,
          );
          manager = createStateManager();
          settingsController.setScalePowerMode(ScalePowerMode.displayOff);
          scaleController.connectToScale(scale);
          de1Controller.connect(testDe1);
        });
        try {
          await settle();
          testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
          await settle();
          testDe1.emitStateAndSubstate(
            MachineState.sleeping,
            MachineSubstate.idle,
          );
          await settle();
          expect(scale.sleepDisplayCalls, 1);
          expect(scale.wakeDisplayCalls, 0);

          if (!connectedOnWake) {
            scale.setConnectionState(ConnectionState.disconnected);
            await settle();
          }
          expect(
            scaleController.currentConnectionState,
            connectedOnWake
                ? ConnectionState.connected
                : ConnectionState.disconnected,
          );
          testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
          await settle();
          expect(scale.wakeDisplayCalls, connectedOnWake ? 1 : 0);
          testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
          time.elapse(const Duration(seconds: 9));
          await settle();

          expect(scale.wakeDisplayCalls, connectedOnWake ? 1 : 0);
          expect(mockScanner.scanCallCount, 0);
          expect(mockScanner.startWatchCallCount, 0);
          expect(connectionManager.connectCalls, isEmpty);
        } finally {
          manager.dispose();
          final disposal = connectionManager.dispose();
          await settle();
          await disposal;
        }
      },
    );
  }

  test('plugin display-off disconnect marks the scale sleeping', () async {
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
    expect(connectionManager.scaleSleepMarks, 1);
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

      transport.writes.clear();
      testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
      await pump(6);
      expect(transport.disconnectCalls, 0);
      expect(transport.nativeState, ConnectionState.connected);
      expect(
        transport.writes.any(
          (data) => data.length == 7 && data[1] == 0x0A && data[2] == 0x01,
        ),
        isTrue,
      );

      await scale.disconnectForHandoff();
      await transport.dispose();
    },
  );

  test(
    'disabling power management applies to the next machine sleep',
    () async {
      await settingsController.setScalePowerMode(ScalePowerMode.disconnect);
      final transport = _ControllerBleTransport();
      final scale = DecentScale(transport: transport);
      await scaleController.connectToScale(scale);
      de1Controller.connect(testDe1);
      await pump();
      testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
      await pump();
      transport.writes.clear();
      transport.disconnectCalls = 0;

      await settingsController.setScalePowerMode(ScalePowerMode.disabled);
      testDe1.emitStateAndSubstate(MachineState.sleeping, MachineSubstate.idle);
      await pump(6);

      expect(transport.disconnectCalls, 0);
      expect(transport.nativeState, ConnectionState.connected);
      expect(transport.writes, isEmpty);
      expect(connectionManager.scaleSleepMarks, 0);

      await scale.disconnectForHandoff();
      await transport.dispose();
    },
  );

  for (final mode in [ScalePowerMode.disabled, ScalePowerMode.disconnect]) {
    test('shutdown respects ${mode.name} at the Decent BLE boundary', () async {
      final transport = _ControllerBleTransport(respondToVoltage: true);
      final scale = DecentScale(transport: transport);
      addTearDown(transport.dispose);
      await scaleController.connectToScale(scale);
      await settingsController.setScalePowerMode(mode);
      expect(scale.debugProfile.capabilities.supportsPowerOff, isTrue);
      transport.writes.clear();

      await connectionManager.shutdown();

      expect(transport.disconnectCalls, 1);
      expect(transport.nativeState, ConnectionState.disconnected);
      expect(
        transport.writes.any(
          (frame) => frame.length == 7 && frame[1] == 0x0A && frame[2] == 0x02,
        ),
        mode == ScalePowerMode.disconnect,
      );
    });
  }

  for (final mode in ScalePowerMode.values) {
    test(
      'shutdown respects ${mode.name} during an in-flight Decent BLE connect',
      () async {
        final transport = _BlockingControllerBleTransport();
        final scale = DecentScale(transport: transport);
        addTearDown(transport.dispose);
        addTearDown(() {
          if (!transport.continueDiscovery.isCompleted) {
            transport.continueDiscovery.complete();
          }
        });
        await settingsController.setScalePowerMode(mode);
        final connecting = connectionManager.connectScale(scale);
        await transport.discoveryStarted.future;
        expect(transport.nativeState, ConnectionState.connected);

        final shutdown = connectionManager.shutdown();
        transport.continueDiscovery.complete();
        final result = await connecting;
        await shutdown;

        expect(result.success, isFalse);
        expect(settingsController.preferredScaleId, isNull);
        expect(
          scaleController.currentConnectionState,
          isNot(ConnectionState.connected),
        );
        expect(scale.debugProfile.capabilities.supportsPowerOff, isTrue);
        expect(transport.disconnectCalls, 1);
        expect(transport.nativeState, ConnectionState.disconnected);
        expect(
          transport.writes.any(
            (frame) =>
                frame.length == 7 && frame[1] == 0x0A && frame[2] == 0x02,
          ),
          mode != ScalePowerMode.disabled,
        );
      },
    );
  }
}
