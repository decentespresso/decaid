import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_attach_notifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/usb_attach_probe.dart';
import 'package:reaprime/src/services/serial/serial_service_android.dart';
import 'package:rxdart/subjects.dart';

// ignore: depend_on_referenced_packages
import 'package:usb_serial/usb_serial.dart';

UsbDevice _device({
  int? vid = 0x2E8A,
  int? pid = 0x000A,
  String? serial = '8549628789ABCDEF',
  String productName = 'DE1',
}) {
  return UsbDevice(
    '/dev/bus/usb/001/002',
    vid,
    pid,
    productName,
    'Decent Espresso',
    1002,
    serial,
    1,
  );
}

class _FakeMachine implements De1Interface {
  @override
  String get deviceId => 'usb-2e8a-a-8549628789ABCDEF';

  @override
  String get name => 'DE1';

  @override
  DeviceType get type => DeviceType.machine;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.serial;

  int onConnectCalls = 0;
  int disconnectCalls = 0;
  bool failConnect = false;

  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.connected);

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Stream<MachineSnapshot> get currentSnapshot => const Stream.empty();

  @override
  Stream<bool> get ready => const Stream.empty();

  @override
  Future<void> onConnect() async {
    onConnectCalls++;
    if (failConnect) throw Exception('simulated connect failure');
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeScale implements Device {
  @override
  String get deviceId => 'usb-2e8a-a-8549628789ABCDEF-scale';

  @override
  String get name => 'Half Decent Scale';

  @override
  DeviceType get type => DeviceType.scale;

  @override
  DeviceImplementation get implementation => DeviceImplementation.hdsSerial;

  @override
  TransportType get transportType => TransportType.serial;

  int disconnectCalls = 0;

  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);

  @override
  Future<void> onConnect() async {}

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeSensor implements Device {
  @override
  String get deviceId => 'usb-2e8a-a-8549628789ABCDEF-sensor';

  @override
  String get name => 'Sensor Basket';

  @override
  DeviceType get type => DeviceType.sensor;

  @override
  DeviceImplementation get implementation => DeviceImplementation.sensorBasket;

  @override
  TransportType get transportType => TransportType.serial;

  int disconnectCalls = 0;

  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);

  @override
  Future<void> onConnect() async {}

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late SerialServiceAndroid service;
  late List<UsbDevice> listed;
  late Future<Device?> Function(UsbDevice) detection;

  SerialServiceAndroid build() => SerialServiceAndroid(
    listDevices: () async => listed,
    usbEventStream: () => null,
    detectDevice: detection,
  );

  setUp(() {
    listed = [];
    detection = (_) async => null;
    service = build();
  });

  tearDown(() async {
    await service.dispose();
  });

  test('correlated attach connects the matching supported machine', () async {
    final machine = _FakeMachine();
    listed = [_device()];
    detection = (_) async => machine;
    service = build();

    final result = await service.connectAttachedMachine(
      const DeviceAttachedEvent(deviceId: 'usb-2e8a-a-8549628789ABCDEF'),
    );

    expect(result, isA<AttachProbeConnected>());
    expect((result as AttachProbeConnected).machine, same(machine));
    expect(machine.onConnectCalls, 1);
    expect(await service.devices.first, contains(machine));
  });

  test('attach id matching no listed device is unsupported', () async {
    listed = [_device()];
    detection = (_) async => fail('must not be probed');
    service = build();

    final result = await service.connectAttachedMachine(
      const DeviceAttachedEvent(deviceId: 'usb-ffff-ffff-OTHER'),
    );

    expect(result, isA<AttachProbeUnsupported>());
  });

  test('attach without id probes only devices not already known', () async {
    final machine = _FakeMachine();
    listed = [_device(), _device(serial: 'OTHER-SERIAL')];
    detection = (d) async => d.serial == '8549628789ABCDEF' ? machine : null;
    service = build();
    await service.scanForDevices();
    expect(await service.devices.first, contains(machine));

    final result = await service.connectAttachedMachine(
      const DeviceAttachedEvent(),
    );

    expect(result, isA<AttachProbeUnsupported>());
    expect(machine.onConnectCalls, 0);
  });

  test('duplicate attach for an already-known device is unsupported', () async {
    final machine = _FakeMachine();
    listed = [_device()];
    detection = (_) async => machine;
    service = build();
    await service.scanForDevices();
    expect(await service.devices.first, contains(machine));

    final result = await service.connectAttachedMachine(
      const DeviceAttachedEvent(deviceId: 'usb-2e8a-a-8549628789ABCDEF'),
    );

    expect(result, isA<AttachProbeUnsupported>());
    expect(machine.onConnectCalls, 0);
  });

  test(
    'unrelated USB device does not adopt an already-present serial machine',
    () async {
      final machine = _FakeMachine();
      listed = [_device()];
      detection = (_) async => machine;
      service = build();
      await service.scanForDevices();
      expect(await service.devices.first, contains(machine));

      var keyboardProbed = false;
      listed = [
        _device(),
        _device(
          vid: 0x046D,
          pid: 0xC31C,
          serial: 'kbd-1',
          productName: 'USB Keyboard',
        ),
      ];
      detection = (d) {
        if (d.productName == 'USB Keyboard') keyboardProbed = true;
        return Future.value(machine);
      };
      final result = await service.connectAttachedMachine(
        const DeviceAttachedEvent(
          deviceId: 'usb-46d-c31c-kbd-1',
          name: 'USB Keyboard',
        ),
      );

      expect(keyboardProbed, isFalse);
      expect(result, isA<AttachProbeUnsupported>());
      expect(machine.onConnectCalls, 0);
      expect(await service.devices.first, contains(machine));
    },
  );

  test('scale devices are rejected as attached machine candidates', () async {
    final scale = _FakeScale();
    listed = [_device()];
    detection = (_) async => scale;
    service = build();

    final result = await service.connectAttachedMachine(
      const DeviceAttachedEvent(deviceId: 'usb-2e8a-a-8549628789ABCDEF'),
    );

    expect(result, isA<AttachProbeUnsupported>());
    expect(scale.disconnectCalls, 1);
    expect(await service.devices.first, isEmpty);
  });

  test('sensor devices are rejected as attached machine candidates', () async {
    final sensor = _FakeSensor();
    listed = [_device()];
    detection = (_) async => sensor;
    service = build();

    final result = await service.connectAttachedMachine(
      const DeviceAttachedEvent(deviceId: 'usb-2e8a-a-8549628789ABCDEF'),
    );

    expect(result, isA<AttachProbeUnsupported>());
    expect(sensor.disconnectCalls, 1);
    expect(await service.devices.first, isEmpty);
  });

  test('machine whose connect fails reports failed and cleans up', () async {
    final machine = _FakeMachine()..failConnect = true;
    listed = [_device()];
    detection = (_) async => machine;
    service = build();

    final result = await service.connectAttachedMachine(
      const DeviceAttachedEvent(deviceId: 'usb-2e8a-a-8549628789ABCDEF'),
    );

    expect(result, isA<AttachProbeFailed>());
    expect((result as AttachProbeFailed).deviceId, machine.deviceId);
    expect(machine.disconnectCalls, 1);
    expect(await service.devices.first, isEmpty);
  });

  test('detection failure is unsupported and leaves no residue', () async {
    listed = [_device()];
    detection = (_) async => throw Exception('probe error');
    service = build();

    final result = await service.connectAttachedMachine(
      const DeviceAttachedEvent(deviceId: 'usb-2e8a-a-8549628789ABCDEF'),
    );

    expect(result, isA<AttachProbeUnsupported>());
    expect(await service.devices.first, isEmpty);
  });

  for (final order in ['de1-first', 'keyboard-first']) {
    test('generic startup hint with multiple devices ($order) still finds '
        'the supported machine', () async {
      final machine = _FakeMachine();
      final keyboard = _device(
        vid: 0x046D,
        pid: 0xC31C,
        serial: 'kbd-1',
        productName: 'USB Keyboard',
      );
      listed = order == 'de1-first'
          ? [_device(), keyboard]
          : [keyboard, _device()];
      detection = (d) async => d.productName == 'USB Keyboard' ? null : machine;
      service = build();

      final result = await service.connectAttachedMachine(
        const DeviceAttachedEvent(),
      );

      expect(result, isA<AttachProbeConnected>());
      expect((result as AttachProbeConnected).machine, same(machine));
      expect(machine.onConnectCalls, 1);
      expect(await service.devices.first, contains(machine));
    });
  }
}
