import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/auxiliary_scale_registry.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_de1.dart';
import '../../helpers/test_scale.dart';

void main() {
  late De1Controller controller;
  late TestDe1 machine;
  late ScaleController scales;
  late SettingsController settings;
  late Handler handler;
  late String brewingConnectionId;
  late String brewingSelectionId;
  late TestScale brewingScale;

  setUp(() async {
    final devices = DeviceController([MockDeviceDiscoveryService()]);
    await devices.initialize();
    controller = De1Controller(controller: devices);
    machine = TestDe1(deviceId: 'machine-1');
    controller.adoptDevice(machine);
    await controller.initSettled.firstWhere((generation) => generation != null);

    scales = ScaleController();
    brewingScale = TestScale(deviceId: 'brew-scale');
    await scales.connectToScale(brewingScale);
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
    final connections = await handler(
      Request('GET', Uri.parse('http://localhost/api/v1/scale/connections')),
    );
    final connectionJson = jsonDecode(await connections.readAsString());
    brewingConnectionId = connectionJson['primary']['connectionId'] as String;
    brewingSelectionId = connectionJson['primary']['selectionId'] as String;
  });

  tearDown(() async {
    scales.dispose();
    brewingScale.dispose();
    await controller.dispose();
  });

  Map<String, dynamic> guard({
    required String expectedState,
    required bool requireInactiveGhc,
    String role = 'primary',
  }) => {
    'guarded': true,
    'expectedMachineId': machine.deviceId,
    'expectedMachineGeneration': controller.connectionGeneration,
    'expectedState': expectedState,
    'requireInactiveGhc': requireInactiveGhc,
    'sourceScale': {
      'role': role,
      'deviceId': 'brew-scale',
      'connectionId': brewingConnectionId,
      'selectionId': brewingSelectionId,
    },
  };

  Future<Response> request(String state, Map<String, dynamic> body) async =>
      await handler(
        Request(
          'PUT',
          Uri.parse('http://localhost/api/v1/machine/state/$state'),
          body: jsonEncode(body),
        ),
      );

  test(
    'accepts guarded brewing start and retains bodyless legacy stop',
    () async {
      final connections = await handler(
        Request('GET', Uri.parse('http://localhost/api/v1/scale/connections')),
      );
      expect(connections.statusCode, 200);
      final connectionJson = jsonDecode(await connections.readAsString());
      expect(connectionJson['primary']['deviceId'], 'brew-scale');
      expect(connectionJson.keys, contains('primary'));
      expect(connectionJson.containsKey('brewing'), isFalse);
      expect(connectionJson.containsKey('dosing'), isFalse);

      final state = await handler(
        Request('GET', Uri.parse('http://localhost/api/v1/machine/state')),
      );
      final stateJson = jsonDecode(await state.readAsString());
      expect(stateJson['deviceId'], machine.deviceId);
      expect(
        stateJson['connectionGeneration'],
        controller.connectionGeneration,
      );

      final start = await request(
        'espresso',
        guard(expectedState: 'idle', requireInactiveGhc: true),
      );
      expect(start.statusCode, 200);
      expect(machine.requestedStates, [MachineState.espresso]);

      final stop = await handler(
        Request('PUT', Uri.parse('http://localhost/api/v1/machine/state/idle')),
      );
      expect(stop.statusCode, 200);
      expect(machine.requestedStates, [
        MachineState.espresso,
        MachineState.idle,
      ]);
    },
  );

  test('rejects non-primary source and full gateway guarded start', () async {
    final obsolete = await request(
      'espresso',
      guard(expectedState: 'idle', requireInactiveGhc: true, role: 'brewing'),
    );
    expect(obsolete.statusCode, 400);
    expect(machine.requestedStates, isEmpty);

    final dosing = await request(
      'espresso',
      guard(expectedState: 'idle', requireInactiveGhc: true, role: 'dosing'),
    );
    expect(dosing.statusCode, 409);
    expect(machine.requestedStates, isEmpty);

    await settings.updateGatewayMode(GatewayMode.full);
    final full = await request(
      'espresso',
      guard(expectedState: 'idle', requireInactiveGhc: true),
    );
    expect(full.statusCode, 409);
    expect(machine.requestedStates, isEmpty);
  });

  test('ignores arbitrary non-guarded bodies for compatibility', () async {
    final response = await request('espresso', {'legacy': 'ignored'});
    expect(response.statusCode, 200);
    expect(machine.requestedStates, [MachineState.espresso]);
  });

  test('keeps explicit guarded false on the legacy path', () async {
    final response = await request('espresso', {'guarded': false});
    expect(response.statusCode, 200);
    expect(machine.requestedStates, [MachineState.espresso]);
  });

  test('keeps JSON null on the legacy path', () async {
    final response = await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/machine/state/espresso'),
        body: 'null',
      ),
    );
    expect(response.statusCode, 200);
    expect(machine.requestedStates, [MachineState.espresso]);
  });

  test(
    'rejects malformed nonempty JSON without a legacy machine write',
    () async {
      final response = await handler(
        Request(
          'PUT',
          Uri.parse('http://localhost/api/v1/machine/state/espresso'),
          body: '{not-json',
        ),
      );
      expect(response.statusCode, 400);
      expect(machine.requestedStates, isEmpty);
    },
  );

  test(
    'rejects a non-boolean guarded flag without a legacy machine write',
    () async {
      final response = await request('espresso', {'guarded': 'true'});
      expect(response.statusCode, 400);
      expect(machine.requestedStates, isEmpty);
    },
  );

  test('rejects a captured native source after same-id reconnect', () async {
    final stale = guard(expectedState: 'idle', requireInactiveGhc: true);
    final reconnected = TestScale(deviceId: 'brew-scale');
    await scales.connectToScale(reconnected);

    final response = await request('espresso', stale);
    expect(response.statusCode, 409);
    expect(machine.requestedStates, isEmpty);
    reconnected.dispose();
  });
}
