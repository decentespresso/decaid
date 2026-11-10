import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_attach_notifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/usb_attach_probe.dart';
import 'package:reaprime/src/services/serial/serial_service_android.dart';
import 'package:reaprime/src/services/serial/utils.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:rxdart/subjects.dart';

// ignore: depend_on_referenced_packages
import 'package:usb_serial/usb_serial.dart';

UsbDevice _device({
  int? vid = 0x2E8A,
  int? pid = 0x000A,
  String? serial = '8549628789ABCDEF',
  String productName = 'DE1',
  int? physicalId = 1002,
}) {
  return UsbDevice(
    '/dev/bus/usb/001/002',
    vid,
    pid,
    productName,
    'Decent Espresso',
    physicalId,
    serial,
    1,
  );
}

class _FakeMachine implements De1Interface {
  _FakeMachine({this.id = 'usb-2e8a-a-8549628789ABCDEF'});

  final String id;

  @override
  String get deviceId => id;

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
  Completer<void>? connectGate;

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
    final gate = connectGate;
    if (gate != null) await gate.future;
    if (failConnect) throw Exception('simulated connect failure');
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  void setConnectionState(ConnectionState state) => _connectionState.add(state);

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeScale implements Device {
  _FakeScale({String? id}) : _id = id ?? 'usb-2e8a-a-8549628789ABCDEF-scale';

  final String _id;

  int disconnectCalls = 0;

  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.connected);

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  void setConnectionState(ConnectionState state) => _connectionState.add(state);

  @override
  String get deviceId => _id;

  @override
  String get name => 'Half Decent Scale';

  @override
  DeviceType get type => DeviceType.scale;

  @override
  DeviceImplementation get implementation => DeviceImplementation.hdsSerial;

  @override
  TransportType get transportType => TransportType.serial;

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

  test('unrelated physical detach does not cancel pending attach', () async {
    final machine = _FakeMachine();
    final detectionStarted = Completer<void>();
    machine.connectGate = Completer<void>();
    final de1 = _device(physicalId: 1002);
    final unrelated = _device(
      vid: 0x046D,
      pid: 0xC31C,
      serial: 'kbd-1',
      productName: 'USB Keyboard',
      physicalId: 1003,
    );
    listed = [de1, unrelated];
    detection = (device) async {
      if (device.deviceId == de1.deviceId) {
        detectionStarted.complete();
        return machine;
      }
      return null;
    };
    service = build();

    final attaching = service.connectAttachedMachine(
      const DeviceAttachedEvent(physicalDeviceId: 1002),
    );
    await detectionStarted.future;
    final detached = service.handleUsbEvent(
      UsbEvent()
        ..event = UsbEvent.ACTION_USB_DETACHED
        ..device = unrelated,
    );
    machine.connectGate!.complete();
    await detached;

    expect(await attaching, isA<AttachProbeConnected>());
    expect(await service.devices.first, [same(machine)]);
  });

  test(
    'own physical detach cancels pending attach and disconnects machine',
    () async {
      final machine = _FakeMachine();
      final detectionStarted = Completer<void>();
      machine.connectGate = Completer<void>();
      final device = _device(physicalId: 1002);
      listed = [device];
      detection = (_) async {
        detectionStarted.complete();
        return machine;
      };
      service = build();

      final attaching = service.connectAttachedMachine(
        const DeviceAttachedEvent(physicalDeviceId: 1002),
      );
      await detectionStarted.future;
      final detached = service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_DETACHED
          ..device = device,
      );
      machine.connectGate!.complete();

      await detached;
      expect(await attaching, isA<AttachProbeUnsupported>());
      expect(machine.disconnectCalls, 1);
      expect(await service.devices.first, isEmpty);
    },
  );

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

  test(
    'incomplete detach removes session-only machine after fresh enumeration',
    () async {
      final machine = _FakeMachine(id: 'usb-2e8a-a-unknown-1002');
      final device = _device(serial: null, physicalId: 1002);
      listed = [device];
      detection = (_) async => machine;
      service = build();

      await service.scanForDevices();
      listed = [];
      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_DETACHED
          ..device = _device(serial: null, physicalId: null),
      );

      expect(machine.disconnectCalls, 1);
      expect(await service.devices.first, isEmpty);
    },
  );

  test('incomplete canonical detach removes session-only machine', () async {
    final machine = _FakeMachine(id: 'usb-2e8a-a-unknown-1002');
    final device = _device(serial: null, physicalId: 1002);
    listed = [device];
    detection = (_) async => machine;
    service = build();

    await service.scanForDevices();
    listed = [];
    await service.handleUsbEvent(
      UsbEvent()
        ..event = UsbEvent.ACTION_USB_DETACHED
        ..device = _device(serial: 'CANONICAL', physicalId: null),
    );

    expect(machine.disconnectCalls, 1);
    expect(await service.devices.first, isEmpty);
  });

  test(
    'incomplete detach tombstone blocks a later stale enumeration',
    () async {
      final device = _device(serial: 'KNOWN');
      final machine = _FakeMachine(id: 'usb-2e8a-a-KNOWN');
      listed = [device];
      detection = (_) async => machine;
      service = build();

      await service.scanForDevices();
      listed = [];
      await service.handleUsbEvent(
        UsbEvent()..event = UsbEvent.ACTION_USB_DETACHED,
      );
      expect(await service.devices.first, isEmpty);

      listed = [device];
      await service.scanForDevices();
      expect(await service.devices.first, isEmpty);
      expect(machine.disconnectCalls, 1);
    },
  );

  test('incomplete detach preserves an identical USB survivor', () async {
    final first = _device(serial: null, physicalId: 1002);
    final second = _device(serial: null, physicalId: 1003);
    final firstMachine = _FakeMachine(id: 'usb-2e8a-a-unknown-1002');
    final secondMachine = _FakeMachine(id: 'usb-2e8a-a-unknown-1003');
    listed = [first, second];
    detection = (device) async =>
        device.deviceId == first.deviceId ? firstMachine : secondMachine;
    service = build();

    await service.scanForDevices();
    listed = [second];
    await service.handleUsbEvent(
      UsbEvent()
        ..event = UsbEvent.ACTION_USB_DETACHED
        ..device = _device(serial: null, physicalId: null),
    );

    expect(firstMachine.disconnectCalls, 1);
    expect(secondMachine.disconnectCalls, 0);
    expect(await service.devices.first, [same(secondMachine)]);
  });

  test(
    'same physical attachment coalesces absent and present descriptors',
    () async {
      final unknown = _device(serial: null);
      final canonical = _device(serial: 'LATE-SERIAL');
      final fallbackId = computeUsbAttachmentId(
        vid: unknown.vid,
        pid: unknown.pid,
        physicalId: unknown.deviceId,
      )!;
      final canonicalId = computeUsbAttachmentId(
        vid: canonical.vid,
        pid: canonical.pid,
        serial: canonical.serial,
        physicalId: canonical.deviceId,
      )!;
      var detections = 0;
      listed = [unknown];
      detection = (_) async {
        detections++;
        return _FakeMachine(id: detections == 1 ? fallbackId : canonicalId);
      };
      service = build();

      await service.scanForDevices();
      expect((await service.devices.first).single.deviceId, fallbackId);
      listed = [canonical];
      await service.scanForDevices();
      expect(detections, 1);
      expect((await service.devices.first).single.deviceId, fallbackId);

      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_DETACHED
          ..device = unknown,
      );
      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_ATTACHED
          ..device = canonical,
      );
      await service.scanForDevices();
      expect(detections, 2);
      expect((await service.devices.first).single.deviceId, canonicalId);
    },
  );

  test('two same-VID/PID devices without serial remain distinct', () async {
    final first = _device(serial: null);
    final second = _device(serial: null);
    final devices = [
      first,
      UsbDevice(
        '/dev/bus/usb/001/003',
        second.vid,
        second.pid,
        second.productName,
        second.manufacturerName,
        8,
        null,
        second.interfaceCount,
      ),
    ];
    listed = devices;
    detection = (d) async => _FakeMachine(
      id: computeUsbAttachmentId(
        vid: d.vid,
        pid: d.pid,
        serial: d.serial,
        physicalId: d.deviceId,
      )!,
    );
    service = build();

    await service.scanForDevices();

    expect((await service.devices.first).map((d) => d.deviceId).toSet(), {
      'usb-2e8a-a-unknown-1002',
      'usb-2e8a-a-unknown-8',
    });
  });

  test(
    'detach during attach cannot republish after replug generation changes',
    () async {
      final device = _device(serial: null);
      final machine = _FakeMachine(id: 'usb-2e8a-a-unknown-1002');
      machine.connectGate = Completer<void>();
      listed = [device];
      detection = (_) async => machine;
      service = build();

      final attaching = service.connectAttachedMachine(
        DeviceAttachedEvent(
          physicalDeviceId: device.deviceId,
          deviceId: 'usb-2e8a-a-unknown-1002',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final detached = service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_DETACHED
          ..device = device,
      );
      machine.connectGate!.complete();
      await detached;

      expect(await attaching, isA<AttachProbeUnsupported>());
      expect(await service.devices.first, isEmpty);

      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_ATTACHED
          ..device = device,
      );
      final replugged = await service.connectAttachedMachine(
        DeviceAttachedEvent(
          physicalDeviceId: device.deviceId,
          deviceId: 'usb-2e8a-a-unknown-1002',
        ),
      );
      expect(replugged, isA<AttachProbeConnected>());
      expect((await service.devices.first).single, same(machine));
    },
  );

  test(
    'a serial-less scale re-enumerated with a readable serial is not re-admitted',
    () async {
      final scale = _FakeScale(id: 'usb-2e8a-a-unknown-7');
      var detections = 0;
      listed = [_device(serial: null, physicalId: 7)];
      detection = (_) async {
        detections++;
        return scale;
      };
      service = build();

      await service.scanForDevices();
      expect(await service.devices.first, [same(scale)]);
      expect(detections, 1);

      listed = [_device(serial: 'SCALE123', physicalId: 7)];
      await service.scanForDevices();

      expect(
        detections,
        1,
        reason: 'the scale still owns this physical attachment',
      );
      expect(await service.devices.first, [same(scale)]);
      expect(scale.disconnectCalls, 0);
    },
  );

  test(
    'quick-connect reuses a connected serial-less scale instead of opening a port',
    () async {
      final scale = _FakeScale(id: 'usb-2e8a-a-unknown-7');
      var detections = 0;
      listed = [_device(serial: null, physicalId: 7)];
      detection = (_) async {
        detections++;
        return scale;
      };
      service = build();
      await service.scanForDevices();

      listed = [_device(serial: 'SCALE123', physicalId: 7)];
      final reused = await service.tryQuickConnect(
        const RememberedDevice(
          id: 'usb-2e8a-a-SCALE123',
          name: 'Half Decent Scale',
          type: DeviceType.scale,
          implementation: DeviceImplementation.hdsSerial,
          transportType: TransportType.serial,
        ),
      );

      expect(reused, same(scale));
      expect(detections, 1);
      expect(await service.devices.first, [same(scale)]);
      expect(scale.disconnectCalls, 0);
    },
  );

  test(
    'a disconnected serial-less scale adopts its canonical serial on redetection',
    () async {
      final session = _FakeScale(id: 'usb-2e8a-a-unknown-7');
      final canonical = _FakeScale(id: 'usb-2e8a-a-SCALE123');
      Device? detected = session;
      listed = [_device(serial: null, physicalId: 7)];
      detection = (_) async => detected;
      service = build();
      await service.scanForDevices();
      expect(await service.devices.first, [same(session)]);

      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_DETACHED
          ..device = _device(serial: null, physicalId: 7),
      );
      expect(await service.devices.first, isEmpty);
      expect(session.disconnectCalls, 1);

      final replugged = _device(serial: 'SCALE123', physicalId: 7);
      listed = [replugged];
      detected = canonical;
      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_ATTACHED
          ..device = replugged,
      );
      await service.scanForDevices();

      expect(await service.devices.first, [same(canonical)]);
    },
  );

  test(
    'a scan ignores a detached attachment still present in enumeration',
    () async {
      final device = _device();
      final machine = _FakeMachine();
      var detections = 0;
      listed = [device];
      detection = (_) async {
        detections++;
        return machine;
      };
      service = build();

      await service.scanForDevices();
      expect(await service.devices.first, contains(machine));
      expect(detections, 1);

      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_DETACHED
          ..device = device,
      );
      expect(await service.devices.first, isEmpty);

      await service.scanForDevices();

      expect(
        await service.devices.first,
        isEmpty,
        reason:
            'a stale enumeration entry must not republish a detached machine',
      );
      expect(detections, 1, reason: 'a tombstoned attachment is not probed');

      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_ATTACHED
          ..device = device,
      );
      await service.scanForDevices();
      expect(await service.devices.first, contains(machine));
    },
  );

  test('concurrent attach and scan share detection and connect once', () async {
    final device = _device(serial: null);
    final detectionResult = Completer<Device?>();
    final machine = _FakeMachine(id: 'usb-2e8a-a-unknown-1002')
      ..setConnectionState(ConnectionState.discovered);
    var detections = 0;
    listed = [device];
    detection = (_) {
      detections++;
      return detectionResult.future;
    };
    service = build();

    final scan = service.scanForDevices();
    final attach = service.connectAttachedMachine(
      DeviceAttachedEvent(
        physicalDeviceId: device.deviceId,
        deviceId: 'usb-2e8a-a-unknown-1002',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    detectionResult.complete(machine);

    final result = await attach;
    await scan;
    expect(result, isA<AttachProbeConnected>());
    expect(detections, 1);
    expect(machine.onConnectCalls, 1);
    expect(
      (await service.devices.first).where((d) => identical(d, machine)),
      hasLength(1),
    );
  });

  test(
    'scan publication filters a detached result but keeps its survivor',
    () async {
      final first = _device(physicalId: 1002);
      final second = _device(physicalId: 1003, serial: 'SECOND');
      final firstMachine = _FakeMachine(id: 'usb-2e8a-a-FIRST');
      final secondMachine = _FakeMachine(id: 'usb-2e8a-a-SECOND');
      final secondDetectionStarted = Completer<void>();
      final releaseSecondDetection = Completer<void>();
      listed = [first, second];
      detection = (device) async {
        if (device.deviceId == second.deviceId) {
          secondDetectionStarted.complete();
          await releaseSecondDetection.future;
          return secondMachine;
        }
        return firstMachine;
      };
      service = build();
      final publications = <List<Device>>[];
      final subscription = service.devices.listen(
        (devices) => publications.add(List.of(devices)),
      );
      addTearDown(subscription.cancel);

      final scan = service.scanForDevices();
      await secondDetectionStarted.future;
      final detach = service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_DETACHED
          ..device = first,
      );
      releaseSecondDetection.complete();
      await scan;
      await detach;

      expect(
        publications,
        isNot(contains([same(firstMachine), same(secondMachine)])),
      );
      expect(publications.last, [same(secondMachine)]);
      expect(firstMachine.disconnectCalls, 1);
      expect(secondMachine.disconnectCalls, 0);
    },
  );

  test(
    'scan during attach connection does not start another detection',
    () async {
      final machine = _FakeMachine()..connectGate = Completer<void>();
      var detections = 0;
      listed = [_device()];
      detection = (_) async {
        detections++;
        return detections == 1 ? machine : _FakeMachine();
      };
      service = build();
      final attach = service.connectAttachedMachine(
        const DeviceAttachedEvent(physicalDeviceId: 1002),
      );
      await Future<void>.delayed(Duration.zero);
      final scan = service.scanForDevices();
      await Future<void>.delayed(Duration.zero);
      machine.connectGate!.complete();
      await attach;
      await scan;
      expect(detections, 1);
      expect(await service.devices.first, [same(machine)]);
      expect(machine.onConnectCalls, 1);
    },
  );

  test(
    'quick-connect rejects a detach and replug during enumeration',
    () async {
      final enumerationStarted = Completer<void>();
      final releaseEnumeration = Completer<void>();
      final machine = _FakeMachine();
      final physical = _device();
      listed = [physical];
      detection = (_) async => machine;
      service = SerialServiceAndroid(
        listDevices: () async {
          enumerationStarted.complete();
          await releaseEnumeration.future;
          return [physical];
        },
        usbEventStream: () => null,
        detectDevice: detection,
      );
      final quick = service.tryQuickConnect(
        const RememberedDevice(
          id: 'usb-2e8a-a-8549628789ABCDEF',
          name: 'DE1',
          type: DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.serial,
        ),
      );
      await enumerationStarted.future;
      final detach = service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_DETACHED
          ..device = physical,
      );
      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_ATTACHED
          ..device = physical,
      );
      releaseEnumeration.complete();

      expect(await quick, isNull);
      await detach;
      expect(machine.onConnectCalls, 0);
      expect(await service.devices.first, isEmpty);
    },
  );

  test('attach probe rejects a detach and replug during enumeration', () async {
    final enumerationStarted = Completer<void>();
    final releaseEnumeration = Completer<void>();
    final machine = _FakeMachine();
    final physical = _device();
    listed = [physical];
    detection = (_) async => machine;
    service = SerialServiceAndroid(
      listDevices: () async {
        enumerationStarted.complete();
        await releaseEnumeration.future;
        return [physical];
      },
      usbEventStream: () => null,
      detectDevice: detection,
    );
    final attach = service.connectAttachedMachine(
      const DeviceAttachedEvent(physicalDeviceId: 1002),
    );
    await enumerationStarted.future;
    final detach = service.handleUsbEvent(
      UsbEvent()
        ..event = UsbEvent.ACTION_USB_DETACHED
        ..device = physical,
    );
    await service.handleUsbEvent(
      UsbEvent()
        ..event = UsbEvent.ACTION_USB_ATTACHED
        ..device = physical,
    );
    releaseEnumeration.complete();

    expect(await attach, isA<AttachProbeUnsupported>());
    await detach;
    expect(machine.onConnectCalls, 0);
    expect(await service.devices.first, isEmpty);
  });

  test(
    'quick-connect detection completing after detach and replug is rejected',
    () async {
      final detected = Completer<Device?>();
      final machine = _FakeMachine();
      listed = [_device()];
      detection = (_) => detected.future;
      service = build();
      final quick = service.tryQuickConnect(
        const RememberedDevice(
          id: 'usb-2e8a-a-8549628789ABCDEF',
          name: 'DE1',
          type: DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.serial,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final detach = service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_DETACHED
          ..device = _device(),
      );
      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_ATTACHED
          ..device = _device(),
      );
      detected.complete(machine);
      expect(await quick, isNull);
      await detach;
      expect(machine.onConnectCalls, 0);
      expect(await service.devices.first, isEmpty);
    },
  );

  test(
    'canonical connected inventory survives absent descriptors and preferred reconnect',
    () async {
      final canonical = _FakeMachine();
      var detections = 0;
      listed = [_device()];
      detection = (_) async {
        detections++;
        return canonical;
      };
      service = build();
      const remembered = RememberedDevice(
        id: 'usb-2e8a-a-8549628789ABCDEF',
        name: 'DE1',
        type: DeviceType.machine,
        implementation: DeviceImplementation.unifiedDe1,
        transportType: TransportType.serial,
      );
      await service.tryQuickConnect(remembered);
      listed = [_device(serial: null)];
      for (var i = 0; i < 3; i++) {
        await service.scanForDevices();
      }
      final api = await buildAvailabilityDeviceList(
        await service.devices.first,
        [remembered],
      );
      expect(api, [containsPair('state', 'connected')]);
      expect(canonical.disconnectCalls, 0);
      expect(await service.tryQuickConnect(remembered), same(canonical));
      expect(detections, 1);
      canonical.setConnectionState(ConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
      expect(await service.tryQuickConnect(remembered), same(canonical));
      expect(detections, 2);
      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_DETACHED
          ..device = _device(serial: null),
      );
      expect(await service.devices.first, isEmpty);
    },
  );

  test(
    'two known serials on independent physical devices stay separate',
    () async {
      listed = [_device(serial: 'ONE'), _device(serial: 'TWO', physicalId: 8)];
      detection = (device) async => _FakeMachine(
        id: computeUsbAttachmentId(
          vid: device.vid,
          pid: device.pid,
          serial: device.serial,
          physicalId: device.deviceId,
        )!,
      );
      service = build();
      await service.scanForDevices();
      expect(
        (await service.devices.first).map((device) => device.deviceId).toSet(),
        {'usb-2e8a-a-ONE', 'usb-2e8a-a-TWO'},
      );
    },
  );

  test(
    'physical attach hint correlates when the descriptor becomes readable',
    () async {
      listed = [_device(serial: 'LATE')];
      final canonical = _FakeMachine(id: 'usb-2e8a-a-LATE');
      detection = (_) async => canonical;
      service = build();
      final result = await service.connectAttachedMachine(
        const DeviceAttachedEvent(
          deviceId: 'usb-2e8a-a-unknown-1002',
          physicalDeviceId: 1002,
        ),
      );
      expect(result, isA<AttachProbeConnected>());
      expect(await service.devices.first, [same(canonical)]);
    },
  );

  test(
    'canonical quick-connect never redetects a healthy fallback attachment',
    () async {
      final fallback = _FakeMachine(id: 'usb-2e8a-a-unknown-1002');
      var detections = 0;
      listed = [_device(serial: null)];
      detection = (_) async => ++detections == 1 ? fallback : _FakeMachine();
      service = build();
      await service.connectAttachedMachine(
        const DeviceAttachedEvent(physicalDeviceId: 1002),
      );
      listed = [_device()];
      final result = await service.tryQuickConnect(
        const RememberedDevice(
          id: 'usb-2e8a-a-8549628789ABCDEF',
          name: 'DE1',
          type: DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.serial,
        ),
      );
      expect(result, same(fallback));
      expect(detections, 1);
      expect(fallback.onConnectCalls, 1);
      expect(fallback.disconnectCalls, 0);
      expect(await service.devices.first, [same(fallback)]);
    },
  );

  test(
    'attach rebinds an unconnected fallback before choosing a known canonical ID',
    () async {
      final fallback = _FakeMachine(id: 'usb-2e8a-a-unknown-1002')
        ..setConnectionState(ConnectionState.discovered);
      final canonical = _FakeMachine();
      var detections = 0;
      listed = [_device(serial: null)];
      detection = (_) async => ++detections == 1 ? fallback : canonical;
      service = build();
      await service.scanForDevices();
      listed = [_device()];
      final result = await service.connectAttachedMachine(
        const DeviceAttachedEvent(physicalDeviceId: 1002),
      );
      expect((result as AttachProbeConnected).machine, same(canonical));
      expect(fallback.onConnectCalls, 0);
      expect(canonical.onConnectCalls, 1);
      expect(await service.devices.first, [same(canonical)]);
    },
  );

  test('healthy quick-connect reuses the existing physical machine', () async {
    final machine = _FakeMachine();
    var detections = 0;
    listed = [_device()];
    detection = (_) async {
      detections++;
      return machine;
    };
    service = build();
    final remembered = const RememberedDevice(
      id: 'usb-2e8a-a-8549628789ABCDEF',
      name: 'DE1',
      type: DeviceType.machine,
      implementation: DeviceImplementation.unifiedDe1,
      transportType: TransportType.serial,
    );

    await service.tryQuickConnect(remembered);
    final result = await service.tryQuickConnect(remembered);

    expect(result, same(machine));
    expect(detections, 1);
    expect(machine.onConnectCalls, 1);
  });

  test('quick-connect replaces a stale same-ID API entry', () async {
    final stale = _FakeMachine();
    final reconnected = _FakeMachine();
    var detections = 0;
    listed = [_device()];
    detection = (_) async => detections++ == 0 ? stale : reconnected;
    service = build();

    await service.scanForDevices();
    stale.setConnectionState(ConnectionState.disconnected);

    final result = await service.tryQuickConnect(
      const RememberedDevice(
        id: 'usb-2e8a-a-8549628789ABCDEF',
        name: 'DE1',
        type: DeviceType.machine,
        implementation: DeviceImplementation.unifiedDe1,
        transportType: TransportType.serial,
      ),
    );
    final liveDevices = await service.devices.first;
    final apiDevices = await buildAvailabilityDeviceList(liveDevices, const []);

    expect(result, same(reconnected));
    expect(apiDevices, [containsPair('state', 'connected')]);
    expect(liveDevices, [same(reconnected)]);
  });

  test('stale disconnect preserves replacement ownership', () async {
    final stale = _FakeMachine();
    final reconnected = _FakeMachine();
    var detections = 0;
    listed = [_device()];
    detection = (_) async => detections++ == 0 ? stale : reconnected;
    service = build();
    const remembered = RememberedDevice(
      id: 'usb-2e8a-a-8549628789ABCDEF',
      name: 'DE1',
      type: DeviceType.machine,
      implementation: DeviceImplementation.unifiedDe1,
      transportType: TransportType.serial,
    );

    await service.tryQuickConnect(remembered);
    stale.setConnectionState(ConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);
    await service.tryQuickConnect(remembered);
    stale.setConnectionState(ConnectionState.disconnected);
    await Future<void>.delayed(Duration.zero);

    expect(await service.devices.first, [same(reconnected)]);

    await service.handleUsbEvent(
      UsbEvent()
        ..event = UsbEvent.ACTION_USB_DETACHED
        ..device = _device(),
    );

    expect(reconnected.disconnectCalls, 1);
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
