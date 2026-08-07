import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:web_socket_channel/io.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';

import 'helpers/mock_device_discovery_service.dart';
import 'helpers/mock_settings_service.dart';
import 'helpers/test_scale.dart';
import 'helpers/test_sensor.dart';

void main() {
  late DeviceController deviceController;
  late De1Controller de1Controller;
  late ScaleController scaleController;
  late ConnectionManager connectionManager;
  late MockDeviceDiscoveryService mockDiscovery;
  late DevicesHandler devicesHandler;
  late HttpServer server;
  late Uri wsUri;

  setUp(() async {
    mockDiscovery = MockDeviceDiscoveryService();
    deviceController = DeviceController([mockDiscovery]);
    await deviceController.initialize();

    de1Controller = De1Controller(controller: deviceController);
    scaleController = ScaleController();

    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();

    connectionManager = ConnectionManager(
      deviceScanner: deviceController,
      de1Controller: de1Controller,
      scaleController: scaleController,
      settingsController: settingsController,
    );

    devicesHandler = DevicesHandler(
      controller: deviceController,
      connectionManager: connectionManager,
    );

    final app = Router().plus;
    devicesHandler.addRoutes(app);

    server = await io.serve(app.call, 'localhost', 0);
    wsUri = Uri.parse('ws://localhost:${server.port}/ws/v1/devices');
  });

  tearDown(() async {
    await server.close(force: true);
    devicesHandler.dispose();
    connectionManager.dispose();
    deviceController.dispose();
  });

  (IOWebSocketChannel, Stream<Map<String, dynamic>>) connectWs() {
    final channel = IOWebSocketChannel.connect(wsUri);
    final messages = channel.stream
        .map((msg) => jsonDecode(msg.toString()) as Map<String, dynamic>)
        .asBroadcastStream();
    return (channel, messages);
  }

  Future<Map<String, dynamic>> waitForError(
    Stream<Map<String, dynamic>> messages,
  ) {
    return messages
        .where((msg) => msg.containsKey('error'))
        .first
        .timeout(Duration(seconds: 2));
  }

  Future<Map<String, dynamic>> waitForState(
    Stream<Map<String, dynamic>> messages,
  ) {
    return messages
        .where((msg) => msg.containsKey('devices'))
        .first
        .timeout(Duration(seconds: 2));
  }

  group('Devices WebSocket', () {
    test('sends initial state on connect', () async {
      final (channel, messages) = connectWs();

      final first = await waitForState(messages);

      expect(first, containsPair('scanning', false));
      expect(first['timestamp'], isA<String>());
      expect(first['devices'], isList);
      expect((first['devices'] as List), isEmpty);

      await channel.sink.close();
    });

    test('sends initial state with existing devices', () async {
      mockDiscovery.addDevice(TestScale(deviceId: 'scale-1', name: 'My Scale'));
      await Future.delayed(Duration.zero);

      final (channel, messages) = connectWs();

      final state = await messages
          .where(
            (msg) =>
                msg.containsKey('devices') &&
                (msg['devices'] as List).isNotEmpty,
          )
          .first
          .timeout(Duration(seconds: 2));

      expect(state['scanning'], false);
      final devices = state['devices'] as List;
      expect(devices, hasLength(1));
      expect(devices[0]['id'], 'scale-1');
      expect(devices[0]['name'], 'My Scale');
      expect(devices[0]['type'], 'scale');

      await channel.sink.close();
    });

    test('emits update when device is added', () async {
      final (channel, messages) = connectWs();

      await waitForState(messages);

      mockDiscovery.addDevice(
        TestScale(deviceId: 'new-scale', name: 'New Scale'),
      );

      final update = await messages
          .where(
            (msg) =>
                msg.containsKey('devices') &&
                (msg['devices'] as List).isNotEmpty,
          )
          .first
          .timeout(Duration(seconds: 2));

      final devices = update['devices'] as List;
      expect(devices, hasLength(1));
      expect(devices[0]['id'], 'new-scale');

      await channel.sink.close();
    });

    test('emits update when device is removed', () async {
      mockDiscovery.addDevice(TestScale(deviceId: 'scale-1', name: 'Scale'));
      await Future.delayed(Duration.zero);

      final (channel, messages) = connectWs();

      await messages
          .where(
            (msg) =>
                msg.containsKey('devices') &&
                (msg['devices'] as List).isNotEmpty,
          )
          .first
          .timeout(Duration(seconds: 2));

      mockDiscovery.removeDevice('scale-1');

      final update = await messages
          .where(
            (msg) =>
                msg.containsKey('devices') && (msg['devices'] as List).isEmpty,
          )
          .first
          .timeout(Duration(seconds: 2));

      expect((update['devices'] as List), isEmpty);

      await channel.sink.close();
    });

    test('responds with error for unknown command', () async {
      final (channel, messages) = connectWs();

      await waitForState(messages);

      channel.sink.add(jsonEncode({'command': 'reboot'}));

      final response = await waitForError(messages);
      expect(response['error'], contains('Unknown command'));

      await channel.sink.close();
    });

    test('responds with error for missing command field', () async {
      final (channel, messages) = connectWs();

      await waitForState(messages);

      channel.sink.add(jsonEncode({'action': 'scan'}));

      final response = await waitForError(messages);
      expect(response['error'], contains('Missing "command"'));

      await channel.sink.close();
    });

    test('responds with error for invalid JSON', () async {
      final (channel, messages) = connectWs();

      await waitForState(messages);

      channel.sink.add('not json');

      final response = await waitForError(messages);
      expect(response['error'], contains('Invalid JSON'));

      await channel.sink.close();
    });

    test('connect command with missing deviceId returns error', () async {
      final (channel, messages) = connectWs();

      await waitForState(messages);

      channel.sink.add(jsonEncode({'command': 'connect'}));

      final response = await waitForError(messages);
      expect(response['error'], contains('Missing "deviceId"'));

      await channel.sink.close();
    });

    test('disconnect command with unknown device returns error', () async {
      final (channel, messages) = connectWs();

      await waitForState(messages);

      channel.sink.add(
        jsonEncode({'command': 'disconnect', 'deviceId': 'nonexistent'}),
      );

      final response = await waitForError(messages);
      expect(response['error'], contains('Device not found'));

      await channel.sink.close();
    });

    test('disconnect command calls device.disconnect()', () async {
      mockDiscovery.addDevice(TestScale(deviceId: 'scale-1', name: 'Scale'));
      await Future.delayed(Duration.zero);

      final (channel, messages) = connectWs();

      await messages
          .where(
            (msg) =>
                msg.containsKey('devices') &&
                (msg['devices'] as List).isNotEmpty,
          )
          .first
          .timeout(Duration(seconds: 2));

      channel.sink.add(
        jsonEncode({'command': 'disconnect', 'deviceId': 'scale-1'}),
      );

      await Future.delayed(Duration(milliseconds: 100));

      await channel.sink.close();
    });

    test('scan command defaults to scan-first connection policy', () async {
      final (channel, messages) = connectWs();

      await waitForState(messages);
      channel.sink.add(jsonEncode({'command': 'scan'}));

      await waitForState(messages);
      await Future.delayed(const Duration(milliseconds: 300));
      expect(mockDiscovery.scanCallCount, 1);
      expect(connectionManager.lastScanReport, isNotNull);

      await channel.sink.close();
    });

    test('scan command connect=false opts into discovery-only', () async {
      final (channel, messages) = connectWs();

      await waitForState(messages);
      channel.sink.add(jsonEncode({'command': 'scan', 'connect': false}));

      await waitForState(messages);
      await Future.delayed(const Duration(milliseconds: 300));
      expect(connectionManager.lastScanReport, isNull);

      await channel.sink.close();
    });

    test('scan command triggers scanForDevices', () async {
      final (channel, messages) = connectWs();

      await waitForState(messages);

      channel.sink.add(
        jsonEncode({'command': 'scan', 'connect': false, 'quick': true}),
      );

      final update = await waitForState(messages);
      expect(update, containsPair('scanning', isA<bool>()));

      await channel.sink.close();
    });

    test('connect command connects a scale device', () async {
      mockDiscovery.addDevice(TestScale(deviceId: 'scale-1', name: 'Scale'));
      await Future.delayed(Duration.zero);

      final (channel, messages) = connectWs();

      await messages
          .where(
            (msg) =>
                msg.containsKey('devices') &&
                (msg['devices'] as List).isNotEmpty,
          )
          .first
          .timeout(Duration(seconds: 2));

      channel.sink.add(
        jsonEncode({'command': 'connect', 'deviceId': 'scale-1'}),
      );

      await Future.delayed(Duration(milliseconds: 100));

      await channel.sink.close();
    });

    test('connect failure sends a structured command result', () async {
      final scale = _FailingWsScale(deviceId: 'scale-failure');
      mockDiscovery.addDevice(scale);
      await Future.delayed(Duration.zero);

      final (channel, messages) = connectWs();
      await waitForState(messages);

      channel.sink.add(
        jsonEncode({'command': 'connect', 'deviceId': scale.deviceId}),
      );

      final response = await waitForError(messages);
      expect(response['outcome'], 'failed');
      expect(response['connectionError']['kind'], 'scaleConnectFailed');
      expect(response['connectionError']['deviceId'], scale.deviceId);

      await channel.sink.close();
    });

    test('serializes connect results in command order', () async {
      final blocker = Completer<void>();
      final scale = _BlockingWsScale(
        deviceId: 'scale-blocked',
        blocker: blocker,
      );
      mockDiscovery.addDevice(scale);
      await Future.delayed(Duration.zero);

      final (channel, messages) = connectWs();
      await waitForState(messages);
      final resultsFuture = messages
          .where(
            (message) =>
                message['operation'] == 'connect' &&
                message['deviceId'] == scale.deviceId,
          )
          .take(2)
          .toList()
          .timeout(Duration(seconds: 2));

      final command = jsonEncode({
        'command': 'connect',
        'deviceId': scale.deviceId,
      });
      channel.sink.add(command);
      channel.sink.add(command);
      await Future.delayed(Duration.zero);
      blocker.complete();

      final results = await resultsFuture;
      expect(results.map((result) => result['outcome']), [
        'connected',
        'alreadyConnected',
      ]);

      await channel.sink.close();
    });

    test(
      'connect reports an already-connected sensor without reconnecting',
      () async {
        final sensor = TestSensor(deviceId: 'sensor-connected');
        mockDiscovery.addDevice(sensor);
        await Future.delayed(Duration.zero);

        final (channel, messages) = connectWs();
        await waitForState(messages);
        final resultFuture = messages
            .where(
              (message) =>
                  message['operation'] == 'connect' &&
                  message['deviceId'] == sensor.deviceId,
            )
            .first
            .timeout(Duration(seconds: 2));

        channel.sink.add(
          jsonEncode({'command': 'connect', 'deviceId': sensor.deviceId}),
        );

        final result = await resultFuture;
        expect(result['outcome'], 'alreadyConnected');
        expect(result['state'], 'connected');
        expect(sensor.connectCallCount, 0);

        await channel.sink.close();
      },
    );

    test('emits update when device connection state changes', () async {
      final scale = TestScale(deviceId: 'scale-1', name: 'Scale');
      mockDiscovery.addDevice(scale);
      await Future.delayed(Duration.zero);

      final (channel, messages) = connectWs();

      await messages
          .where(
            (msg) =>
                msg.containsKey('devices') &&
                (msg['devices'] as List).isNotEmpty &&
                (msg['devices'] as List)[0]['state'] == 'connected',
          )
          .first
          .timeout(Duration(seconds: 2));

      scale.setConnectionState(ConnectionState.disconnected);

      final update = await messages
          .where(
            (msg) =>
                msg.containsKey('devices') &&
                (msg['devices'] as List).isNotEmpty &&
                (msg['devices'] as List)[0]['state'] == 'disconnected',
          )
          .first
          .timeout(Duration(seconds: 2));

      expect((update['devices'] as List)[0]['state'], 'disconnected');

      await channel.sink.close();
    });

    test('handles device reappearance with same ID', () async {
      final scale1 = TestScale(deviceId: 'scale-1', name: 'Scale');
      mockDiscovery.addDevice(scale1);
      await Future.delayed(Duration.zero);

      final (channel, messages) = connectWs();

      await messages
          .where(
            (msg) =>
                msg.containsKey('devices') &&
                (msg['devices'] as List).isNotEmpty,
          )
          .first
          .timeout(Duration(seconds: 2));

      mockDiscovery.removeDevice('scale-1');
      await messages
          .where(
            (msg) =>
                msg.containsKey('devices') && (msg['devices'] as List).isEmpty,
          )
          .first
          .timeout(Duration(seconds: 2));

      final scale2 = TestScale(
        deviceId: 'scale-1',
        name: 'Scale',
        initialState: ConnectionState.discovered,
      );
      mockDiscovery.addDevice(scale2);

      final update = await messages
          .where(
            (msg) =>
                msg.containsKey('devices') &&
                (msg['devices'] as List).isNotEmpty &&
                (msg['devices'] as List)[0]['state'] == 'discovered',
          )
          .first
          .timeout(Duration(seconds: 2));

      expect((update['devices'] as List)[0]['state'], 'discovered');

      scale2.setConnectionState(ConnectionState.connected);

      final connected = await messages
          .where(
            (msg) =>
                msg.containsKey('devices') &&
                (msg['devices'] as List).isNotEmpty &&
                (msg['devices'] as List)[0]['state'] == 'connected',
          )
          .first
          .timeout(Duration(seconds: 2));

      expect((connected['devices'] as List)[0]['state'], 'connected');

      await channel.sink.close();
    });

    test('multiple clients receive same state updates', () async {
      final (channel1, messages1) = connectWs();
      final (channel2, messages2) = connectWs();

      await waitForState(messages1);
      await waitForState(messages2);

      final deviceAdded1 = messages1
          .where(
            (msg) =>
                msg.containsKey('devices') &&
                (msg['devices'] as List).isNotEmpty,
          )
          .first
          .timeout(Duration(seconds: 2));

      final deviceAdded2 = messages2
          .where(
            (msg) =>
                msg.containsKey('devices') &&
                (msg['devices'] as List).isNotEmpty,
          )
          .first
          .timeout(Duration(seconds: 2));

      final scale = TestScale(deviceId: 'scale-1', name: 'Scale');
      mockDiscovery.addDevice(scale);

      final update1 = await deviceAdded1;
      final update2 = await deviceAdded2;

      expect((update1['devices'] as List)[0]['id'], 'scale-1');
      expect((update2['devices'] as List)[0]['id'], 'scale-1');

      final stateChanged1 = messages1
          .where(
            (msg) =>
                msg.containsKey('devices') &&
                (msg['devices'] as List).isNotEmpty &&
                (msg['devices'] as List)[0]['state'] == 'disconnected',
          )
          .first
          .timeout(Duration(seconds: 2));

      final stateChanged2 = messages2
          .where(
            (msg) =>
                msg.containsKey('devices') &&
                (msg['devices'] as List).isNotEmpty &&
                (msg['devices'] as List)[0]['state'] == 'disconnected',
          )
          .first
          .timeout(Duration(seconds: 2));

      scale.setConnectionState(ConnectionState.disconnected);

      final stateUpdate1 = await stateChanged1;
      final stateUpdate2 = await stateChanged2;

      expect((stateUpdate1['devices'] as List)[0]['state'], 'disconnected');
      expect((stateUpdate2['devices'] as List)[0]['state'], 'disconnected');

      await channel1.sink.close();
      await channel2.sink.close();
    });
  });
}

class _FailingWsScale extends TestScale {
  _FailingWsScale({required super.deviceId})
    : super(initialState: ConnectionState.disconnected);

  @override
  Future<void> onConnect() async {
    throw StateError('scale unavailable');
  }
}

class _BlockingWsScale extends TestScale {
  final Completer<void> blocker;

  _BlockingWsScale({required super.deviceId, required this.blocker});

  @override
  Future<void> onConnect() => blocker.future;
}
