import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/auxiliary_scale_registry.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/data/shot_state_event.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:web_socket_channel/io.dart';
import 'package:rxdart/rxdart.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_scale.dart';

void main() {
  late DeviceController devices;
  late De1Controller de1;
  late SettingsController settings;
  late TestScale primary;
  late _SwappableScaleController scaleController;
  late AuxiliaryScaleRegistry registry;
  late HttpServer server;
  late Handler handler;

  setUp(() async {
    devices = DeviceController([MockDeviceDiscoveryService()]);
    await devices.initialize();
    de1 = De1Controller(controller: devices);
    final mockSettings = MockSettingsService();
    await mockSettings.setBlockTareDuringShot(true);
    settings = SettingsController(mockSettings);
    await settings.loadSettings();
    primary = TestScale(deviceId: 'primary/one');
    scaleController = _SwappableScaleController(primary);
    registry = AuxiliaryScaleRegistry();
    final app = Router().plus;
    ScaleHandler(
      controller: scaleController,
      de1Controller: de1,
      settingsController: settings,
      auxiliaryScaleRegistry: registry,
    ).addRoutes(app);
    handler = app.call;
    server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
    await registry.dispose();
    scaleController.dispose();
    primary.dispose();
    devices.dispose();
  });

  Future<Response> tare(String id) async => await handler(
    Request(
      'PUT',
      Uri.parse(
        'http://localhost/api/v1/scales/${Uri.encodeComponent(id)}/tare',
      ),
    ),
  );

  test(
    'addressed tare decodes an opaque id once and targets auxiliary only',
    () async {
      final auxiliary = TestScale(deviceId: 'aux/one%two');
      addTearDown(auxiliary.dispose);
      expect(
        (await registry.connect(
          auxiliary,
          isPrimaryClaimed: (_) => false,
        )).success,
        isTrue,
      );

      final response = await tare(auxiliary.deviceId);

      expect(response.statusCode, 200);
      expect(auxiliary.tareCallCount, 1);
      expect(primary.tareCallCount, 0);
    },
  );

  test(
    'primary tare remains blocked during a shot while auxiliary tare works',
    () async {
      final auxiliary = TestScale(deviceId: 'auxiliary');
      addTearDown(auxiliary.dispose);
      expect(
        (await registry.connect(
          auxiliary,
          isPrimaryClaimed: (_) => false,
        )).success,
        isTrue,
      );
      de1.publishShotEvent(
        ShotStateEvent(
          event: 'state',
          timestamp: DateTime.now(),
          state: ShotState.pouring,
        ),
      );
      final primaryResponse = await handler(
        Request('PUT', Uri.parse('http://localhost/api/v1/scale/tare')),
      );
      final auxiliaryResponse = await tare(auxiliary.deviceId);
      final addressedPrimaryResponse = await tare(primary.deviceId);

      expect(primaryResponse.statusCode, 400);
      expect(addressedPrimaryResponse.statusCode, 400);
      expect(auxiliaryResponse.statusCode, 200);
      expect(primary.tareCallCount, 0);
      expect(auxiliary.tareCallCount, 1);
    },
  );

  test(
    'addressed snapshots isolate two auxiliaries and sibling changes',
    () async {
      final first = TestScale(deviceId: 'aux/first');
      final second = TestScale(deviceId: 'aux/second');
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      expect(
        (await registry.connect(first, isPrimaryClaimed: (_) => false)).success,
        isTrue,
      );
      expect(
        (await registry.connect(
          second,
          isPrimaryClaimed: (_) => false,
        )).success,
        isTrue,
      );

      final firstChannel = _connect(server, first.deviceId);
      final secondChannel = _connect(server, second.deviceId);
      final firstFrames = <Map<String, dynamic>>[];
      final secondFrames = <Map<String, dynamic>>[];
      firstChannel.stream.listen(
        (value) => firstFrames.add(
          jsonDecode(value.toString()) as Map<String, dynamic>,
        ),
      );
      secondChannel.stream.listen(
        (value) => secondFrames.add(
          jsonDecode(value.toString()) as Map<String, dynamic>,
        ),
      );
      addTearDown(() async {
        await firstChannel.sink.close();
        await secondChannel.sink.close();
      });
      await _settle();
      firstFrames.clear();
      secondFrames.clear();

      first.emitSnapshot(_snapshot(11));
      second.emitSnapshot(_snapshot(22));
      await _settle();

      expect(firstFrames.map((frame) => frame['weight']), contains(11));
      expect(firstFrames.map((frame) => frame['weight']), isNot(contains(22)));
      expect(secondFrames.map((frame) => frame['weight']), contains(22));
      expect(secondFrames.map((frame) => frame['weight']), isNot(contains(11)));

      await registry.disconnect(second.deviceId);
      first.emitSnapshot(_snapshot(33));
      await _settle();
      expect(firstFrames.map((frame) => frame['weight']), contains(33));
    },
  );

  test('same-id auxiliary reconnect rebinds the existing websocket', () async {
    final first = TestScale(deviceId: 'aux/rebind');
    addTearDown(first.dispose);
    expect(
      (await registry.connect(first, isPrimaryClaimed: (_) => false)).success,
      isTrue,
    );
    final channel = _connect(server, first.deviceId);
    final frames = <Map<String, dynamic>>[];
    channel.stream.listen(
      (value) =>
          frames.add(jsonDecode(value.toString()) as Map<String, dynamic>),
    );
    addTearDown(() => channel.sink.close());
    await _settle();
    frames.clear();

    await registry.disconnect(first.deviceId);
    expect(
      (await registry.connect(first, isPrimaryClaimed: (_) => false)).success,
      isTrue,
    );
    await _settle();
    first.emitSnapshot(_snapshot(44));
    await _settle();

    expect(frames.map((frame) => frame['weight']), contains(44));
  });

  test(
    'closing an addressed websocket releases its session subscriptions',
    () async {
      final scale = TestScale(deviceId: 'aux/closed');
      addTearDown(scale.dispose);
      expect(
        (await registry.connect(scale, isPrimaryClaimed: (_) => false)).success,
        isTrue,
      );
      final channel = _connect(server, scale.deviceId);
      final frames = <Map<String, dynamic>>[];
      channel.stream.listen(
        (value) =>
            frames.add(jsonDecode(value.toString()) as Map<String, dynamic>),
      );
      await _settle();
      await channel.sink.close();
      await _settle();

      await registry.disconnect(scale.deviceId);
      final replacement = TestScale(deviceId: scale.deviceId);
      addTearDown(replacement.dispose);
      expect(
        (await registry.connect(
          replacement,
          isPrimaryClaimed: (_) => false,
        )).success,
        isTrue,
      );
      replacement.emitSnapshot(_snapshot(55));
      await _settle();

      expect(frames.map((frame) => frame['weight']), isNot(contains(55)));
    },
  );

  test(
    'primary addressed websocket ignores weights after a different-id swap',
    () async {
      final channel = _connect(server, primary.deviceId);
      final frames = <Map<String, dynamic>>[];
      channel.stream.listen(
        (value) =>
            frames.add(jsonDecode(value.toString()) as Map<String, dynamic>),
      );
      addTearDown(() => channel.sink.close());
      await _settle();
      frames.clear();
      scaleController.emitWeight(10);
      await _settle();
      final replacement = TestScale(deviceId: 'primary/two');
      addTearDown(replacement.dispose);
      scaleController.swap(replacement);
      await _settle();
      scaleController.emitWeight(20);
      await _settle();
      expect(frames.map((frame) => frame['weight']), contains(10));
      expect(frames.map((frame) => frame['weight']), isNot(contains(20)));
    },
  );

  test(
    'closing then disconnecting leaves no scale snapshot subscription',
    () async {
      final scale = _TrackingScale(deviceId: 'aux/tracked');
      addTearDown(scale.dispose);
      expect(
        (await registry.connect(scale, isPrimaryClaimed: (_) => false)).success,
        isTrue,
      );
      final channel = _connect(server, scale.deviceId);
      addTearDown(() => channel.sink.close());
      await _settle();
      expect(scale.listenCount, 1);
      await channel.sink.close();
      await registry.disconnect(scale.deviceId);
      expect(scale.cancelCount, 1);
    },
  );

  test(
    'addressed websocket follows a same-id auxiliary to primary transition',
    () async {
      final auxiliary = TestScale(deviceId: 'transition/id');
      addTearDown(auxiliary.dispose);
      expect(
        (await registry.connect(
          auxiliary,
          isPrimaryClaimed: (_) => false,
        )).success,
        isTrue,
      );
      final channel = _connect(server, auxiliary.deviceId);
      final frames = <Map<String, dynamic>>[];
      channel.stream.listen(
        (value) =>
            frames.add(jsonDecode(value.toString()) as Map<String, dynamic>),
      );
      addTearDown(() => channel.sink.close());
      await _settle();
      frames.clear();
      await registry.disconnect(auxiliary.deviceId);
      final primaryReplacement = TestScale(deviceId: auxiliary.deviceId);
      addTearDown(primaryReplacement.dispose);
      scaleController.swap(primaryReplacement);
      await _settle();
      scaleController.emitWeight(66);
      await _settle();
      expect(frames.map((frame) => frame['weight']), contains(66));
    },
  );

  test(
    'addressed websocket follows a same-id primary to auxiliary transition',
    () async {
      final primaryReplacement = TestScale(deviceId: 'transition/back');
      addTearDown(primaryReplacement.dispose);
      scaleController.swap(primaryReplacement);
      final channel = _connect(server, primaryReplacement.deviceId);
      final frames = <Map<String, dynamic>>[];
      channel.stream.listen(
        (value) =>
            frames.add(jsonDecode(value.toString()) as Map<String, dynamic>),
      );
      addTearDown(() => channel.sink.close());
      await _settle();
      frames.clear();
      scaleController.disconnectOnly();
      final auxiliary = TestScale(deviceId: primaryReplacement.deviceId);
      addTearDown(auxiliary.dispose);
      expect(
        (await registry.connect(
          auxiliary,
          isPrimaryClaimed: (_) => false,
        )).success,
        isTrue,
      );
      await _settle();
      auxiliary.emitSnapshot(_snapshot(77));
      await _settle();
      expect(frames.map((frame) => frame['weight']), contains(77));
    },
  );

  test('unknown addressed scale returns 404 without a tare', () async {
    final response = await tare('missing/scale');

    expect(response.statusCode, 404);
    expect(
      jsonDecode(await response.readAsString())['error'],
      contains('missing/scale'),
    );
    expect(primary.tareCallCount, 0);
  });
}

IOWebSocketChannel _connect(
  HttpServer server,
  String id,
) => IOWebSocketChannel.connect(
  Uri.parse(
    'ws://127.0.0.1:${server.port}/ws/v1/scales/${Uri.encodeComponent(id)}/snapshot',
  ),
);

ScaleSnapshot _snapshot(double weight) => ScaleSnapshot(
  timestamp: DateTime(2026, 1, 15, 8),
  weight: weight,
  batteryLevel: 80,
);

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 40));
}

class _SwappableScaleController extends ScaleController {
  TestScale _scale;
  final BehaviorSubject<ConnectionState> _state = BehaviorSubject.seeded(
    ConnectionState.connected,
  );
  final StreamController<WeightSnapshot> _weights =
      StreamController.broadcast();
  int _generation = 0;

  _SwappableScaleController(this._scale);

  @override
  Stream<ConnectionState> get connectionState => _state.stream;

  @override
  ConnectionState get currentConnectionState => _state.value;

  @override
  String get lastConnectedDeviceId => _scale.deviceId;

  @override
  int get connectionGeneration => _generation;

  @override
  Stream<WeightSnapshot> get weightSnapshot => _weights.stream;

  @override
  Scale connectedScale() => _scale;

  void emitWeight(double weight) {
    _weights.add(
      WeightSnapshot(
        timestamp: DateTime(2026, 1, 15, 8),
        weight: weight,
        weightFlow: 0,
      ),
    );
    _scale.emitSnapshot(_snapshot(weight));
  }

  void swap(TestScale scale) {
    _generation++;
    _state.add(ConnectionState.disconnected);
    _scale = scale;
    _state.add(ConnectionState.connected);
  }

  void disconnectOnly() => _state.add(ConnectionState.disconnected);

  @override
  void dispose() {
    _state.close();
    _weights.close();
    super.dispose();
  }
}

class _TrackingScale extends TestScale {
  late final StreamController<ScaleSnapshot> _snapshots =
      StreamController.broadcast(
        onListen: _trackListen,
        onCancel: _trackCancel,
      );
  int listenCount = 0;
  int cancelCount = 0;

  _TrackingScale({required super.deviceId});

  void _trackListen() => listenCount++;
  void _trackCancel() => cancelCount++;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _snapshots.stream;

  @override
  void emitSnapshot(ScaleSnapshot snapshot) => _snapshots.add(snapshot);

  @override
  void dispose() {
    _snapshots.close();
    super.dispose();
  }
}
