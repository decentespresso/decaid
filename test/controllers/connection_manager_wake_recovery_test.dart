import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_state_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/remembered_devices_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_virtual_scale.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_device_scanner.dart';
import '../helpers/mock_scale_controller.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_de1.dart';
import '../helpers/test_scale.dart';

class _Storage extends Fake implements StorageService {}

class _WakeScaleController extends MockScaleController {
  @override
  ConnectionState get currentConnectionState => connectionStateSubject.value;

  @override
  TestScale connectedScale() {
    if (currentConnectionState != ConnectionState.connected) {
      throw StateError('No connected scale');
    }
    return lastConnectedScale! as TestScale;
  }
}

class _Bengle extends TestDe1 implements BengleInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _WakeHarness {
  final FakeAsync time;
  final scanner = MockDeviceScanner();
  final service = MockSettingsService();
  final ScaleController scales;
  late final settings = SettingsController(service);
  late final de1 = MockDe1Controller(
    controller: DeviceController([MockDeviceDiscoveryService()]),
  );
  late final remembered = RememberedDevicesController(
    machineConnections: const Stream.empty(),
    scaleConnections: const Stream.empty(),
    settings: service,
  );
  late final manager = ConnectionManager(
    deviceScanner: scanner,
    de1Controller: de1,
    scaleController: scales,
    settingsController: settings,
    rememberedDevices: remembered,
  );
  final TestDe1 machine;
  final devices = <TestScale>[];
  De1StateManager? displayManager;

  _WakeHarness(this.time, {TestDe1? machine, ScaleController? scales})
    : machine = machine ?? TestDe1(),
      scales = scales ?? _WakeScaleController();

  void start({
    String? preferred,
    bool watch = false,
    TransportType? transport,
    bool withDisplayManager = false,
  }) {
    scanner.supportsWatch = watch;
    if (transport != null) {
      service.setRememberedDevices(
        RememberedDevice.encodeList([
          RememberedDevice(
            id: preferred!,
            name: 'Scale',
            type: DeviceType.scale,
            transportType: transport,
          ),
        ]),
      );
    }
    settings.loadSettings();
    remembered.initialize();
    time.flushMicrotasks();
    settings.setPreferredScaleId(preferred);
    settings.setScalePowerMode(ScalePowerMode.disconnect);
    time.flushMicrotasks();
    manager.snapshotStalenessTimeout = const Duration(minutes: 10);
    if (withDisplayManager) {
      displayManager = De1StateManager(
        de1Controller: de1,
        scaleController: scales,
        workflowController: WorkflowController(),
        persistenceController: PersistenceController(
          storageService: _Storage(),
        ),
        settingsController: settings,
        connectionManager: manager,
        navigatorKey: GlobalKey<NavigatorState>(),
      );
    }
    de1.de1Subject.add(machine);
    time.flushMicrotasks();
    machine.emitStateAndSubstate(MachineState.sleeping, MachineSubstate.idle);
    time.flushMicrotasks();
  }

  TestScale scale(String id) {
    final scale = TestScale(deviceId: id);
    devices.add(scale);
    return scale;
  }

  void wake() {
    machine.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
    time.flushMicrotasks();
  }

  void elapse(Duration duration) {
    time.elapse(duration);
    time.flushMicrotasks();
  }

  void dispose() {
    displayManager?.dispose();
    manager.dispose();
    remembered.dispose();
    scales.dispose();
    machine.dispose();
    de1.de1Subject.close();
    scanner.dispose();
    for (final device in devices) {
      device.dispose();
    }
    time.flushMicrotasks();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void run(void Function(_WakeHarness) body) {
    fakeAsync((time) {
      final h = _WakeHarness(time);
      try {
        body(h);
      } finally {
        h.dispose();
      }
    });
  }

  test('wake recovery 1: missing scale waits the full settling interval', () {
    run((h) {
      h.start();
      h.wake();
      expect(h.scanner.scanCallCount, 0);
      h.elapse(const Duration(milliseconds: 2999));
      expect(h.scanner.scanCallCount, 0);
      h.elapse(const Duration(milliseconds: 1));
      expect(h.scanner.scanCallCount, 1);
    });
  });

  test(
    'wake recovery 2: primary connects during settling, no stale request',
    () {
      run((h) {
        h.start(withDisplayManager: true);
        h.wake();
        h.elapse(const Duration(seconds: 1));
        h.scales.connectToScale(h.scale('arrived-during-settling'));
        h.elapse(Duration.zero);
        expect(h.scales.currentConnectionState, ConnectionState.connected);
        h.elapse(const Duration(seconds: 2));
        expect(h.scanner.scanCallCount, 0);
        expect(h.scales.connectedScale().deviceId, 'arrived-during-settling');
      });
    },
  );

  test('wake recovery 3: preferred BLE watch never competes with a burst', () {
    run((h) {
      h.start(
        preferred: 'ble-scale',
        watch: true,
        transport: TransportType.ble,
      );
      h.wake();
      expect(h.scanner.watchActive, isTrue);
      final starts = h.scanner.startWatchCallCount;
      final stops = h.scanner.stopWatchCallCount;
      h.elapse(const Duration(seconds: 9));
      expect(h.scanner.watchActive, isTrue);
      expect(h.scanner.startWatchCallCount, starts);
      expect(h.scanner.stopWatchCallCount, stops);
      expect(h.scanner.scanCallCount, 0);
    });
  });

  test('wake recovery 4: no preference discovers scales for the picker', () {
    run((h) {
      h.start(watch: true);
      h.scanner.addDevice(h.scale('one'));
      h.scanner.addDevice(h.scale('two'));
      h.wake();
      h.elapse(const Duration(seconds: 3));
      expect(h.scanner.scanCallCount, 1);
      expect(
        h.manager.currentStatus.pendingAmbiguity,
        AmbiguityReason.scalePicker,
      );
      expect(h.scanner.startWatchCallCount, 0);
    });
  });

  for (final transport in [TransportType.serial, TransportType.wifi]) {
    test(
      'wake recovery 5: remembered ${transport.name} uses scale-only fallback',
      () {
        run((h) {
          h.start(preferred: 'preferred', watch: true, transport: transport);
          h.wake();
          expect(h.manager.supportsBackgroundScaleWatch, isFalse);
          expect(h.scanner.scanCallCount, 0);
          h.elapse(const Duration(seconds: 3));
          expect(h.scanner.scanCallCount, 1);
          expect(h.scanner.startWatchCallCount, 0);
          expect(h.de1.connectCalls, isEmpty);
          expect(h.manager.scaleReconnectScheduled, isTrue);
        });
      },
    );
  }

  test('wake recovery 6: unsupported watch retains burst and backoff', () {
    run((h) {
      h.start(preferred: 'preferred');
      h.wake();
      h.elapse(const Duration(seconds: 3));
      expect(h.scanner.scanCallCount, 1);
      expect(h.manager.scaleReconnectScheduled, isTrue);
      h.elapse(const Duration(seconds: 20));
      expect(h.scanner.scanCallCount, greaterThan(1));
      expect(h.scanner.startWatchCallCount, 0);
    });
  });

  test('wake recovery 7: unavailable watch keeps the backoff fallback', () {
    run((h) {
      h.start(preferred: 'preferred', watch: true);
      h.scanner.failNextWatchWith = StateError('watch unavailable');
      h.wake();
      expect(h.manager.scaleReconnectScheduled, isTrue);
      expect(h.scanner.watchActive, isFalse);
      h.scanner.failNextWatchWith = StateError('still unavailable');
      h.elapse(const Duration(seconds: 3));
      expect(h.scanner.scanCallCount, 0);
      expect(h.manager.scaleReconnectScheduled, isTrue);
      h.elapse(const Duration(seconds: 2));
      expect(h.scanner.scanCallCount, 1);
    });
  });

  test('wake recovery 8: Bengle integrated scale keeps precedence', () {
    fakeAsync((time) {
      final scales = MockScaleController();
      final h = _WakeHarness(time, machine: _Bengle(), scales: scales);
      try {
        h.start(preferred: 'external', watch: true);
        h.wake();
        h.de1.adoptDevice(h.machine);
        h.manager.connect(scaleOnly: true);
        time.flushMicrotasks();
        time.elapse(Duration.zero);
        time.flushMicrotasks();
        expect(scales.connectCalls.single, isA<BengleVirtualScale>());
        final scans = h.scanner.scanCallCount;
        h.machine.emitStateAndSubstate(
          MachineState.sleeping,
          MachineSubstate.idle,
        );
        time.flushMicrotasks();
        h.scanner.addDevice(h.scale('external'));
        h.wake();
        h.elapse(const Duration(seconds: 9));
        expect(scales.connectCalls, hasLength(1));
        expect(h.scanner.startWatchCallCount, 0);
        expect(h.scanner.scanCallCount, scans);
      } finally {
        h.dispose();
      }
    });
  });
}
