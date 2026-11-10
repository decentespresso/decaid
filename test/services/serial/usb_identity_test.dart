import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:reaprime/src/models/device/device_identity.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_attach_notifier.dart';
import 'package:reaprime/src/models/device/usb_attach_probe.dart';
import 'package:reaprime/src/controllers/connection/policy_resolver.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/services/serial/serial_service_android.dart';
import 'package:reaprime/src/services/serial/utils.dart';

// ignore: depend_on_referenced_packages
import 'package:usb_serial/usb_serial.dart';

class _DescriptorDevice extends UsbDevice {
  _DescriptorDevice(String? serial)
    : super(
        '/dev/bus/usb/001/002',
        0x2e8a,
        0x000a,
        'DE1',
        'Decent Espresso',
        7,
        serial,
        1,
      );

  int createCalls = 0;
  @override
  Future<UsbPort?> create([String type = '', int iface = -1]) async {
    createCalls++;
    return UsbPort('descriptor-port');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'safe redetection retains a serial learned during this attachment',
    () async {
      var listed = <UsbDevice>[_DescriptorDevice(null)];
      var closes = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('descriptor-port'),
        (call) async {
          if (call.method == 'close') closes++;
          return true;
        },
      );
      final service = SerialServiceAndroid(
        listDevices: () async => listed,
        usbEventStream: () => null,
      );
      addTearDown(() async {
        await service.dispose();
        messenger.setMockMethodCallHandler(
          const MethodChannel('descriptor-port'),
          null,
        );
      });
      await service.scanForDevices();
      final initial = (await service.devices.first).single;
      expect(initial.deviceId, 'usb-2e8a-a-unknown-7');
      listed = [_DescriptorDevice('KNOWN')];
      await service.scanForDevices();
      expect((await service.devices.first).single.deviceId, 'usb-2e8a-a-KNOWN');
      listed = [_DescriptorDevice(null)];
      await service.scanForDevices();
      expect((await service.devices.first).single.deviceId, 'usb-2e8a-a-KNOWN');
      expect(closes, greaterThanOrEqualTo(2));
      expect((initial as CanonicalDeviceIdentity).canonicalDeviceId, isNull);
      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_DETACHED
          ..device = _DescriptorDevice(null),
      );
      expect(await service.devices.first, isEmpty);
      await service.handleUsbEvent(
        UsbEvent()
          ..event = UsbEvent.ACTION_USB_ATTACHED
          ..device = _DescriptorDevice(null),
      );
      await service.scanForDevices();
      expect(
        (await service.devices.first).single.deviceId,
        'usb-2e8a-a-unknown-7',
      );
    },
  );

  test(
    'machine forwards attachment-proven identity without relabeling the transport',
    () {
      String? canonical;
      final transport = AndroidSerialPort(
        device: _DescriptorDevice(null),
        port: UsbPort('identity-test'),
        canonicalIdentity: () => canonical,
      );
      final machine = UnifiedDe1(transport: transport);
      expect(machine.canonicalDeviceId, isNull);
      canonical = 'usb-2e8a-a-KNOWN';
      expect(machine.canonicalDeviceId, canonical);
      final policy = resolveMachinePolicy(
        machines: [machine],
        preferredMachineId: canonical,
      );
      expect((policy as ConnectMachineAction).machine, same(machine));
      expect(machine.deviceId, 'usb-2e8a-a-unknown-7');
    },
  );

  test(
    'initial enumeration retains readable serial before attach probing',
    () async {
      var listed = <UsbDevice>[_DescriptorDevice('KNOWN')];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('descriptor-port'),
        (_) async => true,
      );
      final service = SerialServiceAndroid(
        listDevices: () async => listed,
        usbEventStream: () => null,
      );
      addTearDown(() async {
        await service.dispose();
        messenger.setMockMethodCallHandler(
          const MethodChannel('descriptor-port'),
          null,
        );
      });
      await service.initialize();
      listed = [_DescriptorDevice(null)];
      await service.scanForDevices();
      final machine = (await service.devices.first).single;
      expect(machine.deviceId, 'usb-2e8a-a-KNOWN');
      expect(
        (machine as CanonicalDeviceIdentity).canonicalDeviceId,
        'usb-2e8a-a-KNOWN',
      );
    },
  );

  test(
    'real serial transport reports and coalesces pending port opening',
    () async {
      final opening = Completer<bool>();
      var opens = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('opening-port'), (
        call,
      ) async {
        if (call.method == 'open') {
          opens++;
          return opening.future;
        }
        return true;
      });
      final transport = AndroidSerialPort(
        device: _DescriptorDevice(null),
        port: UsbPort('opening-port'),
      );
      final first = transport.connect();
      final second = transport.connect();
      try {
        await Future<void>.delayed(Duration.zero);
        expect(
          await transport.connectionState.first,
          ConnectionState.connecting,
        );
        expect(opens, 1);
      } finally {
        opening.complete(false);
        await first.catchError((Object _) {});
        await second.catchError((Object _) {});
        await transport.dispose();
        messenger.setMockMethodCallHandler(
          const MethodChannel('opening-port'),
          null,
        );
      }
    },
  );

  test(
    'attach and rescan preserve a real machine during external port opening',
    () async {
      final opening = Completer<bool>();
      var opens = 0;
      var closes = 0;
      final physical = _DescriptorDevice('KNOWN');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('descriptor-port'),
        (call) async {
          if (call.method == 'open') {
            opens++;
            return opening.future;
          }
          if (call.method == 'close') closes++;
          return true;
        },
      );
      final service = SerialServiceAndroid(
        listDevices: () async => [physical],
        usbEventStream: () => null,
      );
      await service.scanForDevices();
      final machine = (await service.devices.first).single;
      final connection = machine.onConnect();
      try {
        await Future<void>.delayed(Duration.zero);
        expect(await machine.connectionState.first, ConnectionState.connecting);
        expect(
          await service.connectAttachedMachine(
            const DeviceAttachedEvent(physicalDeviceId: 7),
          ),
          isA<AttachProbeUnsupported>(),
        );
        await service.scanForDevices();
        expect(await service.devices.first, [same(machine)]);
        expect(physical.createCalls, 1);
        expect(opens, 1);
        expect(closes, 0);
        await service.handleUsbEvent(
          UsbEvent()
            ..event = UsbEvent.ACTION_USB_DETACHED
            ..device = physical,
        );
        opening.complete(true);
        await expectLater(connection, throwsStateError);
        expect(await service.devices.first, isEmpty);
        expect(closes, greaterThan(0));
      } finally {
        if (!opening.isCompleted) opening.complete(false);
        await connection.catchError((Object _) {});
        await service.dispose();
        messenger.setMockMethodCallHandler(
          const MethodChannel('descriptor-port'),
          null,
        );
      }
    },
  );

  test('descriptor serial remains the canonical USB identity', () {
    expect(
      computeUsbAttachmentId(
        vid: 0x2e8a,
        pid: 0x000a,
        serial: '8549628789ABCDEF',
        physicalId: 7,
      ),
      'usb-2e8a-a-8549628789ABCDEF',
    );
    expect(isEphemeralDeviceIdentity('usb-2e8a-a-8549628789ABCDEF'), isFalse);
  });

  test('missing serial gets an attachment-scoped identity', () {
    final first = computeUsbAttachmentId(
      vid: 0x2e8a,
      pid: 0x000a,
      serial: null,
      physicalId: 7,
    );
    final second = computeUsbAttachmentId(
      vid: 0x2e8a,
      pid: 0x000a,
      serial: null,
      physicalId: 8,
    );

    expect(first, 'usb-2e8a-a-unknown-7');
    expect(second, 'usb-2e8a-a-unknown-8');
    expect(first, isNot(second));
    expect(isEphemeralDeviceIdentity(first!), isTrue);
    expect(isEphemeralDeviceIdentity(second!), isTrue);
  });

  test('incomplete VID/PID descriptors cannot become durable raw IDs', () {
    final id = computeUsbAttachmentId(physicalId: 7);
    expect(id, 'usb-session-7');
    expect(isEphemeralDeviceIdentity(id!), isTrue);
  });

  test('legacy unknown IDs are also treated as ephemeral', () {
    expect(isEphemeralDeviceIdentity('usb-2e8a-a-unknown'), isTrue);
    expect(isEphemeralDeviceIdentity('usb-2e8a-a-unknown-if02-7'), isTrue);
  });

  test('whitespace-only serial is an attachment fallback', () {
    expect(
      computeUsbAttachmentId(
        vid: 0x2e8a,
        pid: 0x000a,
        serial: '  ',
        physicalId: 7,
      ),
      'usb-2e8a-a-unknown-7',
    );
  });

  test(
    'AndroidSerialPort uses physical identity when descriptor serial is absent',
    () {
      final port = AndroidSerialPort(
        device: UsbDevice(
          '/dev/bus/usb/001/002',
          0x2e8a,
          0x000a,
          'DE1',
          'Decent Espresso',
          7,
          null,
          1,
        ),
        port: UsbPort('identity-test'),
      );
      expect(port.id, 'usb-2e8a-a-unknown-7');
    },
  );
}
