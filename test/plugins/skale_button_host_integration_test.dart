import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_plus/shelf_plus.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_de1.dart';
import '../helpers/skale_plugin_fixture.dart';
import 'plugin_test_helpers.dart';

final _settings = SkaleSettingsFixture();

void main() {
  setUpAll(_settings.start);

  setUp(() {
    _settings.values.clear();
    _settings.defaultUsbPower = false;
    _settings.defaultSquareAction = true;
    _settings.error = false;
    _settings.delay = Duration.zero;
    _settings.machineDelay = Duration.zero;
    _settings.scaleConnections = {'primary': null};
    _settings.machineState = {
      'deviceId': 'machine-1',
      'connectionGeneration': 1,
      'state': {'state': 'idle', 'substate': 'idle'},
    };
    _settings.machineInfo = {
      'version': '1.0',
      'model': 'MockDe1',
      'serialNumber': 'mock',
      'GHC': false,
    };
    _settings.machineRequests.clear();
  });

  tearDownAll(_settings.close);

  test(
    'routes buttons through the actual host roles and guarded handler',
    () async {
      final devices = DeviceController([MockDeviceDiscoveryService()]);
      await devices.initialize();
      final de1 = De1Controller(controller: devices);
      final machine = TestDe1(deviceId: 'machine-1');
      de1.adoptDevice(machine);
      await de1.initSettled.firstWhere((generation) => generation != null);

      final brewingController = ScaleController();
      final settingsController = SettingsController(MockSettingsService());
      await settingsController.loadSettings();
      final app = Router().plus;
      De1Handler(
        controller: de1,
        settingsController: settingsController,
        scaleController: brewingController,
        workflowController: WorkflowController(),
      ).addRoutes(app);
      ScaleHandler(
        controller: brewingController,
        de1Controller: de1,
        settingsController: settingsController,
      ).addRoutes(app);
      final roleReadWaiters = <Completer<void>>[];
      final guardedBodies = <Map<String, dynamic>>[];
      _settings.apiHandler = (request) async {
        final body = await request.readAsString();
        if (request.url.path.endsWith('/machine/state/espresso')) {
          guardedBodies.add(jsonDecode(body) as Map<String, dynamic>);
        }
        final response = await app.call(
          shelf.Request(
            request.method,
            request.requestedUri,
            headers: request.headers,
            body: body,
          ),
        );
        if (request.url.path.endsWith('/scale/connections') &&
            roleReadWaiters.isNotEmpty) {
          roleReadWaiters.removeAt(0).complete();
        }
        return response;
      };

      Future<void> waitForRoleRead() {
        final waiter = Completer<void>();
        roleReadWaiters.add(waiter);
        return waiter.future.timeout(const Duration(seconds: 5));
      }

      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      await loadSkalePlugin(manager);
      final evidence = BleAdvertisementEvidence(serviceUuids: ['ff08']);
      final driver = manager.bleService.registry
          .decide(evidence)
          .drivers
          .single;
      final brewingTransport = SkalePluginTransport(
        'AA:20',
        batteryPresent: false,
      );
      final brewing = await _candidate(
        manager,
        driver,
        evidence,
        'AA:20',
        brewingTransport,
      );
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = SkaleSettingsHttpOverrides(_settings);
      try {
        final brewingConnect = brewing.onConnect().timeout(
          const Duration(seconds: 5),
        );
        await brewingTransport.buttonSubscribed.future.timeout(
          const Duration(seconds: 5),
        );
        await brewingTransport.finalEnable.future.timeout(
          const Duration(seconds: 5),
        );
        brewingTransport.emitWeight(skaleFourBytePacket(1));
        await brewingConnect;
        await brewingController.adoptScale(brewing);

        final brewingCircleRead = waitForRoleRead();
        brewingTransport.emitButton(1);
        await brewingCircleRead;
        await _waitFor(() => brewingTransport.writes.any(_isTareWrite));
        expect(brewingTransport.writes.where(_isTareWrite), hasLength(1));

        final brewingSquareRead = waitForRoleRead();
        brewingTransport.emitButton(2);
        await brewingSquareRead;
        await _waitFor(() => machine.requestedStates.isNotEmpty);
        expect(machine.requestedStates, [MachineState.espresso]);
        expect(guardedBodies, hasLength(1));
        expect(guardedBodies.single['guarded'], isTrue);
        expect(
          guardedBodies.single['sourceScale'] as Map,
          containsPair('role', 'primary'),
        );
      } finally {
        HttpOverrides.global = previousOverrides;
        _settings.apiHandler = null;
        brewingController.dispose();
        await manager.dispose();
        await de1.dispose();
      }
    },
  );
}

Future<Scale> _candidate(
  PluginManager manager,
  dynamic driver,
  BleAdvertisementEvidence evidence,
  String physicalId,
  SkalePluginTransport transport,
) async =>
    await manager.bleService.createCandidate(
          driver: driver,
          physicalId: physicalId,
          evidence: evidence,
          admit: () => true,
          createTransport: () => transport,
        )
        as Scale;

bool _isTareWrite(dynamic write) =>
    write.data.length == 1 && write.data[0] == 0x10;

Future<void> _waitFor(bool Function() predicate) async {
  for (var i = 0; i < 100 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(predicate(), isTrue);
}
