import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/grinder_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  late GrinderController controller;
  late HttpServer server;
  late HttpClient client;

  setUp(() async {
    controller = GrinderController();
    final router = Router().plus;
    GrinderHandler(controller: controller).addRoutes(router);
    server = await shelf_io.serve(router.call, '127.0.0.1', 0);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await controller.dispose();
    await server.close(force: true);
  });

  Future<(int, dynamic)> request(
    String method,
    String path, {
    Object? body,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  test('returns 503 when no grinder is connected', () async {
    final (infoStatus, _) = await request('GET', '/api/v1/grinder/info');
    final (stateStatus, _) = await request('GET', '/api/v1/grinder/state');

    expect(infoStatus, HttpStatus.serviceUnavailable);
    expect(stateStatus, HttpStatus.serviceUnavailable);
  });

  test('exposes runtime info, state, commands, and strict payloads', () async {
    final grinder = _TestGrinder('runtime-grinder');
    await controller.connectToGrinder(grinder);

    final (infoStatus, info) = await request('GET', '/api/v1/grinder/info');
    final (stateStatus, state) = await request('GET', '/api/v1/grinder/state');
    expect(infoStatus, HttpStatus.ok);
    expect(info, {
      'deviceId': 'runtime-grinder',
      'capabilities': ['startStop', 'grindSetting', 'rpmControl'],
    });
    expect(stateStatus, HttpStatus.ok);
    expect(state['state'], 'idle');
    expect(state, isNot(contains('vendor')));

    expect(
      (await request('PUT', '/api/v1/grinder/state/grinding')).$1,
      HttpStatus.ok,
    );
    expect(
      (await request(
        'PUT',
        '/api/v1/grinder/setting',
        body: {'setting': 12.3},
      )).$1,
      HttpStatus.badRequest,
    );
    expect(
      (await request('PUT', '/api/v1/grinder/rpm', body: {'rpm': 1200.5})).$1,
      HttpStatus.badRequest,
    );
    expect(
      (await request('PUT', '/api/v1/grinder/rpm', body: {'rpm': -1})).$1,
      HttpStatus.badRequest,
    );
    expect(
      (await request(
        'PUT',
        '/api/v1/grinder/setting',
        body: {'setting': '12.3'},
      )).$1,
      HttpStatus.ok,
    );
    expect(
      (await request('PUT', '/api/v1/grinder/rpm', body: {'rpm': 1200})).$1,
      HttpStatus.ok,
    );
    expect(
      (await request('PUT', '/api/v1/grinder/state/idle')).$1,
      HttpStatus.ok,
    );
    expect(grinder.operations, ['start', 'setting:12.3', 'rpm:1200', 'stop']);
  });

  test('websocket survives replacement and emits snapshots only', () async {
    final first = _TestGrinder('stable');
    await controller.connectToGrinder(first);
    final channel = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${server.port}/ws/v1/grinder/snapshot'),
    );
    final frames = <Map<String, dynamic>>[];
    final subscription = channel.stream.listen(
      (data) => frames.add(jsonDecode(data as String) as Map<String, dynamic>),
    );
    addTearDown(() async {
      await channel.sink.close();
      await subscription.cancel();
    });
    await channel.ready;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    first.emit(GrinderState.grinding);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final replacement = _TestGrinder('stable')..connect();
    await controller.adoptGrinder(replacement);
    replacement.emit(GrinderState.idle, rpm: 900);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(frames.map((frame) => frame['state']), ['grinding', 'idle']);
    expect(frames.every((frame) => frame.containsKey('timestamp')), isTrue);
    expect(frames.every((frame) => !frame.containsKey('status')), isTrue);
  });
}

class _TestGrinder implements GrinderDevice {
  _TestGrinder(this.deviceId);

  @override
  final String deviceId;
  final _connection = BehaviorSubject.seeded(ConnectionState.discovered);
  final _snapshots = PublishSubject<GrinderSnapshot>();
  final operations = <String>[];

  void connect() => _connection.add(ConnectionState.connected);

  void emit(GrinderState state, {String? setting, int? rpm}) => _snapshots.add(
    GrinderSnapshot(
      timestamp: DateTime.now().toUtc(),
      state: state,
      setting: setting,
      rpm: rpm,
    ),
  );

  @override
  Set<GrinderCapability> get capabilities => GrinderCapability.values.toSet();
  @override
  Stream<GrinderSnapshot> get currentSnapshot => _snapshots.stream;
  @override
  Stream<ConnectionState> get connectionState => _connection.stream;
  @override
  DeviceImplementation get implementation => DeviceImplementation.plugin;
  @override
  String get name => 'Test Grinder';
  @override
  TransportType get transportType => TransportType.unknown;
  @override
  DeviceType get type => DeviceType.grinder;

  @override
  Future<void> onConnect() async {
    connect();
    emit(GrinderState.idle);
  }

  @override
  Future<void> disconnect() async =>
      _connection.add(ConnectionState.disconnected);
  @override
  Future<void> start() async => operations.add('start');
  @override
  Future<void> stop() async => operations.add('stop');
  @override
  Future<void> setGrindSetting(String setting) async =>
      operations.add('setting:$setting');
  @override
  Future<void> setRpm(int rpm) async => operations.add('rpm:$rpm');
}
