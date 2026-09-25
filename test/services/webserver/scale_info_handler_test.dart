import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/auxiliary_scale_registry.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/plugins/plugin_device_contract.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_scale.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';

void main() {
  late DeviceController deviceController;
  late De1Controller de1Controller;
  late SettingsController settingsController;

  setUp(() async {
    deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = De1Controller(controller: deviceController);
    settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();
  });

  tearDown(() => deviceController.dispose());

  Future<Response> requestInfo(ScaleController controller) async {
    final app = Router().plus;
    final registry = AuxiliaryScaleRegistry();
    addTearDown(registry.dispose);
    ScaleHandler(
      controller: controller,
      de1Controller: de1Controller,
      settingsController: settingsController,
      auxiliaryScaleRegistry: registry,
    ).addRoutes(app);
    return app.call(
      Request('GET', Uri.parse('http://localhost/api/v1/scale/info')),
    );
  }

  test('returns 503 when no scale is connected', () async {
    final controller = _DisconnectedScaleController();
    addTearDown(controller.dispose);

    final response = await requestInfo(controller);

    expect(response.statusCode, 503);
    expect(jsonDecode(await response.readAsString()), {
      'error': 'No scale connected',
    });
  });

  test('returns opaque firmwareVersion and optional batteryLevel', () async {
    for (final batteryLevel in [null, 0, 100]) {
      final scale = _InfoScale(
        DeviceInformation(firmwareVersion: 'R029', batteryLevel: batteryLevel),
      );
      addTearDown(scale.dispose);
      final controller = _FixedScaleController(scale);
      addTearDown(controller.dispose);

      final response = await requestInfo(controller);
      final json =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;

      expect(response.statusCode, 200);
      expect(json['firmwareVersion'], 'R029');
      if (batteryLevel == null) {
        expect(json.containsKey('batteryLevel'), isFalse);
      } else {
        expect(json['batteryLevel'], batteryLevel);
      }
    }
  });

  test('returns empty info for a scale without metadata capability', () async {
    final scale = TestScale();
    addTearDown(scale.dispose);
    final controller = _FixedScaleController(scale);
    addTearDown(controller.dispose);

    final response = await requestInfo(controller);

    expect(response.statusCode, 200);
    expect(jsonDecode(await response.readAsString()), isEmpty);
  });

  test(
    'selects metadata from the active scale without leaking prior info',
    () async {
      final native = _InfoScale(
        const DeviceInformation(firmwareVersion: 'native-r1', batteryLevel: 91),
      );
      final metadataFree = TestScale(deviceId: 'metadata-free');
      late PluginScale plugin;
      plugin = PluginScale(
        deviceId: 'plugin-scale',
        name: 'Plugin Scale',
        capabilities: {PluginScaleCapability.battery},
        invoke: (operation, payload) async {
          if (operation == PluginDeviceOperation.connect) {
            plugin.publish({
              'weight': 1,
            }, session: payload['session'] as String);
          }
          return {};
        },
      );
      await plugin.onConnect();
      plugin.publishInfo({
        'firmwareVersion': 'plugin-r2',
        'batteryLevel': 42,
      }, session: plugin.connectionId);
      final controller = _SwitchingScaleController(native);
      addTearDown(controller.dispose);
      addTearDown(native.dispose);
      addTearDown(metadataFree.dispose);
      addTearDown(plugin.dispose);

      Future<Map<String, dynamic>> readInfo() async {
        final response = await requestInfo(controller);
        expect(response.statusCode, 200);
        return jsonDecode(await response.readAsString())
            as Map<String, dynamic>;
      }

      expect(await readInfo(), {
        'firmwareVersion': 'native-r1',
        'batteryLevel': 91,
      });
      controller.select(plugin);
      expect(await readInfo(), {
        'firmwareVersion': 'plugin-r2',
        'batteryLevel': 42,
      });
      controller.select(metadataFree);
      expect(await readInfo(), isEmpty);
    },
  );
}

class _InfoScale extends TestScale implements DeviceInformationCapable {
  _InfoScale(this._info);

  final DeviceInformation? _info;

  @override
  DeviceInformation? get currentDeviceInformation => _info;

  @override
  Stream<DeviceInformation?> get deviceInformation => Stream.value(_info);
}

class _FixedScaleController extends ScaleController {
  _FixedScaleController(this._scale);

  final Scale _scale;

  @override
  Scale connectedScale() => _scale;
}

class _SwitchingScaleController extends ScaleController {
  _SwitchingScaleController(this._scale);

  Scale _scale;

  void select(Scale scale) {
    _scale = scale;
  }

  @override
  Scale connectedScale() => _scale;
}

class _DisconnectedScaleController extends ScaleController {
  @override
  Scale connectedScale() => throw const DeviceNotConnectedException.scale();
}
