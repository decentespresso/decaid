import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/services/webserver/ble_diagnostics_handler.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

import 'helpers/mock_device_discovery_service.dart';
import 'helpers/mock_settings_service.dart';

void main() {
  test('BLE diagnostics is read-only and includes service details', () async {
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
    expect(
      body['ble']['services'][0]['details']['scan']['nativeIsScanning'],
      false,
    );
    expect(body['ble']['services'][0]['details']['cache'][0]['instanceId'], 42);
    expect(body['connection']['preferredScaleId'], isNull);
    expect(
      (await devices.bleDiagnostics()).single['details'],
      ble.diagnosticDetails,
    );

    manager.dispose();
    devices.dispose();
    ble.dispose();
  });
}
