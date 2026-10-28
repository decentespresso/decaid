import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/machine_settings_store.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/fake_ble_transport.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';
import '../../helpers/test_scale_controller.dart';

class _MemoryMachineSettingsStore implements MachineSettingsStore {
  final Map<String, MachineSettings> values = {};

  @override
  Future<MachineSettings?> read(String identity) async => values[identity];

  @override
  Future<void> update(
    String identity, {
    int? fanThreshold,
    De1RefillKitSettings? refillKitSetting,
    double? flowCalibration,
  }) async {
    if (identity.isEmpty) return;
    final current = values[identity];
    values[identity] = MachineSettings(
      fanThreshold: fanThreshold ?? current?.fanThreshold,
      refillKitSetting: refillKitSetting ?? current?.refillKitSetting,
      flowCalibration: flowCalibration ?? current?.flowCalibration,
    );
  }

  @override
  Future<void> clear(String identity) async => values.remove(identity);
}

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
  _MemoryMachineSettingsStore settings, {
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

List<int> _flowWrites(FakeBleTransport transport) {
  final address = MMRItem.calFlowEst.address;
  return transport.writes
      .where(
        (write) =>
            write.characteristicUUID == Endpoint.writeToMMR.uuid &&
            write.data.length >= 8 &&
            write.data[1] == ((address >> 16) & 0xff) &&
            write.data[2] == ((address >> 8) & 0xff) &&
            write.data[3] == (address & 0xff),
      )
      .map(
        (write) => ByteData.sublistView(write.data).getUint32(4, Endian.little),
      )
      .toList();
}

Future<Response> _post(Handler handler, Object body) async => await handler(
  Request(
    'POST',
    Uri.parse('http://localhost/api/v1/machine/calibration'),
    body: jsonEncode(body),
    headers: {'content-type': 'application/json'},
  ),
);

void main() {
  test('successful calibration write persists requested intent', () async {
    final settings = _MemoryMachineSettingsStore();
    final harness = await _connect(settings);
    addTearDown(harness.controller.dispose);
    final handler = await _handler(harness.controller);

    expect((await _post(handler, {'flowMultiplier': 3.0})).statusCode, 202);
    expect(settings.values['serial:12345']?.flowCalibration, 3.0);
    expect(_flowWrites(harness.transport), [2000]);
  });

  test('failed calibration write does not persist an override', () async {
    final settings = _MemoryMachineSettingsStore();
    final transport = FakeBleTransport()
      ..failMmrWritesForAddresses.add(MMRItem.calFlowEst.address);
    final harness = await _connect(settings, transport: transport);
    addTearDown(harness.controller.dispose);
    final handler = await _handler(harness.controller);

    expect((await _post(handler, {'flowMultiplier': 1.25})).statusCode, 500);
    expect(settings.values, isEmpty);
  });
}
