import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:web_socket_channel/io.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';

void main() {
  late MockDeviceDiscoveryService discovery;
  late DeviceController devices;
  late ConnectionManager manager;
  late DevicesHandler devicesHandler;
  late HttpServer server;

  setUp(() async {
    discovery = MockDeviceDiscoveryService();
    devices = DeviceController([discovery]);
    await devices.initialize();
    final de1 = De1Controller(controller: devices);
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    manager = ConnectionManager(
      deviceScanner: devices,
      de1Controller: de1,
      scaleController: ScaleController(),
      settingsController: settings,
    );
    devicesHandler = DevicesHandler(
      controller: devices,
      connectionManager: manager,
    );
    final app = Router().plus;
    devicesHandler.addRoutes(app);
    server = await shelf_io.serve(app.call, InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
    devicesHandler.dispose();
    await manager.dispose();
    devices.dispose();
  });

  Future<Response> request(String method, String path, {String? body}) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(body);
      }
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      return Response(
        response.statusCode,
        body: responseBody,
        headers: response.headers.contentType == null
            ? null
            : {'content-type': response.headers.contentType.toString()},
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Response> connectRest(String id, {Object? role}) async {
    final body = <String, dynamic>{'deviceId': id};
    if (role != null) body['connectionRole'] = role;
    return request('PUT', '/api/v1/devices/connect', body: jsonEncode(body));
  }

  Future<Response> connectRestBody(Map<String, dynamic> body) =>
      request('PUT', '/api/v1/devices/connect', body: jsonEncode(body));

  Future<Response> disconnectRest(String id) => request(
    'PUT',
    '/api/v1/devices/disconnect',
    body: jsonEncode({'deviceId': id}),
  );

  Future<Response> listRest() => request('GET', '/api/v1/devices');

  Future<void> settle() async =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  test(
    'REST auxiliary connect is idempotent and does not set primary',
    () async {
      final auxiliary = TestScale(deviceId: 'auxiliary-rest');
      addTearDown(auxiliary.dispose);
      discovery.addDevice(auxiliary);
      await settle();

      final first = await connectRest(auxiliary.deviceId, role: 'auxiliary');
      final repeat = await connectRest(auxiliary.deviceId, role: 'auxiliary');
      final body =
          jsonDecode(await first.readAsString()) as Map<String, dynamic>;
      final repeatBody =
          jsonDecode(await repeat.readAsString()) as Map<String, dynamic>;

      expect(first.statusCode, 200);
      expect(body['connectionRole'], 'auxiliary');
      expect(repeat.statusCode, 200);
      expect(repeatBody['outcome'], 'alreadyConnected');
      expect(
        manager.scaleController.currentConnectionState,
        ConnectionState.discovered,
      );
      expect(
        manager.auxiliaryScaleRegistry.connectedDeviceIds,
        contains(auxiliary.deviceId),
      );

      final listed =
          jsonDecode(await (await listRest()).readAsString()) as List<dynamic>;
      final entry =
          listed.singleWhere((value) => value['id'] == auxiliary.deviceId)
              as Map<String, dynamic>;
      expect(entry['connectionRole'], 'auxiliary');
    },
  );

  test(
    'invalid role is rejected before device lookup or transport work',
    () async {
      final response = await connectRest('does-not-exist', role: 42);

      expect(response.statusCode, 400);
      expect(
        jsonDecode(await response.readAsString())['error'],
        'Invalid connectionRole',
      );
    },
  );

  test('primary and auxiliary claims for one ID conflict', () async {
    final scale = TestScale(deviceId: 'claimed-scale');
    addTearDown(scale.dispose);
    discovery.addDevice(scale);
    await settle();

    expect((await connectRest(scale.deviceId)).statusCode, 200);
    final conflict = await connectRest(scale.deviceId, role: 'auxiliary');

    expect(conflict.statusCode, 409);
    expect(manager.auxiliaryScaleRegistry.connectedDeviceIds, isEmpty);
  });

  test('null role is rejected and unknown roles stay 400', () async {
    final scale = TestScale(deviceId: 'role-validation');
    addTearDown(scale.dispose);
    discovery.addDevice(scale);
    await settle();
    final explicitNull = await connectRestBody({
      'deviceId': scale.deviceId,
      'connectionRole': null,
    });
    final unknown = await connectRestBody({
      'deviceId': 'missing',
      'connectionRole': 'sideways',
    });
    expect(explicitNull.statusCode, 400);
    expect(unknown.statusCode, 400);
  });

  test('disconnecting an auxiliary removes its discovery role', () async {
    final scale = TestScale(deviceId: 'auxiliary-disconnect');
    addTearDown(scale.dispose);
    discovery.addDevice(scale);
    await settle();
    expect(
      (await connectRest(scale.deviceId, role: 'auxiliary')).statusCode,
      200,
    );

    final response = await disconnectRest(scale.deviceId);
    await settle();
    final listed =
        jsonDecode(await (await listRest()).readAsString()) as List<dynamic>;
    final entry =
        listed.singleWhere((value) => value['id'] == scale.deviceId)
            as Map<String, dynamic>;

    expect(response.statusCode, 200);
    expect(manager.auxiliaryScaleRegistry.connectedDeviceIds, isEmpty);
    expect(entry.containsKey('connectionRole'), isFalse);
  });

  test(
    'disconnecting an auxiliary after scanner removal removes it entirely',
    () async {
      final scale = TestScale(deviceId: 'auxiliary-vanished');
      addTearDown(scale.dispose);
      discovery.addDevice(scale);
      await settle();
      expect(
        (await connectRest(scale.deviceId, role: 'auxiliary')).statusCode,
        200,
      );
      discovery.removeDevice(scale.deviceId);
      await settle();
      expect((await disconnectRest(scale.deviceId)).statusCode, 200);
      await settle();
      final listed =
          jsonDecode(await (await listRest()).readAsString()) as List<dynamic>;
      expect(listed.where((value) => value['id'] == scale.deviceId), isEmpty);
    },
  );

  test(
    'REST disconnect cancels pending auxiliary connect after scanner removal',
    () async {
      final scale = _DelayedScale(deviceId: 'pending-rest-disconnect');
      addTearDown(scale.dispose);
      discovery.addDevice(scale);
      await settle();

      final connectFuture = connectRest(scale.deviceId, role: 'auxiliary');
      await settle();
      expect(manager.auxiliaryScaleRegistry.isReserved(scale.deviceId), isTrue);
      discovery.removeDevice(scale.deviceId);
      await settle();
      expect((await disconnectRest(scale.deviceId)).statusCode, 200);

      scale.releaseConnect();
      final connectResponse = await connectFuture;
      await settle();
      expect(connectResponse.statusCode, 409);
      expect(
        manager.auxiliaryScaleRegistry.isReserved(scale.deviceId),
        isFalse,
      );
      expect(manager.auxiliaryScaleRegistry.connectedDeviceIds, isEmpty);
      expect(scale.disconnectCalls, 1);
    },
  );

  test('auxiliary connect does not resolve a pending primary picker', () async {
    final first = TestScale(deviceId: 'picker-first');
    final second = TestScale(deviceId: 'picker-second');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    discovery.addDevice(first);
    discovery.addDevice(second);
    await settle();
    await manager.scanAndConnect();
    expect(manager.currentStatus.pendingAmbiguity, AmbiguityReason.scalePicker);
    final response = await connectRest(second.deviceId, role: 'auxiliary');
    expect(response.statusCode, 200);
    expect(manager.currentStatus.pendingAmbiguity, AmbiguityReason.scalePicker);
    expect(
      manager.auxiliaryScaleRegistry.connectedDeviceIds,
      contains(second.deviceId),
    );
    expect(
      manager.scaleController.currentConnectionState,
      ConnectionState.discovered,
    );
  });

  test(
    'devices websocket connects an auxiliary without selecting primary',
    () async {
      final scale = TestScale(deviceId: 'auxiliary-ws');
      addTearDown(scale.dispose);
      discovery.addDevice(scale);
      await settle();
      final channel = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${server.port}/ws/v1/devices'),
      );
      addTearDown(() => channel.sink.close());
      final frames = <Map<String, dynamic>>[];
      channel.stream.listen(
        (value) =>
            frames.add(jsonDecode(value.toString()) as Map<String, dynamic>),
      );
      await settle();
      channel.sink.add(
        jsonEncode({
          'command': 'connect',
          'deviceId': scale.deviceId,
          'connectionRole': 'auxiliary',
        }),
      );
      await settle();

      expect(
        manager.auxiliaryScaleRegistry.connectedDeviceIds,
        contains(scale.deviceId),
      );
      expect(
        manager.scaleController.currentConnectionState,
        ConnectionState.discovered,
      );
      expect(
        frames.any((frame) => frame['deviceId'] == scale.deviceId),
        isTrue,
      );
    },
  );

  test(
    'WS disconnect cancels pending auxiliary connect after scanner removal',
    () async {
      final scale = _DelayedScale(deviceId: 'pending-ws-disconnect');
      addTearDown(scale.dispose);
      discovery.addDevice(scale);
      await settle();

      final connectChannel = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${server.port}/ws/v1/devices'),
      );
      final disconnectChannel = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${server.port}/ws/v1/devices'),
      );
      addTearDown(() => connectChannel.sink.close());
      addTearDown(() => disconnectChannel.sink.close());
      connectChannel.sink.add(
        jsonEncode({
          'command': 'connect',
          'deviceId': scale.deviceId,
          'connectionRole': 'auxiliary',
        }),
      );
      await settle();
      expect(manager.auxiliaryScaleRegistry.isReserved(scale.deviceId), isTrue);
      discovery.removeDevice(scale.deviceId);
      await settle();
      disconnectChannel.sink.add(
        jsonEncode({'command': 'disconnect', 'deviceId': scale.deviceId}),
      );
      await settle();

      scale.releaseConnect();
      await settle();
      expect(
        manager.auxiliaryScaleRegistry.isReserved(scale.deviceId),
        isFalse,
      );
      expect(manager.auxiliaryScaleRegistry.connectedDeviceIds, isEmpty);
      expect(scale.disconnectCalls, 1);
    },
  );

  test('devices websocket rejects non-string and unknown roles', () async {
    final scale = TestScale(deviceId: 'ws-role-validation');
    addTearDown(scale.dispose);
    discovery.addDevice(scale);
    await settle();
    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${server.port}/ws/v1/devices'),
    );
    addTearDown(() => channel.sink.close());
    final errors = <Map<String, dynamic>>[];
    channel.stream.listen((value) {
      final frame = jsonDecode(value.toString()) as Map<String, dynamic>;
      if (frame['error'] != null) errors.add(frame);
    });
    await settle();
    for (final role in [null, 7, 'sideways', <String, dynamic>{}]) {
      channel.sink.add(
        jsonEncode({
          'command': 'connect',
          'deviceId': scale.deviceId,
          'connectionRole': role,
        }),
      );
      await settle();
    }
    expect(errors, hasLength(4));
    expect(
      errors.every((error) => error['error'] == 'Invalid connectionRole'),
      isTrue,
    );
    expect(manager.auxiliaryScaleRegistry.connectedDeviceIds, isEmpty);
    expect(
      manager.scaleController.currentConnectionState,
      ConnectionState.discovered,
    );
  });
}

class _DelayedScale extends TestScale {
  final Completer<void> _connectCompleted = Completer<void>();
  int disconnectCalls = 0;

  _DelayedScale({required super.deviceId});

  @override
  Future<void> onConnect() => _connectCompleted.future;

  void releaseConnect() {
    if (!_connectCompleted.isCompleted) _connectCompleted.complete();
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }
}
