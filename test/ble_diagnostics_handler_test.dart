import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/services/webserver/ble_diagnostics_handler.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:yaml/yaml.dart';

import 'helpers/mock_device_discovery_service.dart';
import 'helpers/mock_settings_service.dart';
import 'helpers/test_scale.dart';

void main() {
  test('BLE diagnostics is read-only and includes correlated state', () async {
    final ble = MockBleDiscoveryService()
      ..diagnosticDetails = {
        'scan': {
          'owner': 'watch',
          'phase': 'active',
          'generation': 4,
          'nativeIsScanning': false,
        },
        'cache': [
          {'deviceId': 'scale-1', 'instanceId': 42},
        ],
      };
    final devices = DeviceController([ble]);
    await devices.initialize();
    final scale = _InfoScale(
      deviceId: 'scale-1',
      name: 'Original Decent Scale',
      information: const DeviceInformation(
        firmwareVersion: '1.1',
        batteryLevel: 88,
      ),
    );
    ble.addDevice(scale);
    await Future<void>.delayed(Duration.zero);

    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    final manager = ConnectionManager(
      deviceScanner: devices,
      de1Controller: De1Controller(controller: devices),
      scaleController: ScaleController(),
      settingsController: settings,
    );
    final router = Router().plus;
    BleDiagnosticsHandler(
      deviceController: devices,
      connectionManager: manager,
      settingsController: settings,
    ).addRoutes(router);

    final response = await router.call(
      Request('GET', Uri.parse('http://localhost/api/v1/diagnostics/ble')),
    );
    final body = jsonDecode(await response.readAsString());

    expect(response.statusCode, 200);
    expect(body['diagnosticsVersion'], 2);
    expect(body['timestamp'], isA<String>());
    expect(body['monotonicMs'], isA<int>());
    expect(body['sampling']['startedAt'], isA<String>());
    expect(body['sampling']['completedAt'], body['timestamp']);
    expect(
      body['sampling']['completedMonotonicMs'],
      greaterThanOrEqualTo(body['sampling']['startedMonotonicMs']),
    );
    expect(body['ble']['servicesDiagnostics']['complete'], isTrue);
    expect(body['ble']['servicesDiagnostics']['sampledAt'], isA<String>());
    expect(
      body['ble']['services'][0]['details']['scan']['nativeIsScanning'],
      false,
    );
    expect(body['ble']['services'][0]['details']['cache'][0]['instanceId'], 42);
    final peer = body['connection']['peers'].single;
    expect(peer['deviceId'], 'scale-1');
    expect(peer['name'], 'Original Decent Scale');
    expect(peer['type'], 'scale');
    expect(peer['transport'], 'unknown');
    expect(peer['instanceId'], isA<int>());
    expect(peer['state'], 'connected');
    expect(peer['information'], {'firmwareVersion': '1.1', 'batteryLevel': 88});
    expect(peer['diagnostics'], {
      'validSample': {'at': null, 'ageMs': null},
    });
    expect(body['connection']['preferredMachineId'], isNull);
    expect(body['connection']['preferredScaleId'], isNull);
    expect(body['connection']['conditions'], isEmpty);
    expect(
      (await devices.bleDiagnostics()).single['details'],
      ble.diagnosticDetails,
    );

    manager.dispose();
    devices.dispose();
    ble.dispose();
    scale.dispose();
  });

  test('BLE diagnostics cancels a silent connection-state probe', () async {
    final ble = MockBleDiscoveryService();
    final devices = DeviceController([ble]);
    await devices.initialize();
    final scale = _SilentScale(deviceId: 'silent-scale', name: 'Silent Scale');
    ble.addDevice(scale);
    await Future<void>.delayed(Duration.zero);

    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    final manager = ConnectionManager(
      deviceScanner: devices,
      de1Controller: De1Controller(controller: devices),
      scaleController: ScaleController(),
      settingsController: settings,
    );
    final router = Router().plus;
    BleDiagnosticsHandler(
      deviceController: devices,
      connectionManager: manager,
      settingsController: settings,
      deviceStateProbeTimeout: const Duration(milliseconds: 10),
    ).addRoutes(router);

    final response = await router.call(
      Request('GET', Uri.parse('http://localhost/api/v1/diagnostics/ble')),
    );
    final body = jsonDecode(await response.readAsString());
    final peer = body['connection']['peers'].single;

    expect(response.statusCode, 200);
    expect(peer['deviceId'], 'silent-scale');
    expect(peer['state'], isNull);
    expect(scale.listenCount, 1);
    expect(scale.cancelCount, 1);

    manager.dispose();
    devices.dispose();
    ble.dispose();
    scale.dispose();
  });

  test(
    'BLE diagnostics bounds and coalesces slow service diagnostics',
    () async {
      final ble = _BlockingBleDiscoveryService();
      final devices = DeviceController([ble]);
      await devices.initialize();
      final settings = SettingsController(MockSettingsService());
      await settings.loadSettings();
      final manager = ConnectionManager(
        deviceScanner: devices,
        de1Controller: De1Controller(controller: devices),
        scaleController: ScaleController(),
        settingsController: settings,
      );
      final router = Router().plus;
      BleDiagnosticsHandler(
        deviceController: devices,
        connectionManager: manager,
        settingsController: settings,
        serviceDiagnosticsWaitTimeout: const Duration(milliseconds: 10),
      ).addRoutes(router);

      Request request() =>
          Request('GET', Uri.parse('http://localhost/api/v1/diagnostics/ble'));
      Future<Response> call() async => router.call(request());

      final responses = await Future.wait<Response>([call(), call()]);
      expect(ble.diagnosticsCallCount, 1);

      for (final response in responses) {
        final body = jsonDecode(await response.readAsString());
        expect(response.statusCode, 200);
        expect(body['ble']['services'], isEmpty);
        expect(body['ble']['servicesDiagnostics']['complete'], isFalse);
        expect(body['ble']['servicesDiagnostics']['sampledAt'], isNull);
      }

      ble.completeDiagnostics({
        'scan': {'nativeIsScanning': false},
      });
      await Future<void>.delayed(Duration.zero);

      final response = await router.call(request());
      final body = jsonDecode(await response.readAsString());
      expect(response.statusCode, 200);
      expect(ble.diagnosticsCallCount, 2);
      expect(body['ble']['servicesDiagnostics']['complete'], isTrue);
      expect(body['ble']['servicesDiagnostics']['sampledAt'], isA<String>());
      expect(
        body['ble']['services'].single['details']['scan']['nativeIsScanning'],
        false,
      );

      manager.dispose();
      devices.dispose();
      ble.dispose();
    },
  );

  test('OpenAPI documents BLE diagnostic correlation fields', () async {
    final spec =
        loadYaml(await File('assets/api/rest_v1.yml').readAsString())
            as YamlMap;
    final schemas = (spec['components'] as YamlMap)['schemas'] as YamlMap;
    final schema = schemas['BleDiagnosticsSnapshot'] as YamlMap;
    final required = schema['required'] as YamlList;
    final properties = schema['properties'] as YamlMap;

    expect(required, containsAll(['diagnosticsVersion', 'monotonicMs']));
    expect((properties['diagnosticsVersion'] as YamlMap)['enum'], contains(2));
    expect((properties['monotonicMs'] as YamlMap)['type'], 'integer');
  });
}

class _InfoScale extends TestScale
    implements DeviceInformationCapable, DeviceDiagnosticsCapable {
  @override
  Map<String, Object?> get connectionDiagnostics => {
    'validSample': {'at': null, 'ageMs': null},
  };
  _InfoScale({
    required super.deviceId,
    required super.name,
    required this.information,
  });

  final DeviceInformation? information;

  @override
  DeviceInformation? get currentDeviceInformation => information;

  @override
  Stream<DeviceInformation?> get deviceInformation => Stream.value(information);
}

class _SilentScale extends TestScale {
  _SilentScale({required super.deviceId, required super.name}) {
    _silentState = StreamController<ConnectionState>(
      onListen: () => listenCount++,
      onCancel: () => cancelCount++,
    );
  }

  late final StreamController<ConnectionState> _silentState;
  int listenCount = 0;
  int cancelCount = 0;

  @override
  Stream<ConnectionState> get connectionState => _silentState.stream;

  @override
  void dispose() {
    _silentState.close();
    super.dispose();
  }
}

class _BlockingBleDiscoveryService extends MockBleDiscoveryService {
  final Completer<Map<String, Object?>> _diagnostics = Completer();
  int diagnosticsCallCount = 0;

  @override
  Future<Map<String, Object?>> diagnostics() {
    diagnosticsCallCount++;
    return _diagnostics.future;
  }

  void completeDiagnostics(Map<String, Object?> value) {
    if (!_diagnostics.isCompleted) _diagnostics.complete(value);
  }
}
