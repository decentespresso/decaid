import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:web_socket_channel/io.dart';

import '../helpers/mock_device_discovery_service.dart';

class _StreamingSensor implements Sensor {
  _StreamingSensor(this.deviceId) {
    _data = StreamController<Map<String, dynamic>>.broadcast(
      onListen: () => listenCount++,
      onCancel: () => cancelCount++,
    );
  }

  @override
  final String deviceId;

  late final StreamController<Map<String, dynamic>> _data;
  int listenCount = 0;
  int cancelCount = 0;

  bool get hasListener => _data.hasListener;

  void emit(String value) => _data.add({'value': value});

  Future<void> dispose() => _data.close();

  @override
  String get name => 'Streaming Sensor';

  @override
  DeviceType get type => DeviceType.sensor;

  @override
  DeviceImplementation get implementation => DeviceImplementation.sensorBasket;

  @override
  TransportType get transportType => TransportType.unknown;

  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);

  @override
  Stream<Map<String, dynamic>> get data => _data.stream;

  @override
  SensorInfo get info => SensorInfo(
    name: 'Streaming Sensor',
    vendor: 'test',
    dataChannels: [],
    commands: [],
  );

  @override
  Future<Map<String, dynamic>> execute(
    String commandId,
    Map<String, dynamic>? parameters,
  ) async => const {};

  @override
  Future<void> onConnect() async {}

  @override
  Future<void> disconnect() async {}
}

void main() {
  late SensorController sensorController;
  late MockDeviceDiscoveryService discovery;
  late HttpServer server;
  final sensors = <_StreamingSensor>[];

  setUp(() async {
    discovery = MockDeviceDiscoveryService();
    final deviceController = DeviceController([discovery]);
    await deviceController.initialize();
    sensorController = SensorController(controller: deviceController);

    final app = Router().plus;
    SensorsHandler(controller: sensorController).addRoutes(app);
    server = await io.serve(app.call, 'localhost', 0);
  });

  tearDown(() async {
    await server.close(force: true);
    sensorController.dispose();
    await Future.wait(sensors.map((sensor) => sensor.dispose()));
    sensors.clear();
  });

  _StreamingSensor sensor(String id) {
    final value = _StreamingSensor(id);
    sensors.add(value);
    return value;
  }

  Future<void> settle([int turns = 6]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  (IOWebSocketChannel, List<Map<String, dynamic>>) connect(String id) {
    final uri = Uri.parse(
      'ws://localhost:${server.port}/ws/v1/sensors/$id/snapshot',
    );
    final channel = IOWebSocketChannel.connect(uri);
    final received = <Map<String, dynamic>>[];
    channel.stream.listen(
      (message) =>
          received.add(jsonDecode(message.toString()) as Map<String, dynamic>),
    );
    return (channel, received);
  }

  test('rebinds to a replacement sensor with the same id', () async {
    final first = sensor('probe-1');
    await sensorController.register(first);
    final (channel, received) = connect(first.deviceId);
    await settle();

    final replacement = sensor(first.deviceId);
    await sensorController.register(replacement);
    await settle();

    received.clear();
    first.emit('old');
    replacement.emit('new');
    await settle();

    expect(received, [
      const {'value': 'new'},
    ]);
    expect(first.hasListener, isFalse);
    expect(replacement.listenCount, 1);
    await channel.sink.close();
  });

  test('stays open across removal and re-add of the requested id', () async {
    final first = sensor('probe-2');
    discovery.addDevice(first);
    await settle();
    final (channel, received) = connect(first.deviceId);
    await settle();

    discovery.removeDevice(first.deviceId);
    await settle();
    expect(first.hasListener, isFalse);

    final replacement = sensor(first.deviceId);
    discovery.addDevice(replacement);
    await settle();
    replacement.emit('restored');
    await settle();

    expect(received.map((frame) => frame['value']), contains('restored'));
    await channel.sink.close();
  });

  test('ignores unrelated registry changes', () async {
    final requested = sensor('probe-3');
    await sensorController.register(requested);
    final (channel, received) = connect(requested.deviceId);
    await settle();

    await sensorController.register(sensor('other'));
    await settle();
    requested.emit('once');
    await settle();

    expect(requested.listenCount, 1);
    expect(requested.cancelCount, 0);
    expect(received, [
      const {'value': 'once'},
    ]);
    await channel.sink.close();
  });

  test(
    'releases data and registry subscriptions when the socket closes',
    () async {
      final first = sensor('probe-4');
      await sensorController.register(first);
      final (channel, _) = connect(first.deviceId);
      await settle();

      await channel.sink.close();
      await settle();
      expect(first.hasListener, isFalse);

      final replacement = sensor(first.deviceId);
      await sensorController.register(replacement);
      await settle();
      expect(replacement.listenCount, 0);
    },
  );

  test('preserves the initial not-found response', () async {
    final uri = Uri.parse(
      'ws://localhost:${server.port}/ws/v1/sensors/missing/snapshot',
    );
    final channel = IOWebSocketChannel.connect(uri);

    expect(
      await channel.stream.first.timeout(const Duration(seconds: 2)),
      jsonEncode({'error': 'not found'}),
    );
  });
}
