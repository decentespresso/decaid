import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:web_socket_channel/io.dart';

import '../../helpers/mock_de1_controller.dart';
import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_device_scanner.dart';
import '../../helpers/mock_scale_controller.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';

class _ConnectedMachine implements De1Interface {
  @override
  String get deviceId => 'connected-machine';
  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);
  @override
  Stream<MachineSnapshot> get currentSnapshot => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late MockDeviceScanner scanner;
  late MockScaleController scales;
  late DeviceController devices;
  late ConnectionManager manager;
  late DevicesHandler handler;
  late HttpServer server;

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('Condition did not settle');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  setUp(() async {
    scanner = MockDeviceScanner();
    scales = MockScaleController();
    devices = DeviceController([MockDeviceDiscoveryService()]);
    await devices.initialize();
    final machines = MockDe1Controller(controller: devices);
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    await settings.setPreferredScaleId('preferred-scale');
    manager = ConnectionManager(
      deviceScanner: scanner,
      de1Controller: machines,
      scaleController: scales,
      settingsController: settings,
    );
    machines.de1Subject.add(_ConnectedMachine());
    await Future<void>.delayed(Duration.zero);
    scanner.scanCompleter = Completer<void>();
    handler = DevicesHandler(controller: devices, connectionManager: manager);
    final router = Router().plus;
    handler.addRoutes(router);
    server = await shelf_io.serve(router.call, InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    if (scanner.scanCompleter?.isCompleted == false) scanner.completeScan();
    await server.close(force: true);
    handler.dispose();
    await manager.dispose();
    scanner.dispose();
    devices.dispose();
  });

  for (final option in [null, false, true]) {
    for (final quick in [false, true]) {
      test('REST option=$option quick=$quick selects only the opted-in shortcut', () async {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final query =
            '?connect=true&quick=$quick${option == null ? '' : '&connectPreferredScaleEarly=$option'}';
        final request = await client.getUrl(
          Uri.parse(
            'http://127.0.0.1:${server.port}/api/v1/devices/scan$query',
          ),
        );
        final response = request.close();
        await waitFor(() => scanner.scanCallCount == 1);
        final scale = TestScale(deviceId: 'preferred-scale');
        scanner.addDevice(scale);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(scanner.stopScanCallCount, option == true ? 1 : 0);
        expect(scales.connectCalls, isEmpty);
        scanner.completeScan();
        expect((await response).statusCode, 200);
        await waitFor(() => scales.connectCalls.isNotEmpty);
        expect(scales.connectCalls, [same(scale)]);
      });
    }

    test(
      'WebSocket option=$option selects only the opted-in shortcut',
      () async {
        final socket = IOWebSocketChannel.connect(
          'ws://127.0.0.1:${server.port}/ws/v1/devices',
        );
        await socket.ready;
        final subscription = socket.stream.listen((_) {});
        addTearDown(() async {
          await subscription.cancel();
          await socket.sink.close();
        });
        socket.sink.add(
          jsonEncode({
            'command': 'scan',
            'connect': true,
            'connectPreferredScaleEarly': ?option,
          }),
        );
        await waitFor(() => scanner.scanCallCount == 1);
        final scale = TestScale(deviceId: 'preferred-scale');
        scanner.addDevice(scale);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(scanner.stopScanCallCount, option == true ? 1 : 0);
        expect(scales.connectCalls, isEmpty);
        scanner.completeScan();
        await waitFor(() => scales.connectCalls.isNotEmpty);
        expect(scales.connectCalls, [same(scale)]);
      },
    );
  }

  test('REST discovery-only ignores the shortcut', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse(
        'http://127.0.0.1:${server.port}/api/v1/devices/scan?connect=false&connectPreferredScaleEarly=true',
      ),
    );
    expect((await request.close()).statusCode, 200);
    expect(scanner.scanCallCount, 0);
    expect(scanner.stopScanCallCount, 0);
    expect(scales.connectCalls, isEmpty);
  });
}
