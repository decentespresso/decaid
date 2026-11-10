import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/remembered_devices_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_identity.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/mock_de1_controller.dart';
import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_device_scanner.dart';
import '../../helpers/mock_scale_controller.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_de1.dart';

class _Machine extends TestDe1 implements CanonicalDeviceIdentity {
  _Machine() : super(deviceId: 'usb-2e8a-a-unknown-7');

  @override
  String? canonicalDeviceId;

  @override
  TransportType get transportType => TransportType.serial;
}

class _WebUI extends Fake implements WebUIService {
  @override
  String serverPath() => '/';
}

class _Storage extends Fake implements WebUIStorage {}

void main() {
  test('USB session identity HTTP smoke uses only mocked services', () async {
    final store = MockSettingsService();
    await store.setRememberedDevices(
      RememberedDevice.encodeList(const [
        RememberedDevice(
          id: 'usb-2e8a-a-KNOWN',
          name: 'DE1',
          type: DeviceType.machine,
        ),
        RememberedDevice(
          id: 'AA:BB:CC:DD:EE:FF',
          name: 'DE1',
          type: DeviceType.machine,
        ),
      ]),
    );
    final settings = SettingsController(store);
    await settings.loadSettings();
    await settings.setPreferredMachineId('usb-2e8a-a-KNOWN');
    final remembered = RememberedDevicesController(
      machineConnections: const Stream.empty(),
      scaleConnections: const Stream.empty(),
      settings: store,
    );
    await remembered.initialize();
    final discovery = MockDeviceDiscoveryService();
    final devices = DeviceController([discovery]);
    await devices.initialize();
    final machine = _Machine();
    discovery.addDevice(machine);
    await Future<void>.delayed(Duration.zero);
    final de1 = MockDe1Controller(controller: devices);
    final scales = MockScaleController();
    final manager = ConnectionManager(
      deviceScanner: MockDeviceScanner(),
      de1Controller: de1,
      scaleController: scales,
      settingsController: settings,
    );
    final devicesHandler = DevicesHandler(
      controller: devices,
      connectionManager: manager,
      rememberedController: remembered,
    );
    final router = Router().plus;
    devicesHandler.addRoutes(router);
    SettingsHandler(
      controller: settings,
      service: _WebUI(),
      webUIStorage: _Storage(),
    ).addRoutes(router);
    final server = await shelf_io.serve(
      router.call,
      InternetAddress.loopbackIPv4,
      0,
    );
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.close(force: true);
      devicesHandler.dispose();
      await manager.dispose();
      await remembered.dispose();
      await de1.dispose();
      devices.dispose();
      await machine.dispose();
      settings.dispose();
    });
    Future<dynamic> request(
      String method,
      String path, [
      Map<String, dynamic>? body,
    ]) async {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      debugPrint(
        '$method $path${body == null ? '' : ' ${jsonEncode(body)}'} -> ${response.statusCode} $text',
      );
      expect(response.statusCode, 200);
      return text.isEmpty ? null : jsonDecode(text);
    }

    expect(await request('GET', '/api/v1/devices'), hasLength(3));
    machine.canonicalDeviceId = 'usb-2e8a-a-KNOWN';
    final inventory = await request('GET', '/api/v1/devices') as List;
    expect(inventory, hasLength(2));
    expect(inventory.map((entry) => entry['id']).toSet(), {
      'usb-2e8a-a-unknown-7',
      'AA:BB:CC:DD:EE:FF',
    });
    await request('POST', '/api/v1/settings', {
      'preferredMachineId': machine.deviceId,
    });
    expect(
      (await request('GET', '/api/v1/settings'))['preferredMachineId'],
      'usb-2e8a-a-KNOWN',
    );
    expect(await store.preferredMachineId(), 'usb-2e8a-a-KNOWN');
  });
}
