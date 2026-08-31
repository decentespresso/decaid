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
import 'package:rxdart/subjects.dart';

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
  List<AttachProbeResult> probeResults = const [];
  int probeCallCount = 0;
  final List<DeviceAttachedEvent> probeEvents = [];

  Completer<void>? probeGate;
  final Completer<void> probeStarted = Completer<void>();

  Object? probeError;
  Completer<void>? quickConnectGate;

  @override
  Future<AttachProbeResult> connectAttachedMachine(
    DeviceAttachedEvent event,
  ) async {
    probeCallCount++;
    probeEvents.add(event);
    final result = probeCallCount <= probeResults.length
        ? probeResults[probeCallCount - 1]
        : probeResult;
    if (!probeStarted.isCompleted) probeStarted.complete();
    final gate = probeGate;
    if (gate != null) await gate.future;
    final error = probeError;
    if (error != null) throw error;
    return result;
  }

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async {
    quickConnectCallCount++;
    final gate = quickConnectGate;
    if (gate != null) await gate.future;
    return quickConnectResult;
  }
}

class _FakeDe1 implements De1Interface {
  final _snapshots = StreamController<MachineSnapshot>.broadcast();
  final _connectionState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );

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

  Completer<void>? connectGate;
  Completer<void>? disconnectGate;
  bool failConnect = false;
  int disconnectCalls = 0;
  int onConnectCalls = 0;

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Stream<MachineSnapshot> get currentSnapshot => _snapshots.stream;

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
    final gate = disconnectGate;
    if (gate != null) await gate.future;
    _connectionState.add(ConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    await _snapshots.close();
    await _connectionState.close();
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

    test('attach probe reports connectingMachine while the USB connection '
        'is in progress', () async {
      probeScanner.probeResult = AttachProbeConnected(
        _FakeDe1(deviceId: 'usb-machine-id'),
      );
      probeScanner.probeGate = Completer<void>();
      // Seed a retryable machine error so the stale-Retry symptom is
      // reproducible: entering connectingMachine must clear it.
      manager.reportError(
        ConnectionError(
          kind: ConnectionErrorKind.machineConnectFailed,
          severity: ConnectionErrorSeverity.error,
          timestamp: DateTime.now().toUtc(),
          deviceId: 'usb-machine-id',
          deviceName: 'DE1',
          message: 'Attached machine DE1 failed to connect.',
        ),
      );
      expect(manager.currentStatus.error, isNotNull);

      probeScanner.attach();
      await probeScanner.probeStarted.future;

      // The USB probe is still inside connectAttachedMachine() (the gate
      // is unresolved); the public status must already say a machine
      // connection is in progress and the stale Retry error must be gone.
      expect(manager.currentStatus.phase, ConnectionPhase.connectingMachine);
      expect(manager.currentStatus.error, isNull);

      probeScanner.probeGate!.complete();
      await Future<void>.delayed(Duration.zero);

      expect(probeScanner.probeCallCount, 1);
      expect(probeScanner.scanCallCount, 0);
      expect(probeScanner.quickConnectCallCount, 0);
      expect(settings.preferredMachineId, 'usb-machine-id');
      expect(manager.currentStatus.phase, ConnectionPhase.ready);
    });

    test('unsupported probe restores an interrupted machine picker', () async {
      probeScanner.addDevice(_FakeDe1(deviceId: 'de1-a'));
      probeScanner.addDevice(_FakeDe1(deviceId: 'de1-b'));
      probeScanner.probeResult = const AttachProbeUnsupported();

      await manager.connect();
      await Future<void>.delayed(Duration.zero);

      expect(
        manager.currentStatus.pendingAmbiguity,
        AmbiguityReason.machinePicker,
      );

      probeScanner.attach();
      await Future<void>.delayed(Duration.zero);

      expect(probeScanner.probeCallCount, 1);
      expect(manager.currentStatus.phase, ConnectionPhase.idle);
      expect(
        manager.currentStatus.pendingAmbiguity,
        AmbiguityReason.machinePicker,
      );
    });

    test('adoption failure after the machine connected settles to ready, '
        'not idle', () async {
      probeScanner.probeResult = AttachProbeConnected(
        _FakeDe1(deviceId: 'usb-machine-id'),
      );
      settingsService.failSetPreferredMachineId = true;

      final phases = <ConnectionPhase>[];
      var seenConnecting = false;
      final sub = manager.status.listen((s) {
        if (s.phase == ConnectionPhase.connectingMachine) {
          seenConnecting = true;
        }
        if (seenConnecting) phases.add(s.phase);
      });

      await attachAndSettle();
      // The failed adoption falls back to the preferred-machine attempt
      // (see 'an adoption failure still completes the latch lifecycle');
      // neither that nor the probe's own cleanup may drop a genuinely
      // connected machine back to idle.
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(probeScanner.probeCallCount, 1);
      expect(phases, isNot(contains(ConnectionPhase.idle)));
      expect(manager.currentStatus.phase, ConnectionPhase.ready);
      expect(manager.currentStatus.pendingAmbiguity, isNull);
    });

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

    test('a throwing attach probe completes the latch lifecycle and leaves '
        'recovery armed', () async {
      await settings.setPreferredMachineId('ble-machine-id');
      probeScanner.probeError = Exception('usb transport failure');

      await attachAndSettle();
      await Future<void>.delayed(Duration.zero);

      expect(probeScanner.probeCallCount, 1);
      // The probe exception falls back to the preferred-machine attempt;
      // the latch must not gate recovery scheduling afterwards.
      expect(manager.machineRecoveryActive, isTrue);
      expect(manager.machineReconnectFailures, 1);
    });

    test('a USB latch during quick-connect defers the fallback scan until '
        'the probe runs', () async {
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
      probeScanner.probeResult = AttachProbeConnected(
        _FakeDe1(deviceId: 'usb-machine-id'),
      );
      probeScanner.quickConnectResult = null;
      probeScanner.quickConnectGate = Completer<void>();
      manager = ConnectionManager(
        deviceScanner: probeScanner,
        de1Controller: actualDe1Controller,
        scaleController: scaleController,
        settingsController: settings,
        rememberedDevices: remembered,
        deviceAttachSettleDelay: Duration.zero,
      );
      manager.machineReconnectBaseDelay = const Duration(days: 1);

      // Remembered quick-connect is in flight...
      final connecting = manager.connect();
      await Future<void>.delayed(Duration.zero);
      expect(probeScanner.quickConnectCallCount, 1);
      expect(probeScanner.scanCallCount, 0);

      // ...when USB intent latches and settles while it is still
      // pending; the queued attach stops a scan that does not exist yet.
      probeScanner.attach();
      await Future<void>.delayed(Duration.zero);

      // Quick-connect misses; the fallback automatic scan must not
      // start while the latch is active.
      probeScanner.quickConnectGate!.complete();
      await connecting;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(probeScanner.scanCallCount, 0);
      expect(probeScanner.probeCallCount, 1);
      expect(settings.preferredMachineId, 'usb-machine-id');
      expect(manager.currentStatus.phase, ConnectionPhase.ready);
      remembered.dispose();
    });

    test(
      'attach during an automatic preferred-BLE scan supersedes the scan',
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

        // Preferred BLE machine appears mid-scan; the latch must block it.
        probeScanner.addDevice(_FakeDe1(deviceId: 'ble-machine-id'));
        await Future<void>.delayed(Duration.zero);
        probeScanner.completeScan();
        await connecting;

        expect(probeScanner.probeCallCount, 1);
        expect(probeScanner.stopScanCallCount, greaterThan(0));
        expect(settings.preferredMachineId, 'usb-machine-id');
        expect(manager.currentStatus.phase, ConnectionPhase.ready);
      },
    );

    test('attach while a preferred-BLE connect is in flight releases BLE '
        'and adopts USB', () async {
      await settings.setPreferredMachineId('ble-machine-id');
      final bleMachine = _FakeDe1(deviceId: 'ble-machine-id')
        ..connectGate = Completer<void>();
      probeScanner.addDevice(bleMachine);
      probeScanner.probeResult = AttachProbeConnected(
        _FakeDe1(deviceId: 'usb-machine-id'),
      );

      final connecting = manager.connect();
      await probeScanner.scanningStream.firstWhere((scanning) => scanning);
      await Future<void>.delayed(Duration.zero);
      probeScanner.attach();
      await Future<void>.delayed(Duration.zero);

      // BLE connect completes inside the settle window.
      bleMachine.connectGate!.complete();
      await connecting;

      expect(probeScanner.probeCallCount, 1);
      expect(bleMachine.disconnectCalls, 1);
      expect(settings.preferredMachineId, 'usb-machine-id');
      expect(manager.currentStatus.phase, ConnectionPhase.ready);
    });

    test('settle expiry during the superseded connect window still queues '
        'the attach', () async {
      await manager.dispose();
      await settings.setPreferredMachineId('ble-machine-id');
      final bleMachine = _FakeDe1(deviceId: 'ble-machine-id')
        ..connectGate = Completer<void>()
        ..disconnectGate = Completer<void>();
      probeScanner.addDevice(bleMachine);
      probeScanner.probeResult = AttachProbeConnected(
        _FakeDe1(deviceId: 'usb-machine-id'),
      );
      final actualDe1Controller = De1Controller(
        controller: DeviceController([discovery]),
      );
      manager = ConnectionManager(
        deviceScanner: probeScanner,
        de1Controller: actualDe1Controller,
        scaleController: scaleController,
        settingsController: settings,
        deviceAttachSettleDelay: const Duration(milliseconds: 50),
      );
      manager.machineReconnectBaseDelay = const Duration(days: 1);

      final connecting = manager.connect();
      await probeScanner.scanningStream.firstWhere((scanning) => scanning);
      await Future<void>.delayed(Duration.zero);
      probeScanner.attach();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(probeScanner.probeCallCount, 0);

      // BLE connect completes: machine now connected, but the intentional
      // release is still pending on the disconnect gate. Settle expiry
      // must queue the attach rather than treat the transient machine as
      // an established connection.
      bleMachine.connectGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(probeScanner.probeCallCount, 0);

      bleMachine.disconnectGate!.complete();
      await connecting;

      expect(probeScanner.probeCallCount, 1);
      expect(bleMachine.disconnectCalls, 1);
      expect(settings.preferredMachineId, 'usb-machine-id');
      expect(manager.currentStatus.phase, ConnectionPhase.ready);
    });

    test('attach while remembered BLE quick-connect is in flight releases '
        'BLE and adopts USB', () async {
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
      probeScanner.quickConnectGate = Completer<void>();
      probeScanner.quickConnectResult = _FakeDe1(deviceId: 'pref-de1');
      probeScanner.probeResult = AttachProbeConnected(
        _FakeDe1(deviceId: 'usb-machine-id'),
      );
      manager = ConnectionManager(
        deviceScanner: probeScanner,
        de1Controller: actualDe1Controller,
        scaleController: scaleController,
        settingsController: settings,
        rememberedDevices: remembered,
        deviceAttachSettleDelay: Duration.zero,
      );
      manager.machineReconnectBaseDelay = const Duration(days: 1);

      final connecting = manager.connect();
      await Future<void>.delayed(Duration.zero);
      expect(probeScanner.quickConnectCallCount, 1);
      probeScanner.attach();
      await Future<void>.delayed(Duration.zero);

      probeScanner.quickConnectGate!.complete();
      await connecting;

      expect(probeScanner.probeCallCount, 1);
      expect(settings.preferredMachineId, 'usb-machine-id');
      expect(manager.currentStatus.phase, ConnectionPhase.ready);
      probeScanner.quickConnectGate = null;
      remembered.dispose();
    });

    test('startup attach hint before connect() prevents remembered '
        'quick-connect and adopts USB first', () async {
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
      probeScanner.quickConnectResult = _FakeDe1(deviceId: 'pref-de1');
      probeScanner.probeResult = AttachProbeConnected(
        _FakeDe1(deviceId: 'usb-machine-id'),
      );
      manager = ConnectionManager(
        deviceScanner: probeScanner,
        de1Controller: actualDe1Controller,
        scaleController: scaleController,
        settingsController: settings,
        rememberedDevices: remembered,
        deviceAttachSettleDelay: const Duration(milliseconds: 50),
      );
      manager.machineReconnectBaseDelay = const Duration(days: 1);

      probeScanner.attach();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await manager.connect();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(probeScanner.quickConnectCallCount, 0);
      expect(probeScanner.scanCallCount, 0);
      expect(probeScanner.probeCallCount, 1);
      expect(settings.preferredMachineId, 'usb-machine-id');
      expect(manager.currentStatus.phase, ConnectionPhase.ready);
      remembered.dispose();
    });

    test(
      'a second latch during the probe preserves the replay obligation',
      () async {
        probeScanner.probeResult = const AttachProbeUnsupported();
        probeScanner.scanCompleter = Completer<void>();
        probeScanner.probeGate = Completer<void>();

        // An automatic no-preference scan is interrupted by the first
        // attach; the queued probe runs after the scan bails.
        final connecting = manager.connect();
        await probeScanner.scanningStream.firstWhere((scanning) => scanning);
        probeScanner.attach();
        await Future<void>.delayed(Duration.zero);
        probeScanner.completeScan();
        await probeScanner.probeStarted.future;

        // A second attach latches while the first probe is in flight; the
        // recorded replay obligation must survive this latch.
        probeScanner.attach();
        await Future<void>.delayed(Duration.zero);

        probeScanner.probeGate!.complete();
        await connecting;

        expect(probeScanner.probeCallCount, 2);
        expect(probeScanner.scanCallCount, 2);
        expect(settings.preferredMachineId, isNull);
        expect(manager.currentStatus.phase, ConnectionPhase.idle);
      },
    );

    test('a queued attach is probed before automatic replay', () async {
      final usbMachine = _FakeDe1(deviceId: 'usb-machine-id');
      final bleMachine = _FakeDe1(deviceId: 'ble-machine-id');
      probeScanner.probeResults = [
        const AttachProbeUnsupported(),
        AttachProbeConnected(usbMachine),
      ];
      probeScanner.probeGate = Completer<void>();
      probeScanner.scanCompleter = Completer<void>();

      final connecting = manager.connect();
      await probeScanner.scanningStream.firstWhere((scanning) => scanning);
      probeScanner.attach();
      await Future<void>.delayed(Duration.zero);
      probeScanner.completeScan();
      await probeScanner.probeStarted.future;

      probeScanner.attach();
      await Future<void>.delayed(Duration.zero);
      probeScanner.addDevice(bleMachine);
      probeScanner.probeGate!.complete();
      await connecting;
      await Future<void>.delayed(Duration.zero);

      expect(probeScanner.probeCallCount, 2);
      expect(bleMachine.onConnectCalls, 0);
      expect(settings.preferredMachineId, 'usb-machine-id');
    });

    test('an adoption failure still completes the latch lifecycle', () async {
      await settings.setPreferredMachineId('ble-machine-id');
      final usbMachine = _FakeDe1(deviceId: 'usb-machine-id');
      probeScanner.probeResult = AttachProbeConnected(usbMachine);
      settingsService.failSetPreferredMachineId = true;

      await attachAndSettle();
      await Future<void>.delayed(Duration.zero);

      expect(probeScanner.probeCallCount, 1);
      // The failed adoption falls back to the preferred-machine attempt;
      // the latch must not suppress that scan or later recovery.
      expect(probeScanner.scanCallCount, 1);
      expect(settingsService.preferredMachineIdWrites.last, 'usb-machine-id');

      // The adopted machine goes away; recovery scheduling must not be
      // gated by the latch either.
      await usbMachine.disconnect();
      await Future<void>.delayed(Duration.zero);
      expect(manager.machineReconnectFailures, 1);
    });

    test('unsupported probe clears the latch and resumes the interrupted '
        'automatic policy', () async {
      await settings.setPreferredMachineId('ble-machine-id');
      final bleMachine = _FakeDe1(deviceId: 'ble-machine-id')
        ..connectGate = Completer<void>();
      probeScanner.addDevice(bleMachine);
      probeScanner.probeResult = const AttachProbeUnsupported();

      final connecting = manager.connect();
      await probeScanner.scanningStream.firstWhere((scanning) => scanning);
      await Future<void>.delayed(Duration.zero);
      probeScanner.attach();
      await Future<void>.delayed(Duration.zero);

      bleMachine.connectGate!.complete();
      await connecting;

      expect(probeScanner.probeCallCount, 1);
      expect(bleMachine.disconnectCalls, 1);
      expect(bleMachine.onConnectCalls, 2);
      expect(settings.preferredMachineId, 'ble-machine-id');
    });

    test(
      'probe failure after releasing BLE reconnects it through recovery',
      () async {
        await settings.setPreferredMachineId('ble-machine-id');
        final bleMachine = _FakeDe1(deviceId: 'ble-machine-id')
          ..connectGate = Completer<void>();
        probeScanner.addDevice(bleMachine);
        probeScanner.probeResult = const AttachProbeFailed(
          deviceId: 'usb-machine-id',
          deviceName: 'DE1',
        );

        final connecting = manager.connect();
        await probeScanner.scanningStream.firstWhere((scanning) => scanning);
        await Future<void>.delayed(Duration.zero);
        probeScanner.attach();
        await Future<void>.delayed(Duration.zero);

        bleMachine.connectGate!.complete();
        await connecting;

        expect(probeScanner.probeCallCount, 1);
        expect(bleMachine.disconnectCalls, 1);
        expect(settings.preferredMachineId, 'ble-machine-id');
        expect(manager.machineRecoveryActive, isTrue);
      },
    );

    test('a failed automatic connect consumes the supersession marker; a '
        'later connect is not released', () async {
      await settings.setPreferredMachineId('ble-machine-id');
      final bleMachine = _FakeDe1(deviceId: 'ble-machine-id')
        ..connectGate = Completer<void>();
      probeScanner.addDevice(bleMachine);
      probeScanner.probeResult = const AttachProbeUnsupported();

      final connecting = manager.connect();
      await probeScanner.scanningStream.firstWhere((scanning) => scanning);
      await Future<void>.delayed(Duration.zero);
      probeScanner.attach();
      await Future<void>.delayed(Duration.zero);

      bleMachine.failConnect = true;
      bleMachine.connectGate!.complete();
      await connecting;
      expect(bleMachine.onConnectCalls, 2);

      bleMachine.failConnect = false;
      await manager.connect();

      expect(bleMachine.onConnectCalls, 3);
      expect(bleMachine.disconnectCalls, 0);
      expect(
        (await realDe1Controller.de1.firstWhere(
          (machine) => machine?.deviceId == 'ble-machine-id',
        )),
        isNotNull,
      );
    });

    test(
      'a direct explicit machine connect is not superseded while latched',
      () async {
        probeScanner.probeResult = const AttachProbeUnsupported();
        probeScanner.probeGate = Completer<void>();
        probeScanner.attach();
        await probeScanner.probeStarted.future;

        final bleMachine = _FakeDe1(deviceId: 'ble-machine-id');
        final result = await manager.connectMachine(bleMachine);

        expect(result.success, isTrue);
        expect(
          (await realDe1Controller.de1.firstWhere(
            (machine) => machine?.deviceId == 'ble-machine-id',
          )),
          isNotNull,
        );

        probeScanner.probeGate!.complete();
        await Future<void>.delayed(Duration.zero);
        expect(settings.preferredMachineId, 'ble-machine-id');
      },
    );

    test('an explicit connect overlapping a latched automatic scan is not '
        'superseded', () async {
      probeScanner.probeResult = const AttachProbeUnsupported();
      probeScanner.scanCompleter = Completer<void>();
      final bleMachine = _FakeDe1(deviceId: 'ble-machine-id')
        ..connectGate = Completer<void>();

      // An automatic no-preference scan is in flight...
      final connecting = manager.connect();
      await probeScanner.scanningStream.firstWhere((scanning) => scanning);

      // ...and a direct REST/WS connect for a BLE machine starts.
      final direct = manager.connectMachine(bleMachine);
      await Future<void>.delayed(Duration.zero);

      // USB intent latches while the explicit connect is in flight; the
      // ambient automatic state is still active, so the latch marks the
      // automatic attempt superseded. The explicit connect must not be
      // caught by that marker.
      probeScanner.attach();
      await Future<void>.delayed(Duration.zero);

      bleMachine.connectGate!.complete();
      final directResult = await direct;

      probeScanner.completeScan();
      await connecting;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(directResult.success, isTrue);
      expect(
        (await realDe1Controller.de1.firstWhere(
          (machine) => machine?.deviceId == 'ble-machine-id',
        )),
        isNotNull,
      );
      expect(settingsService.preferredMachineIdWrites, ['ble-machine-id']);
      expect(settings.preferredMachineId, 'ble-machine-id');
    });

    test('unsupported attach replays an interrupted no-preference '
        'automatic scan', () async {
      probeScanner.probeResult = const AttachProbeUnsupported();
      probeScanner.scanCompleter = Completer<void>();

      final connecting = manager.connect();
      await probeScanner.scanningStream.firstWhere((scanning) => scanning);
      probeScanner.attach();
      await Future<void>.delayed(Duration.zero);
      probeScanner.completeScan();
      await connecting;

      expect(probeScanner.probeCallCount, 1);
      expect(probeScanner.scanCallCount, 2);
      expect(settings.preferredMachineId, isNull);
      expect(manager.currentStatus.phase, ConnectionPhase.idle);
    });

    test(
      'a second USB attach during the resumed scan is not dropped',
      () async {
        probeScanner.probeResult = const AttachProbeUnsupported();
        probeScanner.scanCompleter = Completer<void>();

        final connecting = manager.connect();
        await probeScanner.scanningStream.firstWhere((scanning) => scanning);
        probeScanner.attach();
        await Future<void>.delayed(Duration.zero);
        probeScanner.completeScan();

        // The unsupported attach interrupts the no-preference automatic
        // scan and replays it; gate the resumed scan.
        probeScanner.scanCompleter = Completer<void>();
        await probeScanner.scanningStream.firstWhere((scanning) => scanning);

        // A real DE1 attach during the resumed scan must latch again
        // instead of being dropped by the coordinator's in-flight guard.
        probeScanner.probeResult = AttachProbeConnected(
          _FakeDe1(deviceId: 'usb-machine-id'),
        );
        probeScanner.attach();
        await Future<void>.delayed(Duration.zero);

        probeScanner.completeScan();
        await connecting;
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(probeScanner.probeCallCount, 2);
        expect(settings.preferredMachineId, 'usb-machine-id');
        expect(manager.currentStatus.phase, ConnectionPhase.ready);
      },
    );

    test(
      'suspending recovery for a USB attach preserves the backoff tier',
      () async {
        await settings.setPreferredMachineId('ble-machine-id');
        probeScanner.probeResult = const AttachProbeFailed(
          deviceId: 'usb-machine-id',
          deviceName: 'DE1',
        );

        await attachAndSettle();
        expect(manager.machineRecoveryActive, isTrue);
        expect(manager.machineReconnectFailures, 1);

        // The pending reconnect timer is cancelled and re-armed; the tier
        // must not advance because no reconnect attempt actually ran.
        probeScanner.probeResult = const AttachProbeUnsupported();
        await attachAndSettle();

        expect(manager.machineRecoveryActive, isTrue);
        expect(manager.machineReconnectFailures, 1);
      },
    );

    test(
      'a superseded in-flight connect does not persist its own preference',
      () async {
        final bleMachine = _FakeDe1(deviceId: 'ble-machine-id')
          ..connectGate = Completer<void>();
        probeScanner.addDevice(bleMachine);
        probeScanner.probeResult = AttachProbeConnected(
          _FakeDe1(deviceId: 'usb-machine-id'),
        );

        final connecting = manager.connect();
        await probeScanner.scanningStream.firstWhere((scanning) => scanning);
        await Future<void>.delayed(Duration.zero);
        probeScanner.attach();
        await Future<void>.delayed(Duration.zero);

        bleMachine.connectGate!.complete();
        await connecting;

        expect(probeScanner.probeCallCount, 1);
        expect(settingsService.preferredMachineIdWrites, ['usb-machine-id']);
        expect(settings.preferredMachineId, 'usb-machine-id');
      },
    );
  });
}
