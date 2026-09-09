import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/services/universal_ble_discovery_service.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:web_socket_channel/io.dart';

import '../helpers/bookoo_packets.dart';
import '../helpers/bookoo_plugin_fixture.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/plugin_ble_fixture.dart';
import 'plugin_test_helpers.dart';

class _Fixture {
  final manager = PluginManager(kvStore: FakeKeyValueStoreService());
  final platform = PluginBleFixturePlatform();
  final transports = <BookooPluginTransport>[];
  final scales = ScaleController();
  late final UniversalBleDiscoveryService discovery;
  late final DeviceController devices;
  late final De1Controller de1;
  late final SettingsController settings;
  late final ConnectionManager connections;

  Future<void> initialize(
    MockSettingsService store, {
    bool plugin = true,
    bool compatible = true,
  }) async {
    UniversalBle.setInstance(platform);
    discovery = UniversalBleDiscoveryService(
      pluginBleService: () => manager.bleService,
      scanDuration: const Duration(milliseconds: 40),
      transportFactory:
          ({
            required device,
            required stopScan,
            required requestLargeMtuNonAndroid,
            required lifecycleGate,
          }) {
            final transport = BookooPluginTransport(
              device.deviceId,
              firstPacket: bookooPacket(1),
              servicePresent: compatible,
            );
            transports.add(transport);
            return transport;
          },
    );
    devices = DeviceController([discovery]);
    await devices.initialize();
    settings = SettingsController(store);
    await settings.loadSettings();
    de1 = De1Controller(controller: devices);
    connections = ConnectionManager(
      deviceScanner: devices,
      de1Controller: de1,
      scaleController: scales,
      settingsController: settings,
    );
    if (plugin) await loadBookooPlugin(manager);
    platform.firstAdvertisement = BleDevice(
      deviceId: 'AA:BB',
      name: 'Bookoo Mini',
      services: ['0ffe'],
    );
  }

  Future<void> dispose() async {
    await connections.dispose();
    scales.dispose();
    await discovery.dispose();
    await manager.dispose();
    await de1.dispose();
    devices.dispose();
  }
}

void main() {
  test(
    'Bookoo handshake failure never selects native in the same attempt',
    () async {
      final fixture = _Fixture();
      await fixture.initialize(MockSettingsService(), compatible: false);
      addTearDown(fixture.dispose);
      await fixture.connections.connect(scaleOnly: true);
      expect(
        fixture.scales.currentConnectionState,
        isNot(ConnectionState.connected),
      );
      expect(fixture.transports, hasLength(1));
      await fixture.transports.single.disposed.future.timeout(
        const Duration(seconds: 2),
      );
      expect(fixture.transports.single.disposeCalls, 1);
      expect(
        fixture.devices.devices.whereType<Scale>().every(
          (s) => s.implementation == DeviceImplementation.plugin,
        ),
        isTrue,
      );
      expect(fixture.settings.preferredScaleId, isNull);
    },
  );

  test(
    'persisted Bookoo plugin preference survives reconstruction and never repoints to native',
    () async {
      final store = MockSettingsService();
      RememberedDevice? remembered;
      String? preferred;
      for (final enabled in [true, true, false]) {
        final fixture = _Fixture();
        await fixture.initialize(store, plugin: enabled);
        try {
          if (remembered != null) {
            expect(fixture.settings.preferredScaleId, preferred);
            expect(await fixture.devices.tryQuickConnect(remembered), isNull);
            expect(fixture.transports, isEmpty);
          }
          await fixture.connections
              .connect(scaleOnly: true)
              .timeout(const Duration(seconds: 3));
          if (enabled) {
            final scale = fixture.scales.connectedScale();
            expect(scale.implementation, DeviceImplementation.plugin);
            preferred ??= scale.deviceId;
            expect(scale.deviceId, preferred);
            expect(fixture.settings.preferredScaleId, preferred);
            remembered = RememberedDevice.fromDevice(scale)!;
            expect(fixture.transports.single.connectCalls, 1);
          } else {
            expect(
              fixture.devices.devices.whereType<Scale>().single.implementation,
              DeviceImplementation.bookooScale,
            );
            expect(fixture.settings.preferredScaleId, preferred);
            expect(
              fixture.scales.currentConnectionState,
              isNot(ConnectionState.connected),
            );
            expect(
              fixture.transports.every((t) => t.connectCalls == 0),
              isTrue,
            );
            expect(
              fixture.connections.currentStatus.pendingAmbiguity,
              isNotNull,
            );
          }
        } finally {
          await fixture.dispose();
        }
      }
    },
  );

  test(
    'Bookoo discovery reaches existing Scale HTTP commands and WS snapshots',
    () async {
      final fixture = _Fixture();
      await fixture.initialize(MockSettingsService());
      addTearDown(fixture.dispose);
      await fixture.connections.connect(scaleOnly: true);
      final router = Router().plus;
      ScaleHandler(
        controller: fixture.scales,
        de1Controller: fixture.de1,
        settingsController: fixture.settings,
      ).addRoutes(router);
      final server = await shelf_io.serve(router.call, '127.0.0.1', 0);
      final client = HttpClient();
      final channel = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${server.port}/ws/v1/scale/snapshot'),
      );
      final frames = StreamIterator(channel.stream);
      addTearDown(() async {
        await frames.cancel();
        await channel.sink.close();
        client.close(force: true);
        await server.close(force: true);
      });
      await channel.ready;
      expect(await frames.moveNext(), isTrue);
      expect(jsonDecode(frames.current as String)['status'], 'connected');
      fixture.transports.single.emit(bookooPacket(-4.5, battery: 80));
      expect(await frames.moveNext(), isTrue);
      final sample = jsonDecode(frames.current as String);
      expect(sample['weight'], -4.5);
      expect(sample['battery'], 80);
      for (final path in ['tare', 'timer/start', 'timer/stop', 'timer/reset']) {
        final response = await (await client.putUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/v1/scale/$path'),
        )).close();
        expect(response.statusCode, 200);
        await response.drain<void>();
      }
      expect(
        fixture.transports.single.writes.map((w) => w.data.toList()),
        bookooCommands,
      );
    },
  );
}
