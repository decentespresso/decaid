import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/remembered_devices_controller.dart';
import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_attach_notifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/usb_attach_probe.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_device_scanner.dart';
import '../helpers/mock_scale_controller.dart';
import '../helpers/mock_settings_service.dart';

class _AttachScanner extends MockDeviceScanner implements DeviceAttachNotifier {
  final _attachEvents = StreamController<DeviceAttachedEvent>.broadcast(
    sync: true,
  );

  @override
  Stream<DeviceAttachedEvent> get deviceAttached => _attachEvents.stream;

  void attach() => _attachEvents.add(const DeviceAttachedEvent());

  @override
  void dispose() {
    _attachEvents.close();
    super.dispose();
  }
}

class _ProbeScanner extends _AttachScanner implements UsbAttachProbe {
  AttachProbeResult probeResult = const AttachProbeUnsupported();
  int probeCallCount = 0;
  final List<DeviceAttachedEvent> probeEvents = [];

  Completer<void>? probeGate;
  final Completer<void> probeStarted = Completer<void>();

  @override
  Future<AttachProbeResult> connectAttachedMachine(
    DeviceAttachedEvent event,
  ) async {
    probeCallCount++;
    probeEvents.add(event);
    if (!probeStarted.isCompleted) probeStarted.complete();
    final gate = probeGate;
    if (gate != null) await gate.future;
    return probeResult;
  }
}

class _FakeDe1 implements De1Interface {
  final _snapshots = StreamController<MachineSnapshot>.broadcast();

  @override
  final String deviceId;

  @override
  String get name => 'DE1';

  @override
  DeviceType get type => DeviceType.machine;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.serial;

  _FakeDe1({this.deviceId = 'pref-de1'});

  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);

  @override
  Stream<MachineSnapshot> get currentSnapshot => _snapshots.stream;

  @override
  Stream<bool> get ready => const Stream.empty();

  @override
  Future<void> onConnect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {
    await _snapshots.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late _AttachScanner scanner;
  late MockDeviceDiscoveryService discovery;
  late MockDe1Controller de1Controller;
  late MockScaleController scaleController;
  late MockSettingsService settingsService;
  late SettingsController settings;
  late ConnectionManager manager;

  Future<void> waitForScan() async {
    await scanner.scanningStream.firstWhere((scanning) => scanning);
    await scanner.scanningStream.firstWhere((scanning) => !scanning);
  }

  setUp(() async {
    scanner = _AttachScanner();
    discovery = MockDeviceDiscoveryService();
    de1Controller = MockDe1Controller(
      controller: DeviceController([discovery]),
    );
    scaleController = MockScaleController();
    settingsService = MockSettingsService();
    settings = SettingsController(settingsService);
    await settings.loadSettings();
    manager = ConnectionManager(
      deviceScanner: scanner,
      de1Controller: de1Controller,
      scaleController: scaleController,
      settingsController: settings,
      deviceAttachSettleDelay: Duration.zero,
    );
    manager.machineReconnectBaseDelay = const Duration(days: 1);
  });

  tearDown(() async {
    await manager.dispose();
    scanner.dispose();
    discovery.dispose();
  });

  test(
    'BLE preference stays distinct until the USB machine is selected',
    () async {
      await settings.setPreferredMachineId('ble-machine-id');
      final usbMachine = _FakeDe1(deviceId: 'usb-machine-id');
      scanner.addDevice(usbMachine);
      scanner.mockAdapterState(AdapterState.poweredOff);

      await manager.scanAndConnect();

      expect(
        manager.currentStatus.pendingAmbiguity,
        AmbiguityReason.machinePicker,
      );
      expect(
        manager.currentStatus.foundMachines.single.deviceId,
        'usb-machine-id',
      );
      expect(settings.preferredMachineId, 'ble-machine-id');

      await manager.selectMachine(usbMachine);

      expect(settings.preferredMachineId, 'usb-machine-id');
    },
  );

  test('attach invokes current connection policy immediately', () async {
    await settings.setPreferredMachineId('pref-de1');
    scanner.addDevice(_FakeDe1());

    scanner.attach();
    await waitForScan();

    expect(scanner.scanCallCount, 1);
    expect(de1Controller.connectCalls.single.deviceId, 'pref-de1');
  });

  test('empty attempt leaves preferred-machine recovery armed', () async {
    await settings.setPreferredMachineId('pref-de1');

    scanner.attach();
    await waitForScan();
    await Future<void>.delayed(Duration.zero);

    expect(manager.machineRecoveryActive, isTrue);
    expect(scanner.scanCallCount, 1);
  });

  test('no preferred machine neither scans nor opens a picker', () async {
    scanner.attach();
    await Future<void>.delayed(Duration.zero);

    expect(scanner.scanCallCount, 0);
    expect(manager.machineRecoveryActive, isFalse);
    expect(manager.currentStatus.pendingAmbiguity, isNull);
  });

  test('connected machine ignores attach', () async {
    await settings.setPreferredMachineId('pref-de1');
    de1Controller.de1Subject.add(_FakeDe1());
    await de1Controller.de1.firstWhere((machine) => machine != null);

    scanner.attach();
    await Future<void>.delayed(Duration.zero);

    expect(scanner.scanCallCount, 0);
  });

  test('remembered-machine quick-connect is used before scanning', () async {
    await manager.dispose();
    await settings.setPreferredMachineId('pref-de1');
    settingsService.setRememberedDevices(
      RememberedDevice.encodeList([
        const RememberedDevice(
          id: 'pref-de1',
          name: 'DE1',
          type: DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.serial,
        ),
      ]),
    );
    final remembered = RememberedDevicesController(
      machineConnections: const Stream.empty(),
      scaleConnections: const Stream.empty(),
      settings: settingsService,
    );
    await remembered.initialize();
    final actualDe1Controller = De1Controller(
      controller: DeviceController([discovery]),
    );
    scanner.quickConnectResult = _FakeDe1();
    manager = ConnectionManager(
      deviceScanner: scanner,
      de1Controller: actualDe1Controller,
      scaleController: scaleController,
      settingsController: settings,
      rememberedDevices: remembered,
      deviceAttachSettleDelay: Duration.zero,
    );

    final ready = manager.status.firstWhere(
      (status) => status.phase == ConnectionPhase.ready,
    );
    scanner.attach();
    await ready;

    expect(scanner.quickConnectCallCount, 1);
    expect(scanner.scanCallCount, 0);
    remembered.dispose();
  });

  test('quick-connect failure falls back to the scan path', () async {
    await manager.dispose();
    await settings.setPreferredMachineId('pref-de1');
    settingsService.setRememberedDevices(
      RememberedDevice.encodeList([
        const RememberedDevice(
          id: 'pref-de1',
          name: 'DE1',
          type: DeviceType.machine,
          implementation: DeviceImplementation.unifiedDe1,
          transportType: TransportType.serial,
        ),
      ]),
    );
    final remembered = RememberedDevicesController(
      machineConnections: const Stream.empty(),
      scaleConnections: const Stream.empty(),
      settings: settingsService,
    );
    await remembered.initialize();
    scanner.addDevice(_FakeDe1());
    manager = ConnectionManager(
      deviceScanner: scanner,
      de1Controller: de1Controller,
      scaleController: scaleController,
      settingsController: settings,
      rememberedDevices: remembered,
      deviceAttachSettleDelay: Duration.zero,
    );

    scanner.attach();
    await waitForScan();

    expect(scanner.quickConnectCallCount, 1);
    expect(scanner.scanCallCount, 1);
    expect(de1Controller.connectCalls, hasLength(1));
    remembered.dispose();
  });

  test(
    'attach does not add work to an ordinary connect with queued scale-only',
    () async {
      await settings.setPreferredMachineId('pref-de1');
      scanner.addDevice(_FakeDe1());
      scanner.scanCompleter = Completer<void>();

      final ordinaryConnect = manager.connect();
      await scanner.scanningStream.firstWhere((scanning) => scanning);
      final scaleOnlyConnect = manager.connect(scaleOnly: true);
      scanner.attach();
      await Future<void>.delayed(Duration.zero);

      scanner.completeScan();
      await ordinaryConnect;
      await scaleOnlyConnect;

      expect(scanner.scanCallCount, 2);
    },
  );

  test(
    'scanner without attach capability produces no attach-triggered scan',
    () async {
      await manager.dispose();
      final scannerWithoutNotifier = MockDeviceScanner();
      manager = ConnectionManager(
        deviceScanner: scannerWithoutNotifier,
        de1Controller: de1Controller,
        scaleController: scaleController,
        settingsController: settings,
        deviceAttachSettleDelay: Duration.zero,
      );
      await settings.setPreferredMachineId('pref-de1');

      await Future<void>.delayed(Duration.zero);

      expect(scannerWithoutNotifier.scanCallCount, 0);
      scannerWithoutNotifier.dispose();
    },
  );

  group('probe-capable attach', () {
    late _ProbeScanner probeScanner;
    late De1Controller realDe1Controller;

    setUp(() {
      probeScanner = _ProbeScanner();
      realDe1Controller = De1Controller(
        controller: DeviceController([discovery]),
      );
      manager = ConnectionManager(
        deviceScanner: probeScanner,
        de1Controller: realDe1Controller,
        scaleController: scaleController,
        settingsController: settings,
        deviceAttachSettleDelay: Duration.zero,
      );
      manager.machineReconnectBaseDelay = const Duration(days: 1);
    });

    tearDown(() {
      probeScanner.dispose();
    });

    Future<void> attachAndSettle() async {
      probeScanner.attach();
      await Future<void>.delayed(Duration.zero);
    }

    test(
      'no preferred machine adopts a supported attached USB machine',
      () async {
        probeScanner.probeResult = AttachProbeConnected(
          _FakeDe1(deviceId: 'usb-machine-id'),
        );

        await attachAndSettle();

        expect(probeScanner.probeCallCount, 1);
        expect(probeScanner.scanCallCount, 0);
        expect(probeScanner.quickConnectCallCount, 0);
        expect(manager.currentStatus.pendingAmbiguity, isNull);
        expect(settings.preferredMachineId, 'usb-machine-id');
        expect(manager.currentStatus.phase, ConnectionPhase.ready);
      },
    );

    test('BLE preference loses to a supported attached USB machine', () async {
      await settings.setPreferredMachineId('ble-machine-id');
      probeScanner.probeResult = AttachProbeConnected(
        _FakeDe1(deviceId: 'usb-machine-id'),
      );

      await attachAndSettle();

      expect(probeScanner.scanCallCount, 0);
      expect(probeScanner.quickConnectCallCount, 0);
      expect(settings.preferredMachineId, 'usb-machine-id');
      expect(manager.currentStatus.phase, ConnectionPhase.ready);
    });

    test(
      'a different preferred USB machine loses to the attached machine',
      () async {
        await settings.setPreferredMachineId('usb-other-machine-id');
        probeScanner.probeResult = AttachProbeConnected(
          _FakeDe1(deviceId: 'usb-machine-id'),
        );

        await attachAndSettle();

        expect(settings.preferredMachineId, 'usb-machine-id');
        expect(manager.currentStatus.phase, ConnectionPhase.ready);
      },
    );

    test(
      'same-machine cross-transport preference produces the same outcome',
      () async {
        await settings.setPreferredMachineId('ble-1a86-55d3');
        probeScanner.probeResult = AttachProbeConnected(
          _FakeDe1(deviceId: 'usb-1a86-55d3'),
        );

        await attachAndSettle();

        expect(settings.preferredMachineId, 'usb-1a86-55d3');
        expect(manager.currentStatus.phase, ConnectionPhase.ready);
      },
    );

    test('unsupported USB device changes nothing', () async {
      await settings.setPreferredMachineId('ble-machine-id');
      probeScanner.probeResult = const AttachProbeUnsupported();

      await attachAndSettle();

      expect(probeScanner.probeCallCount, 1);
      expect(probeScanner.scanCallCount, 0);
      expect(settings.preferredMachineId, 'ble-machine-id');
      expect(manager.currentStatus.pendingAmbiguity, isNull);
      expect(manager.currentStatus.phase, ConnectionPhase.idle);
    });

    test(
      'failed attached machine resumes recovery and keeps preference',
      () async {
        await settings.setPreferredMachineId('ble-machine-id');
        probeScanner.probeResult = const AttachProbeFailed(
          deviceId: 'usb-machine-id',
          deviceName: 'DE1',
        );

        await attachAndSettle();

        expect(settings.preferredMachineId, 'ble-machine-id');
        expect(manager.machineRecoveryActive, isTrue);
        expect(manager.currentStatus.phase, ConnectionPhase.idle);
      },
    );

    test(
      'failed attached machine without preference surfaces the failure',
      () async {
        probeScanner.probeResult = const AttachProbeFailed(
          deviceId: 'usb-machine-id',
          deviceName: 'DE1',
        );

        await attachAndSettle();

        expect(settings.preferredMachineId, isNull);
        expect(manager.machineRecoveryActive, isFalse);
        expect(
          manager.currentStatus.error?.kind,
          ConnectionErrorKind.machineConnectFailed,
        );
        expect(manager.currentStatus.phase, ConnectionPhase.idle);
      },
    );

    test('connected machine ignores attach', () async {
      await settings.setPreferredMachineId('ble-machine-id');
      await realDe1Controller.connectToDe1(_FakeDe1());
      await realDe1Controller.de1.firstWhere((machine) => machine != null);

      await attachAndSettle();

      expect(probeScanner.probeCallCount, 0);
    });

    test(
      'attach during automatic scanning is queued, not dropped or parallel',
      () async {
        await settings.setPreferredMachineId('ble-machine-id');
        probeScanner.probeResult = AttachProbeConnected(
          _FakeDe1(deviceId: 'usb-machine-id'),
        );
        probeScanner.scanCompleter = Completer<void>();

        final connecting = manager.connect();
        await probeScanner.scanningStream.firstWhere((scanning) => scanning);
        probeScanner.attach();
        await Future<void>.delayed(Duration.zero);

        probeScanner.completeScan();
        await connecting;

        expect(probeScanner.probeCallCount, 1);
        expect(probeScanner.scanCallCount, 1);
        expect(settings.preferredMachineId, 'usb-machine-id');
        expect(manager.currentStatus.phase, ConnectionPhase.ready);
      },
    );

    test(
      'attach during an explicit scan waits for the scan to finish',
      () async {
        probeScanner.probeResult = AttachProbeConnected(
          _FakeDe1(deviceId: 'usb-machine-id'),
        );
        probeScanner.scanCompleter = Completer<void>();

        final scanning = manager.scanAndConnect();
        await probeScanner.scanningStream.firstWhere((scanning) => scanning);
        probeScanner.attach();
        await Future<void>.delayed(Duration.zero);

        probeScanner.completeScan();
        await scanning;

        expect(probeScanner.probeCallCount, 1);
        expect(probeScanner.scanCallCount, 1);
        expect(settings.preferredMachineId, 'usb-machine-id');
        expect(manager.currentStatus.phase, ConnectionPhase.ready);
      },
    );

    test(
      'explicit scan arriving during an attach probe drains afterwards',
      () async {
        probeScanner.probeResult = AttachProbeConnected(
          _FakeDe1(deviceId: 'usb-machine-id'),
        );
        probeScanner.probeGate = Completer<void>();
        probeScanner.attach();
        await probeScanner.probeStarted.future;

        final scanning = manager.scanAndConnect();
        probeScanner.probeGate!.complete();
        await scanning.timeout(const Duration(seconds: 5));

        expect(probeScanner.probeCallCount, 1);
        expect(probeScanner.scanCallCount, 1);
        expect(settings.preferredMachineId, 'usb-machine-id');
        expect(manager.currentStatus.phase, ConnectionPhase.ready);
      },
    );

    test(
      'scale-only connect arriving during an attach probe drains afterwards',
      () async {
        probeScanner.probeResult = AttachProbeConnected(
          _FakeDe1(deviceId: 'usb-machine-id'),
        );
        probeScanner.probeGate = Completer<void>();
        probeScanner.attach();
        await probeScanner.probeStarted.future;

        final scaleOnly = manager.connect(scaleOnly: true);
        probeScanner.probeGate!.complete();
        await scaleOnly.timeout(const Duration(seconds: 5));

        expect(probeScanner.probeCallCount, 1);
        expect(probeScanner.scanCallCount, 1);
        expect(settings.preferredMachineId, 'usb-machine-id');
        expect(manager.currentStatus.phase, ConnectionPhase.ready);
      },
    );

    test('unavailable probe falls back to preferred-machine policy', () async {
      await settings.setPreferredMachineId('ble-machine-id');
      probeScanner.probeResult = const AttachProbeUnavailable();

      await attachAndSettle();

      expect(probeScanner.probeCallCount, 1);
      expect(probeScanner.scanCallCount, 1);
      expect(settings.preferredMachineId, 'ble-machine-id');
    });

    test('unavailable probe without preference changes nothing', () async {
      probeScanner.probeResult = const AttachProbeUnavailable();

      await attachAndSettle();

      expect(probeScanner.probeCallCount, 1);
      expect(probeScanner.scanCallCount, 0);
      expect(settings.preferredMachineId, isNull);
      expect(manager.currentStatus.pendingAmbiguity, isNull);
    });
  });
}
