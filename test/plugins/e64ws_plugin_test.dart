import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/plugins/plugin_device_service.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

void main() {
  test(
    'E64 instances use independent sockets and read-only commands',
    () async {
      final first = await _E64Fixture.start('token-one', 'one');
      final second = await _E64Fixture.start('token-two', 'two');
      final service = PluginDeviceService();
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: service,
      );
      addTearDown(() async {
        await manager.dispose();
        await first.dispose();
        await second.dispose();
      });

      await manager.loadPlugin(
        id: 'e64ws.reaplugin',
        manifest: _manifest(),
        settings: {
          'InstancesJson': jsonEncode([
            {
              'id': 'one',
              'name': 'First E64',
              'scheme': 'ws',
              'host': '127.0.0.1',
              'port': first.port,
            },
            {
              'id': 'two',
              'name': 'Second E64',
              'scheme': 'ws',
              'host': '127.0.0.1',
              'port': second.port,
            },
          ]),
          'TokensJson': jsonEncode({'one': 'token-one', 'two': 'token-two'}),
        },
        jsCode: await _source(),
      );

      final devices = await service.devices.firstWhere(
        (devices) => devices.length == 2,
      );
      final sensors = devices.cast<Sensor>();
      await Future.wait(sensors.map((sensor) => sensor.onConnect()));
      expect(
        sensors.map((sensor) => sensor.connectionState),
        everyElement(isA<Stream<ConnectionState>>()),
      );
      for (final sensor in sensors) {
        await sensor.connectionState.firstWhere(
          (state) => state == ConnectionState.connected,
        );
      }

      final byId = {
        for (final sensor in sensors) sensor.deviceId.split(':').last: sensor,
      };
      final firstState = byId['one']!.data.first;
      final secondState = byId['two']!.data.first;
      final firstResult = await byId['one']!.execute('readState', null);
      final secondResult = await byId['two']!.execute('readState', null);
      expect(firstResult, {'grinder': 'one'});
      expect(secondResult, {'grinder': 'two'});
      expect(await firstState, {
        'state': {'grinder': 'one'},
      });
      expect(await secondState, {
        'state': {'grinder': 'two'},
      });

      expect(await byId['one']!.execute('readConfig', null), {
        'setting': 'one',
      });
      expect(await byId['one']!.execute('readMachineInfo', null), {
        'model': 'E64',
      });
      expect(await byId['one']!.execute('readLogMessages', null), {
        'messages': <String>['ok'],
      });
      await expectLater(
        byId['one']!.execute('motorStart', null),
        throwsA(isA<Exception>()),
      );

      expect(first.requestTypes, [
        'RequestDriverState',
        'RequestDriverConfig',
        'RequestNachineInfo',
        'RequestLogMessages',
      ]);
      expect(second.requestTypes, ['RequestDriverState']);
      expect(first.requestIds, [1, 2, 3, 4]);
      expect(second.requestIds, [1]);
      expect(first.openCount, 1);
      expect(second.openCount, 1);

      await first.closeConnection();
      await byId['one']!.connectionState.firstWhere(
        (state) => state == ConnectionState.disconnected,
      );
      await expectLater(
        byId['two']!.execute('readState', null),
        completion({'grinder': 'two'}),
      );
      await byId['one']!.onConnect();
      expect(first.openCount, 2);
      expect(await byId['one']!.execute('readState', null), {'grinder': 'one'});
    },
  );

  test(
    'eight E64 instances use the existing registration and transport limits',
    () async {
      final fixtures = [
        for (var index = 0; index < 8; index++)
          await _E64Fixture.start('token-$index', 'grinder-$index'),
      ];
      final service = PluginDeviceService();
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: service,
      );
      addTearDown(() async {
        await manager.dispose();
        for (final fixture in fixtures) {
          await fixture.dispose();
        }
      });
      await manager.loadPlugin(
        id: 'e64ws.reaplugin',
        manifest: _manifest(),
        settings: {
          'InstancesJson': jsonEncode([
            for (var index = 0; index < fixtures.length; index++)
              {
                'id': 'e64-$index',
                'name': 'E64 $index',
                'scheme': 'ws',
                'host': '127.0.0.1',
                'port': fixtures[index].port,
              },
          ]),
          'TokensJson': jsonEncode({
            for (var index = 0; index < fixtures.length; index++)
              'e64-$index': 'token-$index',
          }),
        },
        jsCode: await _source(),
      );
      final sensors = (await service.devices.firstWhere(
        (devices) => devices.length == 8,
      )).cast<Sensor>();
      await Future.wait(sensors.map((sensor) => sensor.onConnect()));
      for (final sensor in sensors) {
        await sensor.connectionState.firstWhere(
          (state) => state == ConnectionState.connected,
        );
      }
      expect(fixtures.map((fixture) => fixture.openCount), everyElement(1));
      expect(
        await Future.wait(
          sensors.map((sensor) => sensor.execute('readState', null)),
        ),
        [
          for (var index = 0; index < 8; index++) {'grinder': 'grinder-$index'},
        ],
      );
    },
  );

  test('invalid E64 configuration opens no socket', () async {
    final fixture = await _E64Fixture.start('token', 'one');
    final service = PluginDeviceService();
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: service,
    );
    addTearDown(() async {
      await manager.dispose();
      await fixture.dispose();
    });

    await expectLater(
      manager.loadPlugin(
        id: 'e64ws.reaplugin',
        manifest: _manifest(),
        settings: {
          'InstancesJson': jsonEncode([
            {
              'id': 'one',
              'name': 'One',
              'scheme': 'ws',
              'host': '127.0.0.1',
              'port': fixture.port,
            },
            {
              'id': 'one',
              'name': 'Duplicate',
              'scheme': 'http',
              'host': '127.0.0.1',
              'port': fixture.port,
            },
          ]),
          'TokensJson': jsonEncode({'one': 'token'}),
        },
        jsCode: await _source(),
      ),
      throwsA(anything),
    );
    expect(fixture.openCount, 0);
    expect(await service.devices.first, isEmpty);
  });

  test('the ninth E64 instance is rejected before registration', () async {
    final service = PluginDeviceService();
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: service,
    );
    addTearDown(manager.dispose);
    final entries = [
      for (var index = 0; index < 9; index++)
        {
          'id': 'e64-$index',
          'name': 'E64 $index',
          'scheme': 'ws',
          'host': '127.0.0.1',
          'port': 1,
        },
    ];
    await expectLater(
      manager.loadPlugin(
        id: 'e64ws.reaplugin',
        manifest: _manifest(),
        settings: {
          'InstancesJson': jsonEncode(entries),
          'TokensJson': jsonEncode({
            for (var index = 0; index < 9; index++) 'e64-$index': 'token',
          }),
        },
        jsCode: await _source(),
      ),
      throwsA(anything),
    );
    expect(await service.devices.first, isEmpty);
  });

  test('invalid host configuration opens no socket', () async {
    final service = PluginDeviceService();
    addTearDown(service.dispose);
    for (final host in [
      'machine:9997',
      '[.]',
      '::::',
      '[12345::1]',
      '192.0.2.1::',
    ]) {
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: service,
      );
      await expectLater(
        manager.loadPlugin(
          id: 'e64ws.reaplugin',
          manifest: _manifest(),
          settings: {
            'InstancesJson': jsonEncode([
              {
                'id': 'one',
                'name': 'One',
                'scheme': 'ws',
                'host': host,
                'port': 9997,
              },
            ]),
            'TokensJson': jsonEncode({'one': 'token'}),
          },
          jsCode: await _source(),
        ),
        throwsA(anything),
      );
      expect(await service.devices.first, isEmpty);
      await manager.dispose();
    }
  });

  test('valid compressed IPv6 configuration reaches registration', () async {
    final fixture = await _E64Fixture.start('token', 'one');
    final service = PluginDeviceService();
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: service,
    );
    addTearDown(() async {
      await manager.dispose();
      await fixture.dispose();
    });
    await manager.loadPlugin(
      id: 'e64ws.reaplugin',
      manifest: _manifest(),
      settings: {
        'InstancesJson': jsonEncode([
          {
            'id': 'one',
            'name': 'One',
            'scheme': 'ws',
            'host': '::1',
            'port': fixture.port,
          },
        ]),
        'TokensJson': jsonEncode({'one': 'token'}),
      },
      jsCode: await _source(),
    );
    expect(
      await service.devices.firstWhere((devices) => devices.length == 1),
      hasLength(1),
    );
    expect(fixture.openCount, 0);
  });

  test(
    'network failure returns a stable error without token material',
    () async {
      final fixture = await _E64Fixture.start('expected-secret', 'one');
      final service = PluginDeviceService();
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: service,
      );
      addTearDown(() async {
        await manager.dispose();
        await fixture.dispose();
      });
      await manager.loadPlugin(
        id: 'e64ws.reaplugin',
        manifest: _manifest(),
        settings: {
          'InstancesJson': jsonEncode([
            {
              'id': 'one',
              'name': 'One',
              'scheme': 'ws',
              'host': '127.0.0.1',
              'port': fixture.port,
            },
          ]),
          'TokensJson': jsonEncode({'one': 'sent-secret'}),
        },
        jsCode: await _source(),
      );
      final sensor =
          (await service.devices.firstWhere(
                (devices) => devices.length == 1,
              )).single
              as Sensor;
      await expectLater(
        sensor.onConnect(),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('E64 connection failed') &&
                !error.toString().contains('sent-secret') &&
                !error.toString().contains('expected-secret'),
          ),
        ),
      );
    },
  );

  test(
    'correlation requires the matching response type for its refId',
    () async {
      final fixture = await _E64Fixture.start('token', 'one')
        ..respond = false;
      final service = PluginDeviceService();
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: service,
      );
      addTearDown(() async {
        await manager.dispose();
        await fixture.dispose();
      });
      await manager.loadPlugin(
        id: 'e64ws.reaplugin',
        manifest: _manifest(),
        settings: {
          'InstancesJson': jsonEncode([
            {
              'id': 'one',
              'name': 'One',
              'scheme': 'ws',
              'host': '127.0.0.1',
              'port': fixture.port,
            },
          ]),
          'TokensJson': jsonEncode({'one': 'token'}),
        },
        jsCode: await _source(),
      );
      final sensor =
          (await service.devices.firstWhere(
                (devices) => devices.length == 1,
              )).single
              as Sensor;
      await sensor.onConnect();
      final state = sensor.execute('readState', null);
      final config = sensor.execute('readConfig', null);
      await _waitFor(() => fixture.pending.length == 2);
      fixture.sendRaw(0, {'pong': true});
      fixture.sendRaw(0, {
        'type': 'RequestDriverStateResult',
        'refId': 999,
        'data': {'grinder': 'late'},
      });
      fixture.respondTo(1, 'RequestDriverStateResult', remove: false);
      await expectLater(config, throwsA(isA<Exception>()));
      fixture.respondTo(0, 'RequestDriverStateResult');
      expect(await state, {'grinder': 'one'});
    },
  );

  test('each instance bounds pending requests before sending', () async {
    final fixture = await _E64Fixture.start('token', 'one')
      ..respond = false;
    final service = PluginDeviceService();
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: service,
      deviceInvocationTimeout: const Duration(seconds: 1),
    );
    addTearDown(() async {
      await manager.dispose();
      await fixture.dispose();
    });
    await manager.loadPlugin(
      id: 'e64ws.reaplugin',
      manifest: _manifest(),
      settings: {
        'InstancesJson': jsonEncode([
          {
            'id': 'one',
            'name': 'One',
            'scheme': 'ws',
            'host': '127.0.0.1',
            'port': fixture.port,
          },
        ]),
        'TokensJson': jsonEncode({'one': 'token'}),
      },
      jsCode: await _source(),
    );
    final sensor =
        (await service.devices.firstWhere(
              (devices) => devices.length == 1,
            )).single
            as Sensor;
    await sensor.onConnect();
    final pending = List.generate(
      32,
      (_) => sensor
          .execute('readConfig', null)
          .then<void>((_) {}, onError: (_) {}),
    );
    await _waitFor(() => fixture.pending.length == 32);
    await expectLater(
      sensor.execute('readConfig', null),
      throwsA(isA<Exception>()),
    );
    expect(fixture.requestTypes.length, 32);
    await manager.dispose();
    await Future.wait(pending);
  });

  test('polling does not overlap and is cancelled on disconnect', () async {
    final fixture = await _E64Fixture.start('token', 'one')
      ..respond = false;
    final service = PluginDeviceService();
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: service,
    );
    addTearDown(() async {
      await manager.dispose();
      await fixture.dispose();
    });
    await manager.loadPlugin(
      id: 'e64ws.reaplugin',
      manifest: _manifest(),
      settings: {
        'InstancesJson': jsonEncode([
          {
            'id': 'one',
            'name': 'One',
            'scheme': 'ws',
            'host': '127.0.0.1',
            'port': fixture.port,
            'pollMs': 100,
          },
        ]),
        'TokensJson': jsonEncode({'one': 'token'}),
      },
      jsCode: await _source(),
    );
    final sensor =
        (await service.devices.firstWhere(
              (devices) => devices.length == 1,
            )).single
            as Sensor;
    await sensor.onConnect();
    await _waitFor(() => fixture.requestTypes.length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(fixture.requestTypes, ['RequestDriverState']);
    await sensor.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(fixture.requestTypes, ['RequestDriverState']);
  });

  test(
    'disconnect rejects pending reads before a new session can publish',
    () async {
      final fixture = await _E64Fixture.start('token', 'one')
        ..respond = false;
      final service = PluginDeviceService();
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        deviceService: service,
      );
      addTearDown(() async {
        await manager.dispose();
        await fixture.dispose();
      });
      await manager.loadPlugin(
        id: 'e64ws.reaplugin',
        manifest: _manifest(),
        settings: {
          'InstancesJson': jsonEncode([
            {
              'id': 'one',
              'name': 'One',
              'scheme': 'ws',
              'host': '127.0.0.1',
              'port': fixture.port,
            },
          ]),
          'TokensJson': jsonEncode({'one': 'token'}),
        },
        jsCode: await _source(),
      );
      final sensor =
          (await service.devices.firstWhere(
                (devices) => devices.length == 1,
              )).single
              as Sensor;
      await sensor.onConnect();
      final oldRead = sensor.execute('readState', null);
      await _waitFor(() => fixture.pending.length == 1);
      await fixture.closeConnection();
      await expectLater(oldRead, throwsA(isA<Exception>()));
      await sensor.connectionState.firstWhere(
        (state) => state == ConnectionState.disconnected,
      );
      fixture.respond = true;
      await sensor.onConnect();
      expect(await sensor.execute('readState', null), {'grinder': 'one'});
      expect(fixture.openCount, 2);
    },
  );

  test('plugin request timeout precedes the host invocation timeout', () async {
    final fixture = await _E64Fixture.start('token', 'one')
      ..respond = false;
    final service = PluginDeviceService();
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      deviceService: service,
      deviceInvocationTimeout: const Duration(seconds: 6),
    );
    addTearDown(() async {
      await manager.dispose();
      await fixture.dispose();
    });
    await manager.loadPlugin(
      id: 'e64ws.reaplugin',
      manifest: _manifest(),
      settings: {
        'InstancesJson': jsonEncode([
          {
            'id': 'one',
            'name': 'One',
            'scheme': 'ws',
            'host': '127.0.0.1',
            'port': fixture.port,
          },
        ]),
        'TokensJson': jsonEncode({'one': 'token'}),
      },
      jsCode: await _source(),
    );
    final sensor =
        (await service.devices.firstWhere(
              (devices) => devices.length == 1,
            )).single
            as Sensor;
    await sensor.onConnect();
    await expectLater(
      sensor.execute('readConfig', null),
      throwsA(
        predicate(
          (error) => error.toString().contains('E64 request timed out'),
        ),
      ),
    );
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

PluginManifest _manifest() => PluginManifest.fromJson({
  'id': 'e64ws.reaplugin',
  'name': 'E64 WebSocket Sensor',
  'author': 'Decaid contributors',
  'description': 'Opt-in E64 telemetry sensor.',
  'version': '0.1.0',
  'apiVersion': 1,
  'permissions': ['network.websocket'],
  'drivers': [
    {'id': 'e64ws', 'type': 'sensor'},
  ],
  'settings': {
    'InstancesJson': {'type': 'string'},
    'TokensJson': {'type': 'string', 'secure': true},
  },
  'api': [],
});

Future<String> _source() =>
    File('examples/plugins/e64ws.reaplugin/plugin.js').readAsString();

class _E64Fixture {
  static const resultTypes = {
    'RequestDriverState': 'RequestDriverStateResult',
    'RequestDriverConfig': 'RequestDriverConfigResult',
    'RequestNachineInfo': 'RequestNachineInfoResult',
    'RequestLogMessages': 'RequestLogMessagesResult',
  };

  _E64Fixture(this.server, this.token, this.name);

  final HttpServer server;
  final String token;
  final String name;
  final List<WebSocket> sockets = [];
  final List<String> requestTypes = [];
  final List<int> requestIds = [];
  final List<({WebSocket socket, Map<String, dynamic> request})> pending = [];
  bool respond = true;
  int openCount = 0;

  int get port => server.port;

  static Future<_E64Fixture> start(String token, String name) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _E64Fixture(server, token, name);
    server.listen(fixture._handle);
    return fixture;
  }

  Future<void> _handle(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request) ||
        request.uri.queryParameters['token'] != token) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    openCount++;
    socket.listen((message) {
      final request = jsonDecode(message as String) as Map<String, dynamic>;
      final type = request['type'] as String;
      requestTypes.add(type);
      requestIds.add(request['msgId'] as int);
      if (!respond) {
        pending.add((socket: socket, request: request));
        return;
      }
      _respond(socket, request, resultTypes[type]!);
    });
  }

  void _respond(WebSocket socket, Map<String, dynamic> request, String type) {
    final requestType = request['type'] as String;
    final data = switch (requestType) {
      'RequestDriverState' => {'grinder': name},
      'RequestDriverConfig' => {'setting': name},
      'RequestNachineInfo' => {'model': 'E64'},
      'RequestLogMessages' => {
        'messages': ['ok'],
      },
      _ => null,
    };
    if (data != null) {
      socket.add(
        jsonEncode({'type': type, 'refId': request['msgId'], 'data': data}),
      );
    }
  }

  void respondTo(int index, String type, {bool remove = true}) {
    final request = pending[index];
    if (remove) pending.removeAt(index);
    _respond(request.socket, request.request, type);
  }

  void sendRaw(int socketIndex, Map<String, dynamic> message) {
    sockets[socketIndex].add(jsonEncode(message));
  }

  Future<void> dispose() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }

  Future<void> closeConnection() => sockets.first.close();
}
