import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/fake_ble_transport.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_scale_controller.dart';
import '../../helpers/memory_machine_settings_store.dart';

const _shotSettings = <int>[
  0,
  150,
  30,
  75,
  50,
  30,
  36,
  94,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
];

Future<({De1Controller controller, FakeBleTransport transport})> _connect(
  MemoryMachineSettingsStore settings, {
  FakeBleTransport? transport,
}) async {
  final ble = transport ?? FakeBleTransport();
  ble
    ..queueOnConnectResponses()
    ..queueRead(
      Endpoint.stateInfo.uuid,
      Uint8List.fromList([2, ...List.filled(19, 0)]),
    )
    ..queueRead(Endpoint.shotSettings.uuid, Uint8List.fromList(_shotSettings));
  final de1 = UnifiedDe1(transport: ble);
  final devices = DeviceController(const <DeviceDiscoveryService>[]);
  await devices.initialize();
  final controller = De1Controller(
    controller: devices,
    machineSettings: settings,
  );
  await controller.connectToDe1(de1);
  await controller.initSettled.firstWhere((generation) => generation != null);
  return (controller: controller, transport: ble);
}

Future<Handler> _handler(De1Controller controller) async {
  final settingsController = SettingsController(MockSettingsService());
  await settingsController.loadSettings();
  final router = Router().plus;
  De1Handler(
    controller: controller,
    settingsController: settingsController,
    scaleController: TestScaleController(TestScale()),
    workflowController: WorkflowController(),
  ).addRoutes(router);
  return router.call;
}

class _FailingWaterLevelsTransport extends FakeBleTransport {
  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (characteristicUUID == Endpoint.waterLevels.uuid) {
      throw StateError('simulated water levels write failure');
    }
    return super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
  }
}

Future<Response> _post(Handler handler, Object body) async => await handler(
  Request(
    'POST',
    Uri.parse('http://localhost/api/v1/machine/waterLevels'),
    body: jsonEncode(body),
    headers: {'content-type': 'application/json'},
  ),
);

Future<Response> _reset(Handler handler) async => await handler(
  Request(
    'DELETE',
    Uri.parse('http://localhost/api/v1/machine/settings/reset'),
  ),
);

void main() {
  test('successful refill level write persists requested intent', () async {
    final settings = MemoryMachineSettingsStore();
    final harness = await _connect(settings);
    addTearDown(harness.controller.dispose);
    final handler = await _handler(harness.controller);

    expect((await _post(handler, {'refillLevel': 12})).statusCode, 202);
    expect(settings.values['serial:12345']?.refillLevel, 12);
  });

  test('failed refill level write does not persist an override', () async {
    final settings = MemoryMachineSettingsStore();
    final harness = await _connect(
      settings,
      transport: _FailingWaterLevelsTransport(),
    );
    addTearDown(harness.controller.dispose);
    final handler = await _handler(harness.controller);

    expect((await _post(handler, {'refillLevel': 12})).statusCode, 500);
    expect(settings.values, isEmpty);
  });

  test('settings reset keeps the saved refill level', () async {
    final settings = MemoryMachineSettingsStore();
    await settings.update(
      'serial:12345',
      fanThreshold: 42,
      refillKitSetting: De1RefillKitSettings.forceOn,
      refillLevel: 12,
    );
    final harness = await _connect(settings);
    addTearDown(harness.controller.dispose);
    final handler = await _handler(harness.controller);

    expect((await _reset(handler)).statusCode, lessThan(300));
    final kept = settings.values['serial:12345'];
    expect(kept?.refillLevel, 12);
    expect(kept?.fanThreshold, isNull);
  });
}
