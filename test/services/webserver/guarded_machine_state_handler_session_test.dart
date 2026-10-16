import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/auxiliary_scale_registry.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/plugins/plugin_device_contract.dart';
import 'package:reaprime/src/plugins/plugin_protocol_device.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_de1.dart';
import '../../helpers/test_scale.dart';

final class _PluginLikeScale extends TestScale {
  _PluginLikeScale({required super.deviceId});

  @override
  DeviceImplementation get implementation => DeviceImplementation.plugin;
}

final class _TypedPluginScale extends PluginProtocolDevice implements Scale {
  _TypedPluginScale({required super.deviceId, required this.currentId})
    : super(name: 'Typed plugin scale', invoke: _invoke);

  static Future<Map<String, dynamic>> _invoke(
    PluginDeviceOperation operation,
    Map<String, dynamic> payload,
  ) async => {};

  final String currentId;
  final _connections = BehaviorSubject.seeded(ConnectionState.connected);
  final _snapshots = BehaviorSubject<ScaleSnapshot>();

  @override
  String? get connectionId => currentId;
  @override
  Stream<ConnectionState> get connectionState => _connections.stream;
  @override
  DeviceType get type => DeviceType.scale;
  @override
  Stream<ScaleSnapshot> get currentSnapshot => _snapshots.stream;
  @override
  Future<void> onConnect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> tare() async {}
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
  @override
  void publish(Map<String, dynamic> snapshot, {String? session}) {}
  @override
  Future<void> dispose() async {
    await _connections.close();
    await _snapshots.close();
    await super.dispose();
  }
}

final class _DelayedMachine extends TestDe1 {
  _DelayedMachine({required super.deviceId});

  final _delayedSnapshots = StreamController<MachineSnapshot>();

  @override
  Stream<MachineSnapshot> get currentSnapshot => _delayedSnapshots.stream;

  void emitDelayedSnapshot(MachineSnapshot snapshot) {
    _delayedSnapshots.add(snapshot);
  }

  @override
  Future<void> dispose() async {
    await _delayedSnapshots.close();
    await super.dispose();
  }
}

void main() {
  late De1Controller controller;
  late TestDe1 machine;
  late ScaleController scales;
  late SettingsController settings;
  late Handler handler;

  setUp(() async {
    final devices = DeviceController([MockDeviceDiscoveryService()]);
    await devices.initialize();
    controller = De1Controller(controller: devices);
    machine = TestDe1(deviceId: 'machine-1');
    controller.adoptDevice(machine);
    await controller.initSettled.firstWhere((generation) => generation != null);

    scales = ScaleController();
    settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    final de1Handler = De1Handler(
      controller: controller,
      settingsController: settings,
      scaleController: scales,
      workflowController: WorkflowController(),
    );
    final app = Router().plus;
    de1Handler.addRoutes(app);
    ScaleHandler(
      controller: scales,
      auxiliaryScaleRegistry: AuxiliaryScaleRegistry(),
      de1Controller: controller,
      settingsController: settings,
    ).addRoutes(app);
    handler = app.call;
  });

  tearDown(() async {
    scales.dispose();
    await controller.dispose();
  });

  test(
    'plugin implementation without typed connection identity fails closed',
    () async {
      final pluginScales = ScaleController();
      final plugin = _PluginLikeScale(deviceId: 'plugin-scale');
      await pluginScales.connectToScale(plugin);
      final pluginHandler = De1Handler(
        controller: controller,
        settingsController: settings,
        scaleController: pluginScales,
        workflowController: WorkflowController(),
      );
      final pluginApp = Router().plus;
      pluginHandler.addRoutes(pluginApp);
      final connections = await pluginApp.call(
        Request('GET', Uri.parse('http://localhost/api/v1/scale/connections')),
      );
      final json = jsonDecode(await connections.readAsString());
      expect(json['primary'], isNull);
      pluginScales.dispose();
      plugin.dispose();
    },
  );

  test(
    'rejects a captured plugin source after same-id session replacement',
    () async {
      final pluginScales = ScaleController();
      final first = _TypedPluginScale(
        deviceId: 'plugin-scale',
        currentId: 'plugin-session-1',
      );
      await pluginScales.connectToScale(first);
      await Future<void>.delayed(Duration.zero);
      final pluginHandler = De1Handler(
        controller: controller,
        settingsController: settings,
        scaleController: pluginScales,
        workflowController: WorkflowController(),
      );
      final pluginApp = Router().plus;
      pluginHandler.addRoutes(pluginApp);
      final projectionResponse = await pluginApp.call(
        Request('GET', Uri.parse('http://localhost/api/v1/scale/connections')),
      );
      final projection = jsonDecode(await projectionResponse.readAsString());
      final source = projection['primary'] as Map<String, dynamic>;
      final second = _TypedPluginScale(
        deviceId: 'plugin-scale',
        currentId: 'plugin-session-2',
      );
      await pluginScales.connectToScale(second);
      final response = await pluginApp.call(
        Request(
          'PUT',
          Uri.parse('http://localhost/api/v1/machine/state/espresso'),
          body: jsonEncode({
            'guarded': true,
            'expectedMachineId': machine.deviceId,
            'expectedMachineGeneration': controller.connectionGeneration,
            'expectedState': 'idle',
            'requireInactiveGhc': true,
            'sourceScale': {
              'role': 'primary',
              'deviceId': source['deviceId'],
              'connectionId': source['connectionId'],
              'selectionId': source['selectionId'],
            },
          }),
        ),
      );
      expect(response.statusCode, 409);
      expect(machine.requestedStates, isEmpty);
      pluginScales.dispose();
      await first.dispose();
      await second.dispose();
    },
  );

  test(
    'machine state read rejects a device replacement during snapshot await',
    () async {
      final delayed = _DelayedMachine(deviceId: 'machine-delayed');
      controller.adoptDevice(delayed);
      await controller.initSettled.firstWhere(
        (generation) => generation != null,
      );

      final pending = handler(
        Request('GET', Uri.parse('http://localhost/api/v1/machine/state')),
      );
      await Future<void>.delayed(Duration.zero);
      final replacement = TestDe1(deviceId: 'machine-replacement');
      controller.adoptDevice(replacement);
      delayed.emitDelayedSnapshot(machine.snapshotSubject.value);

      final response = await pending;
      expect(response.statusCode, 409);
      await delayed.dispose();
      await replacement.dispose();
    },
  );
}
