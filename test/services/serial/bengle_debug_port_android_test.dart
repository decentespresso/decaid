import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/serial/serial_service_android.dart';
import 'package:reaprime/src/services/serial/utils.dart';

// ignore: depend_on_referenced_packages
import 'package:usb_serial/usb_serial.dart';

const _serial = 'TEST-SERIAL';
const _machineId = 'usb-2e8a-a-$_serial';
const _tapId = 'usb-2e8a-a-$_serial-if02';

UsbDevice _composite({
  int? vid = 0x2e8a,
  int? pid = 0x000a,
  String? serial = _serial,
  int? deviceId = 1002,
  int? interfaceCount = 4,
  String? productName = 'Bengle',
}) {
  return UsbDevice(
    '/dev/bus/usb/001/002',
    vid,
    pid,
    productName,
    'Decent Espresso',
    deviceId,
    serial,
    interfaceCount,
  );
}

class _FakeMachine implements Device {
  _FakeMachine(this.deviceId);

  @override
  final String deviceId;

  @override
  String get name => 'Bengle';

  @override
  DeviceType get type => DeviceType.machine;

  @override
  DeviceImplementation get implementation => DeviceImplementation.bengle;

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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<UsbDevice> listed;
  late SerialServiceAndroid service;
  int? requestedInterface;
  late List<String> channelCalls;
  late List<bool> dtrValues;

  String machineIdOf(UsbDevice d) =>
      computeUsbStableId(vid: d.vid, pid: d.pid, serial: d.serial) ??
      '${d.deviceId}';

  SerialServiceAndroid build({Future<Device?> Function(UsbDevice)? detect}) {
    requestedInterface = null;
    return SerialServiceAndroid(
      listDevices: () async => listed,
      usbEventStream: () => null,
      detectDevice: detect ?? (d) async => _FakeMachine(machineIdOf(d)),
      createTapPort: (device, iface) async {
        requestedInterface = iface;
        return UsbPort('test-tap-port');
      },
    );
  }

  setUp(() {
    listed = [];
    channelCalls = [];
    dtrValues = [];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('test-tap-port'), (
      call,
    ) async {
      channelCalls.add(call.method);
      if (call.method == 'setDTR') {
        dtrValues.add(call.arguments['value'] as bool);
      }
      if (call.method == 'open' || call.method == 'close') return true;
      return null;
    });
    messenger.setMockStreamHandler(
      const EventChannel('test-tap-port/stream'),
      MockStreamHandler.inline(onListen: (_, _) {}, onCancel: (_) {}),
    );
    service = build(detect: (_) async => _FakeMachine(_machineId));
  });

  tearDown(() async {
    await service.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('test-tap-port'),
      null,
    );
    messenger.setMockStreamHandler(
      const EventChannel('test-tap-port/stream'),
      null,
    );
  });

  test('composite Bengle exposes machine and tap with distinct IDs', () async {
    listed = [_composite()];
    await service.scanForDevices();

    final devices = await service.devices.first;
    expect(devices, hasLength(2));
    final ids = devices.map((d) => d.deviceId).toSet();
    expect(ids, contains(_machineId));
    expect(ids, contains('$_tapId-1002'));

    final tap = devices.singleWhere((d) => d is Sensor);
    expect(tap.name, 'Bengle EBus Tap');
    expect(tap.implementation, DeviceImplementation.bengleDebugPort);
  });

  test('Android opens the tap data interface 3, identity keeps if02', () async {
    listed = [_composite(), _composite(deviceId: 1003)];
    service = build();
    await service.scanForDevices();

    // The usb_serial fork derives the control interface as iface - 1, so the
    // tap's Android bulk-data interface is 3 even though the logical identity
    // and ID keep denoting interface 2.
    expect(requestedInterface, 3);
    final taps = (await service.devices.first).whereType<Sensor>().toList();
    expect(taps, hasLength(2));
    for (final tap in taps) {
      expect(tap.deviceId, contains('-if02-'), reason: tap.deviceId);
    }
  });

  test('tap discovery is independent of machine detection', () async {
    listed = [_composite()];
    service = build(detect: (_) async => null);
    await service.scanForDevices();

    final devices = await service.devices.first;
    expect(devices.map((d) => d.deviceId), ['$_tapId-1002']);
  });

  test('device without the tap data interface yields no tap', () async {
    listed = [_composite(interfaceCount: 1)];
    await service.scanForDevices();

    final devices = await service.devices.first;
    expect(devices.map((d) => d.deviceId), [_machineId]);
    expect(requestedInterface, isNull);
  });

  test('unrelated interface-2 composite yields no tap', () async {
    listed = [_composite(vid: 0x046d, pid: 0xc31c, serial: 'kbd-1')];
    service = build(detect: (_) async => null);
    await service.scanForDevices();

    final devices = await service.devices.first;
    expect(devices, isEmpty);
    expect(requestedInterface, isNull);
  });

  test(
    'matching vid/pid/interface but wrong product name yields no tap',
    () async {
      // VID/PID are shared Pico SDK identifiers; only the exact product name
      // `Bengle` exposes the tap. A Pico board with the same IDs and interface
      // layout must not open the tap data interface.
      listed = [_composite(productName: 'Pico')];
      await service.scanForDevices();

      final devices = await service.devices.first;
      expect(devices.map((d) => d.deviceId), [_machineId]);
      expect(requestedInterface, isNull);
    },
  );

  test('null product name yields no tap', () async {
    listed = [_composite(productName: null)];
    await service.scanForDevices();

    final devices = await service.devices.first;
    expect(devices.map((d) => d.deviceId), [_machineId]);
    expect(requestedInterface, isNull);
  });

  test('rescan keeps both logical IDs without duplicates', () async {
    listed = [_composite()];
    await service.scanForDevices();
    final tap = (await service.devices.first).singleWhere(
      (d) => d.deviceId == '$_tapId-1002',
    );
    await tap.onConnect();

    await service.scanForDevices();

    final devices = await service.devices.first;
    expect(devices, hasLength(2));
    expect(devices.map((d) => d.deviceId).toSet(), {
      _machineId,
      '$_tapId-1002',
    });
  });

  test(
    'connected machine does not block rediscovery of a missing tap',
    () async {
      listed = [_composite()];
      await service.scanForDevices();
      // The machine stays connected (fake); the tap is left disconnected and is
      // dropped from the registry between scans.
      await service.scanForDevices();

      final devices = await service.devices.first;
      expect(devices.map((d) => d.deviceId).toSet(), {
        _machineId,
        '$_tapId-1002',
      });
    },
  );

  test(
    'two same-serial boards yield one machine and two unique taps',
    () async {
      listed = [_composite(), _composite(deviceId: 1003)];
      service = build();
      await service.scanForDevices();

      final devices = await service.devices.first;
      final ids = devices.map((d) => d.deviceId).toSet();
      expect(ids, {_machineId, '$_tapId-1002', '$_tapId-1003'});
      expect(ids.length, devices.length, reason: 'no duplicate logical IDs');
    },
  );

  test('rescan of two same-serial boards adds no duplicates', () async {
    listed = [_composite(), _composite(deviceId: 1003)];
    service = build();
    await service.scanForDevices();
    await service.scanForDevices();

    final devices = await service.devices.first;
    final ids = devices.map((d) => d.deviceId).toSet();
    expect(ids, {_machineId, '$_tapId-1002', '$_tapId-1003'});
    expect(ids.length, devices.length, reason: 'no duplicate logical IDs');
  });

  test(
    'detaching one same-serial board removes only its physical tap',
    () async {
      listed = [_composite(), _composite(deviceId: 1003)];
      service = build();
      await service.scanForDevices();

      // Board 1002 owns the machine (first in enumeration); detaching it takes
      // the machine and its tap, leaving the other board's tap untouched.
      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_DETACHED
          ..device = _composite(),
      );

      final devices = await service.devices.first;
      expect(devices.map((d) => d.deviceId).toSet(), {'$_tapId-1003'});
    },
  );

  test('detaching a non-owner board preserves the machine', () async {
    listed = [_composite(), _composite(deviceId: 1003)];
    service = build();
    await service.scanForDevices();

    // Board 1003 does not own the machine; detaching it removes only its tap.
    await service.handleUsbEvent(
      UsbEvent()
        ..event = UsbEvent.ACTION_USB_DETACHED
        ..device = _composite(deviceId: 1003),
    );

    final devices = await service.devices.first;
    expect(devices.map((d) => d.deviceId).toSet(), {
      _machineId,
      '$_tapId-1002',
    });
  });

  test('physical detach removes both logical devices', () async {
    listed = [_composite()];
    await service.scanForDevices();
    final tap = (await service.devices.first).singleWhere(
      (d) => d.deviceId == '$_tapId-1002',
    );
    final machine = (await service.devices.first).singleWhere(
      (d) => d.deviceId == _machineId,
    );
    final machineDisconnectCalls = (machine as _FakeMachine).disconnectCalls;

    await service.handleUsbEvent(
      UsbEvent()
        ..event = UsbEvent.ACTION_USB_DETACHED
        ..device = _composite(),
    );

    final devices = await service.devices.first;
    expect(devices, isEmpty);
    expect(machine.disconnectCalls, machineDisconnectCalls + 1);
    expect(await tap.connectionState.first, ConnectionState.disconnected);
  });

  test('physical orphan GC removes only the vanished board tap', () async {
    listed = [_composite(), _composite(deviceId: 1003)];
    service = build();
    await service.scanForDevices();
    for (final tap in (await service.devices.first).whereType<Sensor>()) {
      await tap.onConnect();
    }

    // Board 1003 vanishes from enumeration without a detach event; both taps
    // reduce to the same stable base, so only physical ownership can tell
    // the surviving tap apart.
    listed = [_composite()];
    await service.scanForDevices();

    final devices = await service.devices.first;
    expect(devices.map((d) => d.deviceId).toSet(), {
      _machineId,
      '$_tapId-1002',
    });
  });

  test(
    'scan cleanup disposes the old tap adapter before replacement',
    () async {
      listed = [_composite()];
      service = build();
      await service.scanForDevices();
      final tap = (await service.devices.first).singleWhere(
        (d) => d.deviceId == '$_tapId-1002',
      );
      await tap.onConnect();
      await tap.disconnect();
      channelCalls.clear();

      await service.scanForDevices();

      expect(channelCalls, contains('close'));
      final devices = await service.devices.first;
      final replacement = devices.singleWhere(
        (d) => d.deviceId == '$_tapId-1002',
      );
      expect(replacement, isNot(same(tap)));
    },
  );

  test(
    'detach without a physical ID does not remove unrelated devices',
    () async {
      listed = [
        _composite(deviceId: null), // serial SERIAL, no physical ID
        _composite(serial: 'OTHER-SERIAL', deviceId: null),
      ];
      service = build();
      await service.scanForDevices();
      expect(await service.devices.first, hasLength(4));

      // The detach event carries no physical ID; the stable-ID fallback must
      // only remove the detached serial's logical devices. Devices without
      // physical ownership must not all match a null physical ID.
      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_DETACHED
          ..device = _composite(deviceId: null),
      );

      final devices = await service.devices.first;
      expect(devices.map((d) => d.deviceId).toSet(), {
        'usb-2e8a-a-OTHER-SERIAL',
        'usb-2e8a-a-OTHER-SERIAL-if02',
      });
    },
  );

  test('tap transport asserts DTR on connect', () async {
    listed = [_composite()];
    await service.scanForDevices();
    final tap = (await service.devices.first).singleWhere(
      (d) => d.deviceId == '$_tapId-1002',
    );

    await tap.onConnect();

    expect(channelCalls, contains('setDTR'));
    expect(dtrValues, [true]);
  });

  test('service disposal closes the tap port and is idempotent', () async {
    listed = [_composite()];
    await service.scanForDevices();
    final tap = (await service.devices.first).singleWhere(
      (d) => d.deviceId == '$_tapId-1002',
    );
    await tap.onConnect();
    channelCalls.clear();

    await service.dispose();
    expect(channelCalls, contains('close'));

    await service.dispose();
  });

  test('stable ID helper matches the emitted tap ID', () {
    expect(
      computeUsbStableId(
        vid: 0x2e8a,
        pid: 0x000a,
        serial: _serial,
        interfaceNumber: 2,
      ),
      _tapId,
    );
  });

  group('AndroidSerialPort text vs binary paths', () {
    late List<MockStreamHandlerEventSink> sinks;
    late AndroidSerialPort port;

    setUp(() {
      sinks = [];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('test-port'), (
        call,
      ) async {
        if (call.method == 'open' || call.method == 'close') return true;
        return null;
      });
      messenger.setMockStreamHandler(
        const EventChannel('test-port/stream'),
        MockStreamHandler.inline(
          onListen: (_, events) => sinks.add(events),
          onCancel: (_) {},
        ),
      );
    });

    tearDown(() async {
      await port.dispose();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('test-port'),
        null,
      );
      messenger.setMockStreamHandler(
        const EventChannel('test-port/stream'),
        null,
      );
    });

    test(
      'binary tap chunk reaches rawStream unchanged and skips text',
      () async {
        port = AndroidSerialPort(
          device: _composite(),
          port: UsbPort('test-port'),
          decodeUtf8Text: false,
        );
        await port.connect();

        // Capture the per-chunk decode-failure log the old tap path emitted.
        final previousRootLevel = Logger.root.level;
        Logger.root.level = Level.ALL;
        addTearDown(() => Logger.root.level = previousRootLevel);
        final records = <LogRecord>[];
        final logSub = Logger.root.onRecord.listen(records.add);

        final raw = <Uint8List>[];
        final text = <String>[];
        final rawSub = port.rawStream.listen(raw.add);
        final textSub = port.readStream.listen(text.add);

        final chunk = Uint8List.fromList([0x00, 0xFF, 0x0A, 0x12, 0x80]);
        sinks.single.success(chunk);
        await Future<void>.delayed(Duration.zero);

        expect(raw, [chunk]);
        expect(text, isEmpty);
        expect(
          records.where(
            (r) =>
                r.loggerName.startsWith('Serial:') &&
                r.error is FormatException,
          ),
          isEmpty,
          reason: 'binary tap must never enter the UTF-8 decode/log path',
        );
        await logSub.cancel();
        await rawSub.cancel();
        await textSub.cancel();
      },
    );

    test('default transport still decodes UTF-8 to readStream', () async {
      port = AndroidSerialPort(
        device: _composite(),
        port: UsbPort('test-port'),
      );
      await port.connect();

      final raw = <Uint8List>[];
      final text = <String>[];
      final rawSub = port.rawStream.listen(raw.add);
      final textSub = port.readStream.listen(text.add);

      final chunk = utf8.encode('Bengle machine ping\n');
      sinks.single.success(chunk);
      await Future<void>.delayed(Duration.zero);

      expect(raw, [chunk]);
      expect(text, ['Bengle machine ping\n']);
      await rawSub.cancel();
      await textSub.cancel();
    });
  });
}
