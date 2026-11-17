import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_device_scanner.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_scale.dart';

class _DisconnectScale extends TestScale {
  int disconnectCalls = 0;

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    setConnectionState(ConnectionState.disconnected);
  }
}

class _HandoffScale extends _DisconnectScale implements TransportHandoffScale {
  int handoffCalls = 0;

  @override
  Future<void> disconnectForHandoff() async {
    handoffCalls++;
    setConnectionState(ConnectionState.disconnected);
  }
}

void main() {
  late MockDeviceScanner scanner;
  late MockDe1Controller de1;
  late ScaleController scales;
  late SettingsController settings;
  late ConnectionManager manager;

  setUp(() async {
    scanner = MockDeviceScanner();
    de1 = MockDe1Controller(
      controller: DeviceController([MockDeviceDiscoveryService()]),
    );
    scales = ScaleController();
    settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    manager = ConnectionManager(
      deviceScanner: scanner,
      de1Controller: de1,
      scaleController: scales,
      settingsController: settings,
    );
  });

  tearDown(() async {
    await manager.dispose();
    await de1.de1Subject.close();
    scanner.dispose();
  });

  for (final mode in ScalePowerMode.values) {
    test('shutdown respects ${mode.name} for a handoff scale', () async {
      final scale = _HandoffScale();
      addTearDown(scale.dispose);
      await manager.connectScale(scale);
      await settings.setScalePowerMode(mode);

      await manager.shutdown();
      await manager.shutdown();

      expect(scale.handoffCalls, mode == ScalePowerMode.disabled ? 1 : 0);
      expect(scale.disconnectCalls, mode == ScalePowerMode.disabled ? 0 : 1);
      expect(await scale.connectionState.first, ConnectionState.disconnected);
      expect(scanner.startWatchCallCount, 0);
    });
  }

  test('manual disconnect still uses the normal driver operation', () async {
    final scale = _HandoffScale();
    addTearDown(scale.dispose);
    await manager.connectScale(scale);
    await settings.setScalePowerMode(ScalePowerMode.disabled);

    await manager.disconnectScale();

    expect(scale.handoffCalls, 0);
    expect(scale.disconnectCalls, 1);
  });

  test('shutdown still releases a scale without transport handoff', () async {
    final scale = _DisconnectScale();
    addTearDown(scale.dispose);
    await manager.connectScale(scale);
    await settings.setScalePowerMode(ScalePowerMode.disabled);

    await manager.shutdown();

    expect(scale.disconnectCalls, 1);
    expect(await scale.connectionState.first, ConnectionState.disconnected);
  });

  test('shutdown uses the latest power mode without restarting', () async {
    final scale = _HandoffScale();
    addTearDown(scale.dispose);
    await settings.setScalePowerMode(ScalePowerMode.disconnect);
    await manager.connectScale(scale);
    await settings.setScalePowerMode(ScalePowerMode.disabled);

    await manager.shutdown();

    expect(scale.handoffCalls, 1);
    expect(scale.disconnectCalls, 0);
  });
}
