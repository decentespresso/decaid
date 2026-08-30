import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_attach_notifier.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/scan_result.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/usb_attach_probe.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/services/telemetry/telemetry_service.dart';
import 'package:rxdart/rxdart.dart';

class _FailingDiscoveryService implements DeviceDiscoveryService {
  final _controller = BehaviorSubject<List<Device>>.seeded(const []);
  final Object error;

  _FailingDiscoveryService(this.error);

  @override
  Stream<List<Device>> get devices => _controller.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {
    throw error;
  }

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;
}

class _QuietDiscoveryService implements DeviceDiscoveryService {
  final _controller = BehaviorSubject<List<Device>>.seeded(const []);
  final Device device;

  _QuietDiscoveryService(this.device);

  @override
  Stream<List<Device>> get devices => _controller.stream;

  @override
  Future<void> initialize() async {
    _controller.add([device]);
  }

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {
    _controller.add([device]);
  }

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;
}

class _ManualDiscoveryService implements DeviceDiscoveryService {
  final _controller = BehaviorSubject<List<Device>>.seeded(const []);

  @override
  Stream<List<Device>> get devices => _controller.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;

  void emit(List<Device> devices) => _controller.add(devices);
}

class _RecordingTelemetry implements TelemetryService {
  final Map<String, Object> customKeys = {};

  @override
  Future<void> initialize() async {}

  @override
  Future<void> recordError(
    Object error,
    StackTrace? stackTrace, {
    bool fatal = false,
  }) async {}

  @override
  Future<void> log(String message) async {}

  @override
  Future<void> setCustomKey(String key, Object value) async {
    customKeys[key] = value;
  }

  @override
  Future<void> setConsentEnabled(bool enabled) async {}

  @override
  Future<void> recordTrace(String name, Map<String, int> metrics) async {}

  @override
  String getLogBuffer() => '';
}

class _AttachNotifyingDiscoveryService
    implements DeviceDiscoveryService, DeviceAttachNotifier {
  final _controller = BehaviorSubject<List<Device>>.seeded(const []);
  final _attached = PublishSubject<DeviceAttachedEvent>();
  final Future<void>? initialization;
  final bool emitAttachInInitialize;

  _AttachNotifyingDiscoveryService({
    this.initialization,
    this.emitAttachInInitialize = false,
  });

  bool get hasAttachListener => _attached.hasListener;

  @override
  Stream<List<Device>> get devices => _controller.stream;

  @override
  Stream<DeviceAttachedEvent> get deviceAttached => _attached.stream;

  @override
  Future<void> initialize() async {
    await initialization;
    if (emitAttachInInitialize) {
      _attached.add(
        const DeviceAttachedEvent(deviceId: 'startup-usb', name: 'DE1'),
      );
    }
  }

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;

  void attach(DeviceAttachedEvent event) => _attached.add(event);
}

class _FakeDevice implements Device {
  @override
  final String deviceId;

  @override
  final String name;

  @override
  final DeviceType type;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.unknown;

  _FakeDevice({required this.deviceId, required this.name, required this.type});

  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.disconnected);

  @override
  Future<void> onConnect() async {}

  @override
  Future<void> disconnect() async {}
}

void main() {
  group(
    'DeviceController.scanForDevices partial failures (comms-harden #22)',
    () {
      test('one service throwing does not torpedo the scan — '
          'devices from succeeding services are still returned', () async {
        final failing = _FailingDiscoveryService(
          const PermissionDeniedException('denied'),
        );
        final succeeding = _QuietDiscoveryService(
          _FakeDevice(
            deviceId: 'D9:11:0B:E6:9F:86',
            name: 'DE1',
            type: DeviceType.machine,
          ),
        );

        final controller = DeviceController([failing, succeeding]);
        await controller.initialize();

        final result = await controller.scanForDevices();

        expect(
          result.matchedDevices,
          hasLength(1),
          reason: 'succeeding service must still yield its device',
        );
        expect(result.matchedDevices.first.deviceId, 'D9:11:0B:E6:9F:86');
        expect(
          result.failedServices,
          hasLength(1),
          reason: 'failing service must be surfaced in failedServices',
        );
        expect(
          result.failedServices.first.error,
          isA<PermissionDeniedException>(),
        );
        expect(
          result.failedServices.first.serviceName,
          contains('FailingDiscoveryService'),
        );
        expect(result.terminationReason, ScanTerminationReason.completed);
      });

      test('all services failing yields a ScanResult with empty matched + '
          'populated failedServices (no top-level throw)', () async {
        final a = _FailingDiscoveryService(Exception('adapter-off'));
        final b = _FailingDiscoveryService(const PermissionDeniedException());

        final controller = DeviceController([a, b]);
        await controller.initialize();

        final result = await controller.scanForDevices();

        expect(result.matchedDevices, isEmpty);
        expect(result.failedServices, hasLength(2));
      });

      test(
        'concurrent scanForDevices calls share one in-flight scan',
        () async {
          final service = _QuietDiscoveryService(
            _FakeDevice(deviceId: 'id-1', name: 'D1', type: DeviceType.machine),
          );
          final controller = DeviceController([service]);
          await controller.initialize();

          final first = controller.scanForDevices();
          final second = controller.scanForDevices();

          expect(
            identical(first, second),
            isTrue,
            reason: 'second concurrent call must share the in-flight Future',
          );
          await first;
        },
      );
    },
  );

  group('devices getter caching (comms-harden #28)', () {
    test(
      'repeat getter calls return the same list instance until a mutation',
      () async {
        final service = _ManualDiscoveryService();
        final controller = DeviceController([service]);
        await controller.initialize();

        service.emit([
          _FakeDevice(
            deviceId: 'AA:11:11:11:11:11',
            name: 'DE1',
            type: DeviceType.machine,
          ),
        ]);
        await Future<void>.delayed(Duration.zero);

        final first = controller.devices;
        final second = controller.devices;
        expect(
          identical(first, second),
          isTrue,
          reason: 'cache should return the same instance on a hot call',
        );

        service.emit(const []);
        await Future<void>.delayed(Duration.zero);

        final afterMutation = controller.devices;
        expect(
          identical(first, afterMutation),
          isFalse,
          reason: 'cache must rebuild after a device-list mutation',
        );
      },
    );
  });

  group('deviceAttached aggregation', () {
    test('forwards attach edges from a notifying service', () async {
      final notifier = _AttachNotifyingDiscoveryService();
      final controller = DeviceController([notifier]);
      await controller.initialize();

      final seen = <DeviceAttachedEvent>[];
      final sub = controller.deviceAttached.listen(seen.add);

      notifier.attach(
        const DeviceAttachedEvent(
          deviceId: 'usb-2e8a-a-8549628789ABCDEF',
          name: 'DE1',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(1));
      expect(seen.single.deviceId, 'usb-2e8a-a-8549628789ABCDEF');
      await sub.cancel();
    });

    test('a service that cannot be notified (BLE, Wi-Fi, simulated) never '
        'emits', () async {
      final controller = DeviceController([_ManualDiscoveryService()]);
      await controller.initialize();

      final seen = <DeviceAttachedEvent>[];
      final sub = controller.deviceAttached.listen(seen.add);
      await Future<void>.delayed(Duration.zero);

      expect(seen, isEmpty);
      await sub.cancel();
    });

    test('does not replay a past attach to a late subscriber', () async {
      final notifier = _AttachNotifyingDiscoveryService();
      final controller = DeviceController([notifier]);
      await controller.initialize();

      notifier.attach(const DeviceAttachedEvent(deviceId: 'gone-again'));
      await Future<void>.delayed(Duration.zero);

      final seen = <DeviceAttachedEvent>[];
      final sub = controller.deviceAttached.listen(seen.add);
      await Future<void>.delayed(Duration.zero);

      expect(seen, isEmpty);
      await sub.cancel();
    });

    test('dispose cancels the notifier aggregation subscription', () async {
      final notifier = _AttachNotifyingDiscoveryService();
      final controller = DeviceController([notifier]);
      await controller.initialize();
      expect(notifier.hasAttachListener, isTrue);

      controller.dispose();

      expect(notifier.hasAttachListener, isFalse);
    });

    test(
      'dispose during initialization prevents notifier subscription',
      () async {
        final initialization = Completer<void>();
        final notifier = _AttachNotifyingDiscoveryService(
          initialization: initialization.future,
        );
        final controller = DeviceController([notifier]);

        final initializing = controller.initialize();
        controller.dispose();
        initialization.complete();
        await initializing;

        expect(notifier.hasAttachListener, isFalse);
      },
    );

    test('an attach emitted during a service initialize is not lost', () async {
      final notifier = _AttachNotifyingDiscoveryService(
        emitAttachInInitialize: true,
      );
      final controller = DeviceController([notifier]);
      final seen = <DeviceAttachedEvent>[];
      final sub = controller.deviceAttached.listen(seen.add);

      await controller.initialize();
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(1));
      expect(seen.single.deviceId, 'startup-usb');
      await sub.cancel();
    });
  });

  group('disconnect tracking keys (comms-harden #20)', () {
    test(
      'two devices with same name but different IDs do not collide on disconnect',
      () async {
        final service = _ManualDiscoveryService();
        final telemetry = _RecordingTelemetry();
        final controller = DeviceController([service])
          ..telemetryService = telemetry;
        await controller.initialize();

        final a = _FakeDevice(
          deviceId: 'AA:11:11:11:11:11',
          name: 'DE1',
          type: DeviceType.machine,
        );
        final b = _FakeDevice(
          deviceId: 'BB:22:22:22:22:22',
          name: 'DE1',
          type: DeviceType.machine,
        );

        service.emit([a, b]);
        await Future<void>.delayed(Duration.zero);

        service.emit([a]);
        await Future<void>.delayed(Duration.zero);

        service.emit([a, b]);
        await Future<void>.delayed(Duration.zero);

        expect(
          telemetry.customKeys,
          contains('reconnection_duration_${b.deviceId}'),
        );
        expect(
          telemetry.customKeys,
          isNot(contains('reconnection_duration_${a.deviceId}')),
        );
      },
    );

    test(
      'device returning with a different advertised name is still matched by id',
      () async {
        final service = _ManualDiscoveryService();
        final telemetry = _RecordingTelemetry();
        final controller = DeviceController([service])
          ..telemetryService = telemetry;
        await controller.initialize();

        final before = _FakeDevice(
          deviceId: 'CC:33:33:33:33:33',
          name: 'DE1',
          type: DeviceType.machine,
        );
        final afterFirmware = _FakeDevice(
          deviceId: 'CC:33:33:33:33:33',
          name: 'DE1Pro',
          type: DeviceType.machine,
        );

        service.emit([before]);
        await Future<void>.delayed(Duration.zero);
        service.emit(const []);
        await Future<void>.delayed(Duration.zero);
        service.emit([afterFirmware]);
        await Future<void>.delayed(Duration.zero);

        expect(
          telemetry.customKeys,
          contains('reconnection_duration_${before.deviceId}'),
        );
      },
    );

    test('telemetry device_<id>_type key uses deviceId, not name', () async {
      final service = _ManualDiscoveryService();
      final telemetry = _RecordingTelemetry();
      final controller = DeviceController([service])
        ..telemetryService = telemetry;
      await controller.initialize();

      final a = _FakeDevice(
        deviceId: 'AA:11:11:11:11:11',
        name: 'DE1',
        type: DeviceType.machine,
      );
      final b = _FakeDevice(
        deviceId: 'BB:22:22:22:22:22',
        name: 'DE1',
        type: DeviceType.scale,
      );

      service.emit([a, b]);
      await Future<void>.delayed(Duration.zero);

      expect(telemetry.customKeys, contains('device_${a.deviceId}_type'));
      expect(telemetry.customKeys, contains('device_${b.deviceId}_type'));
      expect(telemetry.customKeys['device_${a.deviceId}_type'], 'machine');
      expect(telemetry.customKeys['device_${b.deviceId}_type'], 'scale');
    });
  });

  group('tryQuickConnect', () {
    test('returns null when all services return null', () async {
      final service = _ManualDiscoveryService();
      final controller = DeviceController([service]);
      await controller.initialize();

      const remembered = RememberedDevice(
        id: 'AA:11:11:11:11:11',
        name: 'DE1',
        type: DeviceType.machine,
        implementation: DeviceImplementation.unifiedDe1,
        transportType: TransportType.ble,
      );
      final result = await controller.tryQuickConnect(remembered);
      expect(result, isNull);
    });

    test('returns first non-null device from services', () async {
      final device = _FakeDevice(
        deviceId: 'AA:11:11:11:11:11',
        name: 'DE1',
        type: DeviceType.machine,
      );
      final service = _QuickConnectService(device);
      final controller = DeviceController([service]);
      await controller.initialize();

      const remembered = RememberedDevice(
        id: 'AA:11:11:11:11:11',
        name: 'DE1',
        type: DeviceType.machine,
        implementation: DeviceImplementation.unifiedDe1,
        transportType: TransportType.ble,
      );
      final result = await controller.tryQuickConnect(remembered);
      expect(result, same(device));
      expect(service.callCount, 1);
    });

    test('catches service exception and continues to next service', () async {
      final device = _FakeDevice(
        deviceId: 'BB:22:22:22:22:22',
        name: 'DE1',
        type: DeviceType.machine,
      );
      final throwing = _ThrowingQuickConnectService();
      final good = _QuickConnectService(device);
      final controller = DeviceController([throwing, good]);
      await controller.initialize();

      const remembered = RememberedDevice(
        id: 'BB:22:22:22:22:22',
        name: 'DE1',
        type: DeviceType.machine,
      );
      final result = await controller.tryQuickConnect(remembered);
      expect(result, same(device));
    });
  });

  group('attach probe routing', () {
    test('routes only to the originating capable service', () async {
      final origin = _AttachProbeService();
      final other = _AttachProbeService();
      final plain = _ManualDiscoveryService();
      final controller = DeviceController([origin, other, plain]);
      await controller.initialize();

      final event = const DeviceAttachedEvent(deviceId: 'usb-2e8a-a-1234');
      origin.emitAttach(event);
      await Future<void>.delayed(Duration.zero);

      final result = await controller.connectAttachedMachine(event);

      expect(result, isA<AttachProbeConnected>());
      expect(origin.probeCalls, 1);
      expect(other.probeCalls, 0);
      controller.dispose();
    });

    test('events not seen by the controller are unavailable', () async {
      final origin = _AttachProbeService();
      final controller = DeviceController([origin]);
      await controller.initialize();

      final result = await controller.connectAttachedMachine(
        const DeviceAttachedEvent(deviceId: 'usb-unknown'),
      );

      expect(result, isA<AttachProbeUnavailable>());
      expect(origin.probeCalls, 0);
      controller.dispose();
    });

    test('events from a notifier-only service are unavailable', () async {
      final notifierOnly = _AttachNotifierOnlyService();
      final capable = _AttachProbeService();
      final controller = DeviceController([notifierOnly, capable]);
      await controller.initialize();

      final event = const DeviceAttachedEvent(deviceId: 'usb-2e8a-a-1234');
      notifierOnly.emitAttach(event);
      await Future<void>.delayed(Duration.zero);

      final result = await controller.connectAttachedMachine(event);

      expect(result, isA<AttachProbeUnavailable>());
      expect(capable.probeCalls, 0);
      controller.dispose();
    });
  });
}

class _QuickConnectService extends _ManualDiscoveryService {
  final Device? _result;
  int callCount = 0;

  _QuickConnectService(this._result);

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async {
    callCount++;
    return _result;
  }
}

class _ThrowingQuickConnectService extends _ManualDiscoveryService {
  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async {
    throw StateError('quick-connect failed');
  }
}

class _FakeMachine implements De1Interface {
  @override
  final String deviceId;

  _FakeMachine(this.deviceId);

  @override
  String get name => 'DE1';

  @override
  DeviceType get type => DeviceType.machine;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.serial;

  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);

  @override
  Stream<MachineSnapshot> get currentSnapshot => const Stream.empty();

  @override
  Stream<bool> get ready => const Stream.empty();

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _AttachProbeService extends _ManualDiscoveryService
    implements DeviceAttachNotifier, UsbAttachProbe {
  final _attachEvents = StreamController<DeviceAttachedEvent>.broadcast(
    sync: true,
  );
  int probeCalls = 0;

  @override
  Stream<DeviceAttachedEvent> get deviceAttached => _attachEvents.stream;

  void emitAttach(DeviceAttachedEvent event) => _attachEvents.add(event);

  @override
  Future<AttachProbeResult> connectAttachedMachine(
    DeviceAttachedEvent event,
  ) async {
    probeCalls++;
    return AttachProbeConnected(_FakeMachine(event.deviceId ?? 'usb'));
  }
}

class _AttachNotifierOnlyService extends _ManualDiscoveryService
    implements DeviceAttachNotifier {
  final _attachEvents = StreamController<DeviceAttachedEvent>.broadcast(
    sync: true,
  );

  @override
  Stream<DeviceAttachedEvent> get deviceAttached => _attachEvents.stream;

  void emitAttach(DeviceAttachedEvent event) => _attachEvents.add(event);
}
