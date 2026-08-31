import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_virtual_scale.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:rxdart/rxdart.dart';

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
  late Handler handler;

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
    handler = app.call;
  });

  tearDown(() {
    devicesHandler.dispose();
    connectionManager.dispose();
    deviceController.dispose();
  });

  Future<Response> sendPut(String path, {String? body}) async {
    return await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost$path'),
        body: body,
        headers: body != null ? {'content-type': 'application/json'} : null,
      ),
    );
  }

  Future<Response> sendGet(String path) async {
    return await handler(Request('GET', Uri.parse('http://localhost$path')));
  }

  group('DevicesHandler', () {
    group('_extractDeviceId', () {
      test('reads deviceId from JSON body', () async {
        final response = await sendPut(
          '/api/v1/devices/connect',
          body: jsonEncode({'deviceId': 'AA:BB:CC:DD:EE:FF'}),
        );
        expect(response.statusCode, 404);
      });

      test('reads deviceId from query parameter', () async {
        final response = await sendPut(
          '/api/v1/devices/connect?deviceId=some-device',
        );
        expect(response.statusCode, 404);
      });

      test('returns 400 when deviceId is missing entirely', () async {
        final response = await sendPut('/api/v1/devices/connect');
        expect(response.statusCode, 400);
        final body = jsonDecode(await response.readAsString());
        expect(body['error'], 'Missing deviceId');
      });

      test('returns 400 when body is empty JSON object', () async {
        final response = await sendPut(
          '/api/v1/devices/connect',
          body: jsonEncode({}),
        );
        expect(response.statusCode, 400);
      });

      test('falls back to query param when body has no deviceId', () async {
        final response = await sendPut(
          '/api/v1/devices/connect?deviceId=fallback-id',
          body: jsonEncode({'other': 'field'}),
        );
        expect(response.statusCode, 404);
      });

      test('body takes precedence over query param', () async {
        mockDiscovery.addDevice(
          TestScale(deviceId: 'body-id', name: 'Body Scale'),
        );
        await Future.delayed(Duration.zero);

        final response = await sendPut(
          '/api/v1/devices/connect?deviceId=query-id',
          body: jsonEncode({'deviceId': 'body-id'}),
        );
        expect(response.statusCode, 200);
      });

      test('falls back to query param when body is invalid JSON', () async {
        final response = await handler(
          Request(
            'PUT',
            Uri.parse(
              'http://localhost/api/v1/devices/connect?deviceId=fallback',
            ),
            body: 'not json at all',
          ),
        );
        expect(response.statusCode, 404);
      });
    });

    group('BLE and USB device IDs', () {
      test('handles BLE MAC address with colons via body', () async {
        const macAddress = 'AA:BB:CC:DD:EE:FF';
        mockDiscovery.addDevice(
          TestScale(deviceId: macAddress, name: 'BLE Scale'),
        );
        await Future.delayed(Duration.zero);

        final response = await sendPut(
          '/api/v1/devices/connect',
          body: jsonEncode({'deviceId': macAddress}),
        );
        expect(response.statusCode, 200);
      });

      test('handles BLE UUID with hyphens via body', () async {
        const uuid = '550e8400-e29b-41d4-a716-446655440000';
        mockDiscovery.addDevice(TestScale(deviceId: uuid, name: 'iOS Scale'));
        await Future.delayed(Duration.zero);

        final response = await sendPut(
          '/api/v1/devices/connect',
          body: jsonEncode({'deviceId': uuid}),
        );
        expect(response.statusCode, 200);
      });

      test('handles USB serial port path with slashes via body', () async {
        const serialPath = '/dev/ttyUSB0';
        mockDiscovery.addDevice(
          TestScale(deviceId: serialPath, name: 'USB Scale'),
        );
        await Future.delayed(Duration.zero);

        final response = await sendPut(
          '/api/v1/devices/connect',
          body: jsonEncode({'deviceId': serialPath}),
        );
        expect(response.statusCode, 200);
      });

      test('handles MAC address via query parameter', () async {
        const macAddress = 'AA:BB:CC:DD:EE:FF';
        mockDiscovery.addDevice(
          TestScale(deviceId: macAddress, name: 'BLE Scale'),
        );
        await Future.delayed(Duration.zero);

        final response = await sendPut(
          '/api/v1/devices/connect?deviceId=$macAddress',
        );
        expect(response.statusCode, 200);
      });
    });

    test('connect continues a pending scale selection session', () async {
      final scale1 = TestScale(deviceId: 'scale-1', name: 'Scale 1');
      final scale2 = TestScale(deviceId: 'scale-2', name: 'Scale 2');
      mockDiscovery.addDevice(scale1);
      mockDiscovery.addDevice(scale2);
      await Future.delayed(Duration.zero);

      await connectionManager.scanAndConnect();
      expect(
        connectionManager.currentStatus.pendingAmbiguity,
        AmbiguityReason.scalePicker,
      );

      final response = await sendPut(
        '/api/v1/devices/connect',
        body: jsonEncode({'deviceId': scale2.deviceId}),
      );

      expect(response.statusCode, 200);
      expect(connectionManager.currentStatus.pendingAmbiguity, isNull);
      expect(
        connectionManager.lastScanReport?.matchedDevices
            .firstWhere((device) => device.deviceId == scale2.deviceId)
            .connectionResult
            ?.success,
        isTrue,
      );
    });

    test('connect returns a structured successful outcome', () async {
      final scale = TestScale(deviceId: 'scale-success', name: 'Scale');
      mockDiscovery.addDevice(scale);
      await Future.delayed(Duration.zero);

      final response = await sendPut(
        '/api/v1/devices/connect',
        body: jsonEncode({'deviceId': scale.deviceId}),
      );
      final body = jsonDecode(await response.readAsString());

      expect(response.statusCode, 200);
      expect(body, {
        'deviceId': scale.deviceId,
        'operation': 'connect',
        'outcome': 'connected',
        'state': 'connected',
        'connectionError': null,
      });
    });

    test(
      'connect reports an already-connected sensor without reconnecting',
      () async {
        final sensor = TestSensor(deviceId: 'sensor-connected');
        mockDiscovery.addDevice(sensor);
        await Future.delayed(Duration.zero);

        final response = await sendPut(
          '/api/v1/devices/connect',
          body: jsonEncode({'deviceId': sensor.deviceId}),
        );
        final body = jsonDecode(await response.readAsString());

        expect(response.statusCode, 200);
        expect(body['outcome'], 'alreadyConnected');
        expect(body['state'], 'connected');
        expect(sensor.connectCallCount, 0);
      },
    );

    test('connect failure returns 503 and the structured error', () async {
      final scale = _FailingTestScale(deviceId: 'scale-failure');
      mockDiscovery.addDevice(scale);
      await Future.delayed(Duration.zero);

      final response = await sendPut(
        '/api/v1/devices/connect',
        body: jsonEncode({'deviceId': scale.deviceId}),
      );
      final body = jsonDecode(await response.readAsString());

      expect(response.statusCode, 503);
      expect(body['outcome'], 'failed');
      expect(body['state'], 'disconnected');
      expect(body['connectionError']['kind'], 'scaleConnectFailed');
      expect(body['connectionError']['deviceId'], scale.deviceId);
    });

    test('overlapping connect returns 409 instead of false success', () async {
      final blocker = Completer<void>();
      final first = _BlockingTestScale(
        deviceId: 'scale-first',
        blocker: blocker,
      );
      final second = TestScale(
        deviceId: 'scale-second',
        initialState: ConnectionState.disconnected,
      );
      mockDiscovery.addDevice(first);
      mockDiscovery.addDevice(second);
      await Future.delayed(Duration.zero);

      final firstRequest = sendPut(
        '/api/v1/devices/connect',
        body: jsonEncode({'deviceId': first.deviceId}),
      );
      await Future.delayed(Duration.zero);
      final response = await sendPut(
        '/api/v1/devices/connect',
        body: jsonEncode({'deviceId': second.deviceId}),
      );
      final body = jsonDecode(await response.readAsString());

      expect(response.statusCode, 409);
      expect(body['outcome'], 'conflict');
      expect(body['deviceId'], second.deviceId);

      blocker.complete();
      await firstRequest;
    });

    group('disconnect', () {
      test('reads deviceId from JSON body', () async {
        mockDiscovery.addDevice(
          TestScale(deviceId: 'scale-1', name: 'My Scale'),
        );
        await Future.delayed(Duration.zero);

        final response = await sendPut(
          '/api/v1/devices/disconnect',
          body: jsonEncode({'deviceId': 'scale-1'}),
        );
        expect(response.statusCode, 200);
      });

      test('returns 400 when deviceId is missing', () async {
        final response = await sendPut('/api/v1/devices/disconnect');
        expect(response.statusCode, 400);
        final body = jsonDecode(await response.readAsString());
        expect(body['error'], 'Missing deviceId');
      });

      test('returns 404 when device not found', () async {
        final response = await sendPut(
          '/api/v1/devices/disconnect',
          body: jsonEncode({'deviceId': 'nonexistent'}),
        );
        expect(response.statusCode, 404);
      });
    });

    group('scan endpoint', () {
      test('defaults to scan-first connection policy', () async {
        final response = await sendGet('/api/v1/devices/scan');

        expect(response.statusCode, 200);
        expect(mockDiscovery.scanCallCount, 1);
        expect(connectionManager.lastScanReport, isNotNull);
      });

      test('connect=false opts into discovery-only', () async {
        final response = await sendGet('/api/v1/devices/scan?connect=false');

        expect(response.statusCode, 200);
        expect(connectionManager.lastScanReport, isNull);
      });
    });

    group('scanning state', () {
      test('isScanning is initially false', () {
        expect(deviceController.isScanning, isFalse);
      });

      test(
        'scanningStream emits true then false during scanForDevices',
        () async {
          final states = <bool>[];
          final sub = deviceController.scanningStream.listen(states.add);

          await deviceController.scanForDevices();
          await Future.delayed(Duration(milliseconds: 300));

          sub.cancel();

          expect(states, contains(true));
          expect(states.last, isFalse);
        },
      );
    });

    group('device list', () {
      test('returns empty list when no devices', () async {
        final response = await sendGet('/api/v1/devices');
        expect(response.statusCode, 200);
        final body = jsonDecode(await response.readAsString());
        expect(body, isEmpty);
      });

      test('returns discovered devices with id field', () async {
        mockDiscovery.addDevice(
          TestScale(deviceId: 'AA:BB:CC:DD:EE:FF', name: 'Test Scale'),
        );
        await Future.delayed(Duration.zero);

        final response = await sendGet('/api/v1/devices');
        expect(response.statusCode, 200);
        final body = jsonDecode(await response.readAsString()) as List;
        expect(body, hasLength(1));
        expect(body[0]['id'], 'AA:BB:CC:DD:EE:FF');
        expect(body[0]['name'], 'Test Scale');
        expect(body[0]['type'], 'scale');
      });

      test('returns connected-session device information', () async {
        final scale = _DeviceInformationTestScale(
          deviceId: 'scale-info',
          name: 'Skale',
        );
        scale.emitDeviceInformation(
          const DeviceInformation(firmwareVersion: 'R029', batteryLevel: 82),
        );
        mockDiscovery.addDevice(scale);
        await Future<void>.delayed(Duration.zero);

        final response = await sendGet('/api/v1/devices');
        expect(response.statusCode, 200);
        final body = jsonDecode(await response.readAsString()) as List;

        expect(body.single['deviceInfo'], {
          'firmwareVersion': 'R029',
          'batteryLevel': 82,
        });
      });

      test('returns a connected scale that is outside discovery', () async {
        final bengle = MockBengle();
        await bengle.onConnect();
        addTearDown(bengle.onDisconnect);
        await scaleController.connectToScale(BengleVirtualScale(bengle));

        final response = await sendGet('/api/v1/devices');
        expect(response.statusCode, 200);
        final body = jsonDecode(await response.readAsString()) as List;
        expect(body, [
          {
            'name': 'Bengle scale',
            'id': 'bengle-internal-MockBengle',
            'state': 'connected',
            'type': 'scale',
            'available': true,
          },
        ]);
      });

      test('rejects machine-managed scale commands explicitly', () async {
        final bengle = MockBengle();
        await bengle.onConnect();
        addTearDown(bengle.onDisconnect);
        final scale = BengleVirtualScale(bengle);
        await scaleController.connectToScale(scale);

        for (final operation in ['connect', 'disconnect']) {
          final response = await sendPut(
            '/api/v1/devices/$operation',
            body: jsonEncode({'deviceId': scale.deviceId}),
          );
          expect(response.statusCode, 409);
          expect(jsonDecode(await response.readAsString()), {
            'error':
                'Device is inventory-only and cannot be controlled here: '
                '${scale.deviceId}',
          });
        }
      });
    });
  });

  group('DevicesStateAggregator', () {
    late DeviceController deviceController;
    late De1Controller de1Controller;
    late ScaleController scaleController;
    late ConnectionManager connectionManager;
    late MockDeviceDiscoveryService mockDiscovery;
    late DevicesStateAggregator aggregator;

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

      aggregator = DevicesStateAggregator(
        controller: deviceController,
        connectionManager: connectionManager,
      );
    });

    tearDown(() {
      aggregator.dispose();
      connectionManager.dispose();
      deviceController.dispose();
    });

    test('emits initial state with empty device list', () async {
      final state = await aggregator.stateStream.first;

      expect(state['devices'], isList);
      expect((state['devices'] as List), isEmpty);
      expect(state['scanning'], false);
      expect(state['timestamp'], isA<String>());
    });

    test('snapshot error is null when no error set', () async {
      final state = await aggregator.stateStream.first;

      expect(state['connectionStatus'], isA<Map>());
      expect(state['connectionStatus']['error'], isNull);
    });

    test('snapshot serializes structured ConnectionError', () async {
      await aggregator.stateStream.first;

      connectionManager.debugEmitError(
        kind: ConnectionErrorKind.scaleConnectFailed,
        severity: ConnectionErrorSeverity.error,
        message: 'fail',
        deviceId: '50:78:7D:1F:AE:E1',
        deviceName: 'Decent Scale',
        timestamp: DateTime.utc(2026, 4, 19),
      );

      final state = await aggregator.stateStream
          .where((s) => s['connectionStatus']?['error'] != null)
          .first
          .timeout(Duration(seconds: 2));

      expect(state['connectionStatus']['error'], {
        'kind': 'scaleConnectFailed',
        'severity': 'error',
        'timestamp': '2026-04-19T00:00:00.000Z',
        'deviceId': '50:78:7D:1F:AE:E1',
        'deviceName': 'Decent Scale',
        'message': 'fail',
      });
    });

    test('emits update when device is added', () async {
      await aggregator.stateStream.first;

      mockDiscovery.addDevice(TestScale(deviceId: 'scale-1', name: 'Scale 1'));

      final state = await aggregator.stateStream
          .where((s) => (s['devices'] as List).isNotEmpty)
          .first
          .timeout(Duration(seconds: 2));

      final devices = state['devices'] as List;
      expect(devices, hasLength(1));
      expect(devices[0]['id'], 'scale-1');
    });

    test('emits update when device is removed', () async {
      mockDiscovery.addDevice(TestScale(deviceId: 'scale-1', name: 'Scale 1'));

      await aggregator.stateStream
          .where((s) => (s['devices'] as List).isNotEmpty)
          .first
          .timeout(Duration(seconds: 2));

      mockDiscovery.removeDevice('scale-1');

      final state = await aggregator.stateStream
          .where((s) => (s['devices'] as List).isEmpty)
          .first
          .timeout(Duration(seconds: 2));

      expect((state['devices'] as List), isEmpty);
    });

    test('cleans up subscription when device is removed', () async {
      mockDiscovery.addDevice(TestScale(deviceId: 'scale-1', name: 'Scale 1'));
      await aggregator.stateStream
          .where((s) => (s['devices'] as List).isNotEmpty)
          .first
          .timeout(Duration(seconds: 2));

      expect(aggregator.activeDeviceSubscriptionCount, 1);

      mockDiscovery.removeDevice('scale-1');
      await aggregator.stateStream
          .where((s) => (s['devices'] as List).isEmpty)
          .first
          .timeout(Duration(seconds: 2));

      expect(aggregator.activeDeviceSubscriptionCount, 0);
    });

    test('emits update when device connection state changes', () async {
      final scale = TestScale(deviceId: 'scale-1', name: 'Scale 1');
      mockDiscovery.addDevice(scale);

      await aggregator.stateStream
          .where(
            (s) =>
                (s['devices'] as List).isNotEmpty &&
                (s['devices'] as List)[0]['state'] == 'connected',
          )
          .first
          .timeout(Duration(seconds: 2));

      scale.setConnectionState(ConnectionState.disconnected);

      final state = await aggregator.stateStream
          .where(
            (s) =>
                (s['devices'] as List).isNotEmpty &&
                (s['devices'] as List)[0]['state'] == 'disconnected',
          )
          .first
          .timeout(Duration(seconds: 2));

      expect((state['devices'] as List)[0]['state'], 'disconnected');
    });

    test('emits connected-session device information updates', () async {
      final scale = _DeviceInformationTestScale(
        deviceId: 'scale-info',
        name: 'Skale',
      );
      mockDiscovery.addDevice(scale);

      await aggregator.stateStream
          .where((s) => (s['devices'] as List).isNotEmpty)
          .first
          .timeout(const Duration(seconds: 2));

      scale.emitDeviceInformation(
        const DeviceInformation(firmwareVersion: 'R029'),
      );

      final state = await aggregator.stateStream
          .where(
            (s) =>
                (s['devices'] as List)
                    .first['deviceInfo']?['firmwareVersion'] ==
                'R029',
          )
          .first
          .timeout(const Duration(seconds: 2));

      expect((state['devices'] as List).first['deviceInfo'], {
        'firmwareVersion': 'R029',
      });
    });

    test('device information follows a same-ID replacement instance', () async {
      final first = _DeviceInformationTestScale(
        deviceId: 'scale-info',
        name: 'Skale v1',
      );
      mockDiscovery.addDevice(first);
      await aggregator.stateStream
          .where((s) => (s['devices'] as List).isNotEmpty)
          .first
          .timeout(const Duration(seconds: 2));

      mockDiscovery.clear();
      final replacement = _DeviceInformationTestScale(
        deviceId: 'scale-info',
        name: 'Skale v2',
      );
      mockDiscovery.addDevice(replacement);
      await aggregator.stateStream
          .where(
            (s) =>
                (s['devices'] as List).isNotEmpty &&
                (s['devices'] as List).first['name'] == 'Skale v2',
          )
          .first
          .timeout(const Duration(seconds: 2));

      replacement.emitDeviceInformation(
        const DeviceInformation(firmwareVersion: 'R030'),
      );
      final state = await aggregator.stateStream
          .where(
            (s) =>
                (s['devices'] as List)
                    .first['deviceInfo']?['firmwareVersion'] ==
                'R030',
          )
          .first
          .timeout(const Duration(seconds: 2));

      first.emitDeviceInformation(
        const DeviceInformation(firmwareVersion: 'stale'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect((state['devices'] as List).first['deviceInfo'], {
        'firmwareVersion': 'R030',
      });
      final latest = await aggregator.stateStream.first;
      expect((latest['devices'] as List).first['deviceInfo'], {
        'firmwareVersion': 'R030',
      });
    });

    test('resubscribes when device reappears with same ID', () async {
      final scale1 = TestScale(deviceId: 'scale-1', name: 'Scale 1');
      mockDiscovery.addDevice(scale1);

      await aggregator.stateStream
          .where((s) => (s['devices'] as List).isNotEmpty)
          .first
          .timeout(Duration(seconds: 2));

      mockDiscovery.removeDevice('scale-1');
      await aggregator.stateStream
          .where((s) => (s['devices'] as List).isEmpty)
          .first
          .timeout(Duration(seconds: 2));

      final scale2 = TestScale(
        deviceId: 'scale-1',
        name: 'Scale 1',
        initialState: ConnectionState.discovered,
      );
      mockDiscovery.addDevice(scale2);

      final state = await aggregator.stateStream
          .where(
            (s) =>
                (s['devices'] as List).isNotEmpty &&
                (s['devices'] as List)[0]['state'] == 'discovered',
          )
          .first
          .timeout(Duration(seconds: 2));

      expect((state['devices'] as List)[0]['state'], 'discovered');

      scale2.setConnectionState(ConnectionState.connected);

      final updated = await aggregator.stateStream
          .where(
            (s) =>
                (s['devices'] as List).isNotEmpty &&
                (s['devices'] as List)[0]['state'] == 'connected',
          )
          .first
          .timeout(Duration(seconds: 2));

      expect((updated['devices'] as List)[0]['state'], 'connected');
    });

    test(
      'replaces subscription when same-ID different-object appears in-place',
      () async {
        final scale1 = TestScale(deviceId: 'scale-1', name: 'Scale v1');
        mockDiscovery.addDevice(scale1);

        await aggregator.stateStream
            .where((s) => (s['devices'] as List).isNotEmpty)
            .first
            .timeout(Duration(seconds: 2));

        expect(aggregator.activeDeviceSubscriptionCount, 1);

        mockDiscovery.clear();
        final scale2 = TestScale(deviceId: 'scale-1', name: 'Scale v2');
        mockDiscovery.addDevice(scale2);

        await aggregator.stateStream
            .where(
              (s) =>
                  (s['devices'] as List).isNotEmpty &&
                  (s['devices'] as List)[0]['name'] == 'Scale v2',
            )
            .first
            .timeout(Duration(seconds: 2));

        expect(aggregator.activeDeviceSubscriptionCount, 1);

        scale1.setConnectionState(ConnectionState.disconnected);
        await Future.delayed(Duration(milliseconds: 200));

        final current = await aggregator.stateStream.first;
        expect((current['devices'] as List)[0]['state'], 'connected');

        scale2.setConnectionState(ConnectionState.disconnecting);

        final state = await aggregator.stateStream
            .where(
              (s) =>
                  (s['devices'] as List).isNotEmpty &&
                  (s['devices'] as List)[0]['state'] == 'disconnecting',
            )
            .first
            .timeout(Duration(seconds: 2));

        expect((state['devices'] as List)[0]['state'], 'disconnecting');
      },
    );

    test('debounces rapid changes into single emission', () async {
      await aggregator.stateStream.first;

      final emissions = <Map<String, dynamic>>[];
      final sub = aggregator.stateStream.listen(emissions.add);

      mockDiscovery.addDevice(TestScale(deviceId: 'scale-1', name: 'Scale 1'));
      mockDiscovery.addDevice(TestScale(deviceId: 'scale-2', name: 'Scale 2'));
      mockDiscovery.addDevice(TestScale(deviceId: 'scale-3', name: 'Scale 3'));

      await Future.delayed(Duration(milliseconds: 300));

      sub.cancel();

      final lastDevices = emissions.last['devices'] as List;
      expect(lastDevices, hasLength(3));
      expect(emissions.length, lessThan(3));
    });

    test('no new emissions after dispose', () async {
      await aggregator.stateStream.first;

      aggregator.dispose();

      final emissions = <Map<String, dynamic>>[];
      final completer = Completer<void>();
      aggregator.stateStream.listen(
        emissions.add,
        onError: (_) {},
        onDone: () => completer.complete(),
      );

      await completer.future.timeout(Duration(seconds: 1));

      final countAfterClose = emissions.length;

      mockDiscovery.addDevice(TestScale(deviceId: 'scale-1', name: 'Scale 1'));
      await Future.delayed(Duration(milliseconds: 200));

      expect(emissions.length, countAfterClose);
    });
  });
}

class _FailingTestScale extends TestScale {
  _FailingTestScale({required super.deviceId})
    : super(initialState: ConnectionState.disconnected);

  @override
  Future<void> onConnect() async {
    throw StateError('scale unavailable');
  }
}

class _BlockingTestScale extends TestScale {
  final Completer<void> blocker;

  _BlockingTestScale({required super.deviceId, required this.blocker});

  @override
  Future<void> onConnect() => blocker.future;
}

class _DeviceInformationTestScale extends TestScale
    implements DeviceInformationCapable {
  _DeviceInformationTestScale({required super.deviceId, required super.name});

  DeviceInformation? _information;
  final BehaviorSubject<DeviceInformation?> _informationController =
      BehaviorSubject<DeviceInformation?>.seeded(null);

  @override
  DeviceInformation? get currentDeviceInformation => _information;

  @override
  Stream<DeviceInformation?> get deviceInformation =>
      _informationController.stream;

  void emitDeviceInformation(DeviceInformation? information) {
    _information = information;
    _informationController.add(information);
  }
}
