import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/services/webserver/ble_diagnostics_handler.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

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
}

class _InfoScale extends TestScale implements DeviceInformationCapable {
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
