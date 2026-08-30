import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device_attach_notifier.dart';
import 'package:reaprime/src/services/serial/serial_service_android.dart';

// ignore: depend_on_referenced_packages
import 'package:usb_serial/usb_serial.dart';

UsbEvent _event(String action, {UsbDevice? device}) {
  return UsbEvent()
    ..event = action
    ..device = device;
}

UsbDevice _device({
  int? vid = 0x2E8A,
  int? pid = 0x000A,
  String? serial = '8549628789ABCDEF',
}) {
  return UsbDevice(
    '/dev/bus/usb/001/002',
    vid,
    pid,
    'TinyUSB Device',
    'Decent Espresso',
    1002,
    serial,
    1,
  );
}

void main() {
  late SerialServiceAndroid service;

  setUp(() {
    service = SerialServiceAndroid();
  });

  tearDown(() async {
    await service.dispose();
  });

  test('implements the optional attach notifier capability', () {
    expect(service, isA<DeviceAttachNotifier>());
  });

  test('attach emits a non-replaying hint with available metadata', () async {
    final event = service.deviceAttached.first;
    service.handleUsbEvent(
      _event(UsbEvent.ACTION_USB_ATTACHED, device: _device()),
    );

    final attached = await event;
    expect(attached.deviceId, 'usb-2e8a-a-8549628789ABCDEF');
    expect(attached.name, 'TinyUSB Device');

    final lateEvents = <DeviceAttachedEvent>[];
    final lateSubscription = service.deviceAttached.listen(lateEvents.add);
    await Future<void>.delayed(Duration.zero);
    expect(lateEvents, isEmpty);
    await lateSubscription.cancel();
  });

  test(
    'attach with incomplete or absent metadata still emits a hint',
    () async {
      final events = <DeviceAttachedEvent>[];
      final subscription = service.deviceAttached.listen(events.add);

      service.handleUsbEvent(
        _event(UsbEvent.ACTION_USB_ATTACHED, device: _device(serial: null)),
      );
      service.handleUsbEvent(
        _event(
          UsbEvent.ACTION_USB_ATTACHED,
          device: _device(vid: null, pid: null, serial: null),
        ),
      );
      service.handleUsbEvent(_event(UsbEvent.ACTION_USB_ATTACHED));
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(3));
      expect(events[1].deviceId, isNull);
      expect(events[2].deviceId, isNull);
      await subscription.cancel();
    },
  );

  test('device support is not filtered by the attach notifier', () async {
    final event = service.deviceAttached.first;
    service.handleUsbEvent(
      _event(
        UsbEvent.ACTION_USB_ATTACHED,
        device: UsbDevice(
          '/dev/bus/usb/001/003',
          0x046D,
          0xC31C,
          'USB Keyboard',
          'Logitech',
          1003,
          'kbd-1',
          1,
        ),
      ),
    );

    expect((await event).name, 'USB Keyboard');
  });

  test('detach and unknown actions emit no attach hints', () async {
    final events = <DeviceAttachedEvent>[];
    final subscription = service.deviceAttached.listen(events.add);

    service.handleUsbEvent(
      _event(UsbEvent.ACTION_USB_DETACHED, device: _device()),
    );
    service.handleUsbEvent(_event('unknown'));
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
    await subscription.cancel();
  });

  test(
    'dispose cancels the platform USB subscription and closes attach events',
    () async {
      final usbEvents = StreamController<UsbEvent>.broadcast();
      service = SerialServiceAndroid(
        listDevices: () async => const [],
        usbEventStream: () => usbEvents.stream,
      );
      await service.initialize();
      expect(usbEvents.hasListener, isTrue);

      final done = service.deviceAttached.drain<void>();
      await service.dispose();

      expect(usbEvents.hasListener, isFalse);
      await done;
      await usbEvents.close();
    },
  );

  test(
    'dispose while initialization is pending prevents USB subscription',
    () async {
      final listedDevices = Completer<List<UsbDevice>>();
      final usbEvents = StreamController<UsbEvent>.broadcast();
      service = SerialServiceAndroid(
        listDevices: () => listedDevices.future,
        usbEventStream: () => usbEvents.stream,
      );

      final initialization = service.initialize();
      await service.dispose();
      listedDevices.complete(const []);
      await initialization;

      expect(usbEvents.hasListener, isFalse);
      await usbEvents.close();
    },
  );

  test(
    'initialization and disposal tolerate an unavailable USB event stream',
    () async {
      service = SerialServiceAndroid(
        listDevices: () async => const [],
        usbEventStream: () => null,
      );

      await service.initialize();
      await service.dispose();
    },
  );

  test(
    'initialization emits one generic hint for a non-empty enumeration',
    () async {
      final usbEvents = StreamController<UsbEvent>.broadcast();
      service = SerialServiceAndroid(
        listDevices: () async => [_device(), _device(serial: 'OTHER')],
        usbEventStream: () => usbEvents.stream,
      );
      final events = <DeviceAttachedEvent>[];
      final subscription = service.deviceAttached.listen(events.add);

      await service.initialize();
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.deviceId, isNull);
      await subscription.cancel();
      await usbEvents.close();
    },
  );

  test('initialization emits no hint for an empty enumeration', () async {
    final usbEvents = StreamController<UsbEvent>.broadcast();
    service = SerialServiceAndroid(
      listDevices: () async => const [],
      usbEventStream: () => usbEvents.stream,
    );
    final events = <DeviceAttachedEvent>[];
    final subscription = service.deviceAttached.listen(events.add);

    await service.initialize();
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
    await subscription.cancel();
    await usbEvents.close();
  });

  test(
    'platform listener is established before enumeration completes',
    () async {
      final listedDevices = Completer<List<UsbDevice>>();
      final usbEvents = StreamController<UsbEvent>.broadcast();
      service = SerialServiceAndroid(
        listDevices: () => listedDevices.future,
        usbEventStream: () => usbEvents.stream,
      );
      final events = <DeviceAttachedEvent>[];
      final subscription = service.deviceAttached.listen(events.add);

      final initializing = service.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(usbEvents.hasListener, isTrue);
      usbEvents.add(_event(UsbEvent.ACTION_USB_ATTACHED, device: _device()));
      listedDevices.complete([_device(serial: 'OTHER')]);
      await initializing;
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(2));
      expect(events[0].deviceId, 'usb-2e8a-a-8549628789ABCDEF');
      expect(events[1].deviceId, isNull);
      await subscription.cancel();
      await usbEvents.close();
    },
  );
}
