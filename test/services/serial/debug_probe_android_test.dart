import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/sensor/debug_port.dart';
import 'package:reaprime/src/services/serial/serial_service_android.dart';

// ignore: depend_on_referenced_packages
import 'package:usb_serial/usb_serial.dart';

UsbDevice _device({
  String? productName = 'Debug Probe (CMSIS-DAP)',
  int deviceId = 42,
}) {
  return UsbDevice(
    '/dev/bus/usb/001/002',
    0x2e8a,
    0x000c,
    productName,
    'Raspberry Pi',
    deviceId,
    'DEBUG-PROBE',
    4,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SerialServiceAndroid service;
  late List<int> bauds;
  late List<List<int>> writes;
  late bool closed;
  late void Function(Uint8List) emit;
  late String portName;
  late bool genericDe1Probe;
  late Completer<void> streamConfigured;
  late bool portParametersConfigured;
  late bool eventStreamListening;
  late UsbDevice listedDevice;
  late List<Map<Object?, Object?>> creates;
  MockStreamHandlerEventSink? sink;

  Future<void> emitAfterStreamConfigured(Uint8List bytes) async {
    await streamConfigured.future;
    await Future<void>.delayed(Duration.zero);
    emit(bytes);
  }

  setUp(() {
    bauds = [];
    writes = [];
    closed = false;
    sink = null;
    portName = 'debug-probe-port';
    genericDe1Probe = false;
    streamConfigured = Completer<void>();
    portParametersConfigured = false;
    eventStreamListening = false;
    creates = [];
    listedDevice = _device();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(const MethodChannel('usb_serial'), (
      call,
    ) async {
      if (call.method == 'create') {
        creates.add(Map<Object?, Object?>.from(call.arguments as Map));
        return portName;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(MethodChannel(portName), (call) async {
      switch (call.method) {
        case 'open':
          return true;
        case 'close':
          closed = true;
          return true;
        case 'setPortParameters':
          bauds.add(call.arguments['baudRate'] as int);
          portParametersConfigured = true;
          if (eventStreamListening && !streamConfigured.isCompleted) {
            Future<void>.delayed(Duration.zero, () {
              if (!streamConfigured.isCompleted) streamConfigured.complete();
            });
          }
          return null;
        case 'write':
          writes.add(List<int>.from(call.arguments['data'] as Uint8List));
          if (genericDe1Probe) {
            sink?.success(Uint8List.fromList(utf8.encode('[M] 1\n')));
          }
          return null;
        default:
          return null;
      }
    });
    messenger.setMockStreamHandler(
      EventChannel('$portName/stream'),
      MockStreamHandler.inline(
        onListen: (_, events) {
          sink = events;
          eventStreamListening = true;
          if (portParametersConfigured && !streamConfigured.isCompleted) {
            Future<void>.delayed(Duration.zero, () {
              if (!streamConfigured.isCompleted) streamConfigured.complete();
            });
          }
        },
        onCancel: (_) {},
      ),
    );
    emit = (bytes) => sink?.success(bytes);

    service = SerialServiceAndroid(
      listDevices: () async => [listedDevice],
      usbEventStream: () => null,
      probeDuration: const Duration(milliseconds: 30),
    );
  });

  tearDown(() async {
    await service.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('usb_serial'), null);
    messenger.setMockMethodCallHandler(MethodChannel(portName), null);
    messenger.setMockStreamHandler(EventChannel('$portName/stream'), null);
  });

  test(
    'opens an admitted Debug Probe at 460800 and keeps passive R telemetry',
    () async {
      final scan = service.scanForDevices();
      final telemetry = emitAfterStreamConfigured(
        Uint8List.fromList(utf8.encode('R telemetry\n')),
      );
      await scan;
      await telemetry;

      final devices = await service.devices.first;
      expect(bauds, [460800]);
      expect(devices, hasLength(1));
      expect(devices.single, isA<DebugPort>());
      expect(devices.single.implementation, DeviceImplementation.debugPort);
      expect(writes, isEmpty);
      expect(creates.single['type'], 'cdc');
      expect(
        creates.single['interface'],
        -1,
        reason: 'CDC pair selection stays automatic for the composite probe',
      );
    },
  );

  test(
    'rejects a quiet admitted Debug Probe without DE1 writes or leaked port',
    () async {
      await service.scanForDevices();

      expect(writes, isEmpty);
      expect(bauds, [460800]);
      expect(await service.devices.first, isEmpty);
      expect(closed, isTrue);
    },
  );

  test(
    'rejects malformed admitted Debug Probe data without DE1 writes',
    () async {
      final scan = service.scanForDevices();
      final telemetry = emitAfterStreamConfigured(
        Uint8List.fromList([0xff, 0xfe, 0x0a]),
      );
      await scan;
      await telemetry;

      expect(writes, isEmpty);
      expect(bauds, [460800]);
      expect(await service.devices.first, isEmpty);
      expect(closed, isTrue);
    },
  );

  test(
    'rejects unrecognized valid UTF-8 from an admitted Debug Probe',
    () async {
      final scan = service.scanForDevices();
      final telemetry = emitAfterStreamConfigured(
        Uint8List.fromList(utf8.encode('not a recognized device\n')),
      );
      await scan;
      await telemetry;

      expect(writes, isEmpty);
      expect(bauds, [460800]);
      expect(await service.devices.first, isEmpty);
      expect(closed, isTrue);
    },
  );

  test('keeps generic serial DE1 probing at the 115200 default', () async {
    genericDe1Probe = true;
    listedDevice = _device(productName: 'USB Serial');
    await service.scanForDevices();

    expect(bauds, [115200]);
    final devices = await service.devices.first;
    expect(devices, hasLength(1));
    expect(devices.single.implementation, DeviceImplementation.unifiedDe1);
    final commands = writes.map(utf8.decode).toList();
    expect(commands, contains('<+M>\n'));
    expect(commands, contains('<+E>\n'));
    expect(commands, contains('<-M>\n'));
    expect(commands, contains('<-E>\n'));
  });

  test(
    'cancellation while baud configuration is pending never connects or listens',
    () async {
      final configGate = Completer<void>();
      final closeCalls = <int>[];
      var listening = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Future<Object?> handler(MethodCall call) async {
        switch (call.method) {
          case 'open':
            return true;
          case 'close':
            closeCalls.add(1);
            return true;
          case 'setPortParameters':
            await configGate.future;
            return null;
          default:
            return null;
        }
      }

      messenger.setMockMethodCallHandler(MethodChannel(portName), handler);
      messenger.setMockStreamHandler(
        EventChannel('$portName/stream'),
        MockStreamHandler.inline(
          onListen: (_, _) {
            listening = true;
          },
          onCancel: (_) {},
        ),
      );

      final port = AndroidSerialPort(
        device: _device(),
        port: UsbPort(portName),
      );
      final states = <ConnectionState>[];
      final sub = port.connectionState.listen(states.add);

      final connecting = port.connect();
      await Future<void>.delayed(Duration.zero);
      final disposed = port.dispose();
      configGate.complete();

      await expectLater(connecting, throwsA(isA<StateError>()));
      await disposed;
      await Future<void>.delayed(Duration.zero);

      expect(states, isNot(contains(ConnectionState.connected)));
      expect(listening, isFalse);
      expect(closeCalls, isNotEmpty);
      await sub.cancel();
    },
  );

  test(
    'keeps AndroidSerialPort defaults at 115200 for non-probe callers',
    () async {
      for (final productName in <String?>[
        'DE1',
        'Bengle',
        'Half Decent Scale',
        null,
        'USB Serial',
        'SensorBasket',
      ]) {
        bauds.clear();
        final port = AndroidSerialPort(
          device: _device(productName: productName),
          port: UsbPort(portName),
        );
        await port.connect();

        expect(bauds, [115200], reason: 'productName=$productName');
        await port.dispose();
      }
    },
  );
}
