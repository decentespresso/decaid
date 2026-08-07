import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/rxdart.dart';

class _TestDiscovery extends DeviceDiscoveryService {
  final BehaviorSubject<List<Device>> _subj = BehaviorSubject.seeded(const []);
  @override
  Stream<List<Device>> get devices => _subj.stream;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}
  void emit(List<Device> list) => _subj.add(list);
}

class _StubSensor implements Sensor {
  _StubSensor(this.deviceId, {this.label = ''});
  @override
  final String deviceId;
  final String label;
  @override
  String get name => 'StubSensor';
  @override
  DeviceType get type => DeviceType.sensor;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.unknown;
  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);
  @override
  Stream<Map<String, dynamic>> get data => const Stream.empty();
  @override
  SensorInfo get info => SensorInfo(
    name: name,
    vendor: 'test',
    dataChannels: const [],
    commands: const [],
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
  group('SensorController', () {
    late _TestDiscovery discovery;
    late DeviceController deviceController;
    late SensorController controller;

    setUp(() async {
      discovery = _TestDiscovery();
      deviceController = DeviceController([discovery]);
      await deviceController.initialize();
      controller = SensorController(controller: deviceController);
    });

    tearDown(() {
      controller.dispose();
    });

    test('bridge-registered sensor appears alone', () async {
      final probe = _StubSensor('probe-1', label: 'bridge');
      await controller.register(probe);
      expect(controller.sensors, contains('probe-1'));
      expect(controller.sensors['probe-1'], same(probe));
    });

    test('DeviceController-sourced sensor appears alone', () async {
      final sensor = _StubSensor('discovered-1', label: 'discovered');
      discovery.emit([sensor]);
      await Future<void>.delayed(Duration.zero);
      expect(controller.sensors, contains('discovered-1'));
    });

    test('bridge wins when same deviceId appears from both sources', () async {
      final discovered = _StubSensor('shared', label: 'discovered');
      final bridge = _StubSensor('shared', label: 'bridge');

      discovery.emit([discovered]);
      await Future<void>.delayed(Duration.zero);
      await controller.register(bridge);

      expect(
        controller.sensors['shared'],
        same(bridge),
        reason: 'bridge-registered instance should win the dedupe',
      );
    });

    test('unregister removes a bridge-registered sensor', () async {
      final probe = _StubSensor('probe-2', label: 'bridge');
      await controller.register(probe);
      expect(controller.sensors, contains('probe-2'));

      await controller.unregister('probe-2');
      expect(controller.sensors, isNot(contains('probe-2')));
    });

    test(
      'unregister does not touch DeviceController-sourced sensors',
      () async {
        final discovered = _StubSensor('keep-1');
        discovery.emit([discovered]);
        await Future<void>.delayed(Duration.zero);

        await controller.unregister('keep-1');
        expect(
          controller.sensors,
          contains('keep-1'),
          reason: 'unregister is a no-op on non-bridge entries',
        );
      },
    );
  });
}
