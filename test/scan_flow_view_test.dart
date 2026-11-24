import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scan_state_guardian.dart';
import 'package:reaprime/src/device_discovery_feature/scan_flow_view.dart';
import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/scan_report.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'helpers/mock_connection_manager.dart';
import 'helpers/mock_de1_controller.dart';
import 'helpers/mock_device_discovery_service.dart';
import 'helpers/mock_device_scanner.dart';
import 'helpers/mock_scale_controller.dart';
import 'helpers/mock_settings_service.dart';
import 'helpers/test_scale.dart';
import 'helpers/test_usb_hds.dart';

class _TrackingDeviceController extends DeviceController {
  int stopScanCalls = 0;

  _TrackingDeviceController(super.services);

  @override
  void stopScan() {
    stopScanCalls++;
    super.stopScan();
  }
}

const skipLabel = 'Skip device setup';
const skipHelp = 'You can connect your machine later from the dashboard.';

class _UnsupportedPeripheral implements Device {
  @override
  String get deviceId => 'peripheral-1';

  @override
  String get name => 'Kitchen Lamp';

  @override
  DeviceType get type => DeviceType.sensor;

  @override
  DeviceImplementation get implementation => DeviceImplementation.debugPort;

  @override
  TransportType get transportType => TransportType.ble;

  @override
  Stream<ConnectionState> get connectionState => const Stream.empty();

  @override
  Future<void> onConnect() async {}

  @override
  Future<void> disconnect() async {}
}

Future<void> flushDiscovery(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 5)),
  );
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  late MockConnectionManager mockCm;
  late MockDeviceScanner mockScanner;
  late _TrackingDeviceController deviceController;
  late SettingsController settingsController;
  late ScanStateGuardian scanStateGuardian;
  late MockBleDiscoveryService discovery;

  setUp(() async {
    mockScanner = MockDeviceScanner();
    final de1 = MockDe1Controller(controller: DeviceController([]));
    final scale = MockScaleController();
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();

    mockCm = MockConnectionManager(
      deviceScanner: mockScanner,
      de1Controller: de1,
      scaleController: scale,
      settingsController: settings,
    );

    discovery = MockBleDiscoveryService();
    deviceController = _TrackingDeviceController([discovery]);
    await deviceController.initialize();
    settingsController = settings;
    scanStateGuardian = ScanStateGuardian(bleService: discovery);
  });

  Widget buildView({
    VoidCallback? initialConnectionIntent,
    VoidCallback? onExit,
    VoidCallback? onConnected,
    String exitLabel = 'Continue to Dashboard',
    String? exitHelp,
    bool directConnect = false,
    double textScale = 1.0,
  }) {
    final view = ScanFlowView(
      connectionManager: mockCm,
      deviceController: deviceController,
      settingsController: settingsController,
      scanStateGuardian: scanStateGuardian,
      directConnect: directConnect,
      initialConnectionIntent: initialConnectionIntent,
      onConnected: onConnected ?? () {},
      onExit: onExit ?? () {},
      exitLabel: exitLabel,
      exitHelp: exitHelp,
    );
    if (textScale == 1.0) return ShadApp(home: view);
    return ShadApp(
      home: Builder(
        builder: (context) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(textScaler: TextScaler.linear(textScale)),
            child: view,
          );
        },
      ),
    );
  }

  group('scan exit ownership', () {
    testWidgets(
      'immediate exit cancels before navigation and ignores late work',
      (tester) async {
        var exits = 0;
        var connections = 0;
        await tester.pumpWidget(
          buildView(
            onConnected: () => connections++,
            onExit: () {
              expect(mockCm.cancelActiveScanCallCount, 1);
              expect(deviceController.stopScanCalls, 1);
              exits++;
            },
          ),
        );
        await tester.pump();

        await tester.tap(find.text('Continue to Dashboard'));
        await tester.pump();
        expect(exits, 1);

        mockCm.emitStatus(const ConnectionStatus(phase: ConnectionPhase.ready));
        scanStateGuardian.onAppResumed();
        discovery.addDevice(FakeDe1());
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
        expect(deviceController.devices, hasLength(1));
        expect(find.textContaining('Found 1 device'), findsNothing);
        await tester.pump(ScanFlowView.scanTooLongThreshold);
        await tester.pump(const Duration(milliseconds: 500));

        expect(connections, 0);
        expect(mockCm.scanAndConnectCallCount, 0);
        expect(
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
          0,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Continue to Dashboard'));
        expect(exits, 1);
      },
    );

    testWidgets('picker exit ignores late ready while still mounted', (
      tester,
    ) async {
      var connections = 0;
      mockCm.emitStatus(
        const ConnectionStatus(
          phase: ConnectionPhase.idle,
          pendingAmbiguity: AmbiguityReason.machinePicker,
        ),
      );
      await tester.pumpWidget(buildView(onConnected: () => connections++));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue to Dashboard'));
      mockCm.emitStatus(const ConnectionStatus(phase: ConnectionPhase.ready));
      await tester.pump();
      expect(connections, 0);
      expect(mockCm.cancelActiveScanCallCount, 1);
      expect(deviceController.stopScanCalls, 1);
    });

    testWidgets('disposal cancels unfinished scan and ignores late ready', (
      tester,
    ) async {
      var connections = 0;
      await tester.pumpWidget(buildView(onConnected: () => connections++));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      mockCm.emitStatus(const ConnectionStatus(phase: ConnectionPhase.ready));
      scanStateGuardian.onAppResumed();
      await tester.pump();
      expect(mockCm.cancelActiveScanCallCount, 1);
      expect(deviceController.stopScanCalls, 1);
      expect(connections, 0);
      expect(mockCm.scanAndConnectCallCount, 0);
    });

    testWidgets('successful ready advances once without cancellation', (
      tester,
    ) async {
      var connections = 0;
      await tester.pumpWidget(buildView(onConnected: () => connections++));
      await tester.pump();
      mockCm.emitStatus(const ConnectionStatus(phase: ConnectionPhase.ready));
      await tester.pump();
      mockCm.emitStatus(const ConnectionStatus(phase: ConnectionPhase.ready));
      scanStateGuardian.onAppResumed();
      await tester.pump();
      expect(connections, 1);
      expect(mockCm.scanAndConnectCallCount, 0);
      await tester.pumpWidget(const SizedBox());
      expect(mockCm.cancelActiveScanCallCount, 0);
      expect(deviceController.stopScanCalls, 0);
    });
  });

  group('initial connection intent', () {
    testWidgets('uses scanAndConnect when intent is provided', (tester) async {
      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pump();

      expect(mockCm.scanAndConnectCallCount, 1);
      expect(
        mockCm.connectCallCount - mockCm.scanAndConnectCallCount,
        0,
        reason: 'all connect calls should be scanAndConnect',
      );
    });

    testWidgets('uses connect when no intent is provided', (tester) async {
      await tester.pumpWidget(buildView());
      await tester.pump();

      expect(mockCm.connectCallCount, 1);
      expect(mockCm.scanAndConnectCallCount, 0);
    });
  });

  group('picker selection', () {
    testWidgets('machine picker calls selectMachine', (tester) async {
      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          pendingAmbiguity: AmbiguityReason.machinePicker,
          foundMachines: [FakeDe1(deviceId: 'm1', name: 'DE1 #1')],
        ),
      );

      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pumpAndSettle();

      expect(find.text('DE1 #1'), findsOneWidget);

      await tester.tap(find.text('DE1 #1'));
      await tester.pump();

      await tester.tap(find.text('Connect'));
      await tester.pump();

      expect(mockCm.selectMachineCallCount, 1);
      expect(
        mockCm.scanAndConnectCallCount,
        1,
        reason: 'scan count must not increase for a picker selection',
      );
    });

    testWidgets('scale picker calls selectScale', (tester) async {
      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          pendingAmbiguity: AmbiguityReason.scalePicker,
          foundScales: [TestScale(deviceId: 's1', name: 'Decent Scale')],
        ),
      );

      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Decent Scale'), findsOneWidget);

      await tester.tap(find.text('Decent Scale'));
      await tester.pump();

      await tester.tap(find.text('Connect'));
      await tester.pump();

      expect(mockCm.selectScaleCallCount, 1);
      expect(
        mockCm.scanAndConnectCallCount,
        1,
        reason: 'scan count must not increase for a picker selection',
      );
    });

    testWidgets('USB HDS family ambiguity offers the physical scales', (
      tester,
    ) async {
      await settingsController.setPreferredScaleId('usb-hds:any');
      final first = TestUsbHds(
        deviceId: 'usb-1a86-7522-unknown-1004',
        name: 'USB HDS one',
      );
      final second = TestUsbHds(
        deviceId: 'usb-1a86-7522-unknown-1005',
        name: 'USB HDS two',
      );
      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          pendingAmbiguity: AmbiguityReason.scalePicker,
          foundScales: [first, second],
        ),
      );

      await tester.pumpWidget(buildView());
      await tester.pumpAndSettle();

      expect(find.text('Scales'), findsOneWidget);
      expect(
        find.textContaining("Your preferred scale wasn't found"),
        findsNothing,
      );
      expect(find.text('USB HDS one'), findsOneWidget);
      expect(find.text('USB HDS two'), findsOneWidget);
      await tester.tap(find.text('USB HDS two'));
      await tester.pump();
      await tester.tap(find.text('Connect'));
      await tester.pump();
      expect(mockCm.selectScaleCallCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      first.dispose();
      second.dispose();
    });

    testWidgets('machine picker transitions to scale picker after selection', (
      tester,
    ) async {
      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          pendingAmbiguity: AmbiguityReason.machinePicker,
          foundMachines: [FakeDe1(deviceId: 'm1', name: 'DE1 #1')],
        ),
      );

      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('DE1 #1'));
      await tester.pump();
      await tester.tap(find.text('Connect'));
      await tester.pump();

      expect(mockCm.selectMachineCallCount, 1);

      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          pendingAmbiguity: AmbiguityReason.scalePicker,
          foundScales: [TestScale(deviceId: 's1', name: 'Decent Scale')],
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Decent Scale'), findsOneWidget);
      expect(find.text('Scales'), findsOneWidget);

      await tester.tap(find.text('Decent Scale'));
      await tester.pump();
      await tester.tap(find.text('Connect'));
      await tester.pump();

      expect(mockCm.selectScaleCallCount, 1);
      expect(mockCm.scanAndConnectCallCount, 1);
    });
  });

  group('error plus picker coexistence', () {
    testWidgets(
      'machine connect failure with another candidate shows picker and error',
      (tester) async {
        final candidate1 = FakeDe1(deviceId: 'm1', name: 'DE1 #1');
        final candidate2 = FakeDe1(deviceId: 'm2', name: 'DE1 #2');

        mockCm.emitStatus(
          ConnectionStatus(
            phase: ConnectionPhase.idle,
            pendingAmbiguity: AmbiguityReason.machinePicker,
            foundMachines: [candidate1, candidate2],
          ),
        );

        await tester.pumpWidget(
          buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('DE1 #1'));
        await tester.pump();

        mockCm.shouldFailMachineConnect = true;
        await tester.tap(find.text('Connect'));
        await tester.pumpAndSettle();

        expect(find.text('DE1 #1'), findsOneWidget);
        expect(find.text('DE1 #2'), findsOneWidget);
        expect(find.text('Connect'), findsOneWidget);

        expect(find.text('Machine DE1 #1 failed to connect.'), findsOneWidget);

        await tester.tap(find.text('DE1 #2'));
        await tester.pump();

        mockCm.shouldFailMachineConnect = false;
        await tester.tap(find.text('Connect'));
        await tester.pump();

        expect(mockCm.selectMachineCallCount, 2);
        expect(mockCm.scanAndConnectCallCount, 1);
      },
    );

    testWidgets(
      'selected machine fails with another candidate — picker remains visible',
      (tester) async {
        final candidate1 = FakeDe1(deviceId: 'm1', name: 'DE1 #1');
        final candidate2 = FakeDe1(deviceId: 'm2', name: 'Alt Machine');

        mockCm.emitStatus(
          ConnectionStatus(
            phase: ConnectionPhase.idle,
            pendingAmbiguity: AmbiguityReason.machinePicker,
            foundMachines: [candidate1, candidate2],
          ),
        );

        await tester.pumpWidget(
          buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('DE1 #1'));
        await tester.pump();

        mockCm.shouldFailMachineConnect = true;
        await tester.tap(find.text('Connect'));
        await tester.pumpAndSettle();

        expect(find.text('DE1 #1'), findsOneWidget);
        expect(find.text('Alt Machine'), findsOneWidget);

        expect(find.text('Machine DE1 #1 failed to connect.'), findsOneWidget);

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'machine fails with no alternatives — scalePicker shows with error',
      (tester) async {
        final machine = FakeDe1(deviceId: 'm1', name: 'My DE1');

        mockCm.emitStatus(
          ConnectionStatus(
            phase: ConnectionPhase.idle,
            pendingAmbiguity: AmbiguityReason.machinePicker,
            foundMachines: [machine],
          ),
        );

        await tester.pumpWidget(
          buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
        );
        await tester.pumpAndSettle();

        mockCm.shouldFailMachineConnect = true;
        await tester.tap(find.text('My DE1'));
        await tester.pump();
        await tester.tap(find.text('Connect'));
        await tester.pump();

        mockCm.emitStatus(
          ConnectionStatus(
            phase: ConnectionPhase.idle,
            pendingAmbiguity: AmbiguityReason.scalePicker,
            foundScales: [TestScale(deviceId: 's1', name: 'My Scale')],
            error: ConnectionError(
              kind: ConnectionErrorKind.machineConnectFailed,
              severity: ConnectionErrorSeverity.error,
              timestamp: DateTime.now().toUtc(),
              message: 'Machine My DE1 failed to connect.',
              suggestion: 'Try another machine.',
            ),
          ),
        );

        await tester.pumpAndSettle();

        expect(find.text('My Scale'), findsOneWidget);
        expect(find.text('Scales'), findsOneWidget);

        expect(find.text('Machine My DE1 failed to connect.'), findsOneWidget);

        await tester.tap(find.text('My Scale'));
        await tester.pump();
        await tester.tap(find.text('Connect'));
        await tester.pump();

        expect(mockCm.selectScaleCallCount, 1);
        expect(mockCm.scanAndConnectCallCount, 1);
      },
    );
  });

  group('wired discovery without Bluetooth', () {
    TransportCondition bluetoothOffCondition() {
      return TransportCondition(
        transportType: TransportType.ble,
        affectedDeviceTypes: const {DeviceType.machine, DeviceType.scale},
        connectionError: ConnectionError(
          kind: ConnectionErrorKind.adapterOff,
          severity: ConnectionErrorSeverity.error,
          timestamp: DateTime.utc(2025),
          message: 'Bluetooth is turned off.',
        ),
      );
    }

    testWidgets('serial picker remains interactive with a Bluetooth notice', (
      tester,
    ) async {
      final serialMachine = FakeDe1(
        deviceId: 'usb-machine',
        name: 'USB Machine',
        transportType: TransportType.serial,
      );
      final condition = bluetoothOffCondition();
      mockCm.emitStatus(
        ConnectionStatus(
          pendingAmbiguity: AmbiguityReason.machinePicker,
          foundMachines: [serialMachine],
          error: condition.connectionError,
          conditions: [condition],
        ),
      );

      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pumpAndSettle();

      expect(find.text('USB Machine'), findsOneWidget);
      expect(
        find.text('Bluetooth is unavailable. USB devices remain available.'),
        findsOneWidget,
      );
      await tester.tap(find.text('USB Machine'));
      await tester.pump();
      await tester.tap(find.text('Connect'));
      await tester.pump();
      expect(mockCm.selectMachineCallCount, 1);
    });

    testWidgets('serial connection failure stays visible above the notice', (
      tester,
    ) async {
      final condition = bluetoothOffCondition();
      mockCm.emitStatus(
        ConnectionStatus(
          activeTargetTransport: TransportType.serial,
          error: ConnectionError(
            kind: ConnectionErrorKind.machineConnectFailed,
            severity: ConnectionErrorSeverity.error,
            timestamp: DateTime.utc(2025),
            message: 'USB machine failed to connect.',
          ),
          conditions: [condition],
        ),
      );

      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Connection Error'), findsOneWidget);
      expect(find.text('USB machine failed to connect.'), findsOneWidget);
      expect(
        find.text('Bluetooth is unavailable. USB devices remain available.'),
        findsOneWidget,
      );
    });

    testWidgets('BLE-only picker shows the blocking Bluetooth error', (
      tester,
    ) async {
      final condition = bluetoothOffCondition();
      mockCm.emitStatus(
        ConnectionStatus(
          pendingAmbiguity: AmbiguityReason.machinePicker,
          foundMachines: [
            FakeDe1(
              deviceId: 'ble-machine',
              name: 'BLE Machine',
              transportType: TransportType.ble,
            ),
          ],
          error: condition.connectionError,
          conditions: [condition],
        ),
      );

      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Bluetooth Unavailable'), findsOneWidget);
      expect(find.text('BLE Machine'), findsNothing);
    });
  });

  group('connect-failure error view', () {
    ConnectionError connectError() => ConnectionError(
      kind: ConnectionErrorKind.machineConnectFailed,
      severity: ConnectionErrorSeverity.error,
      timestamp: DateTime.now().toUtc(),
      message: 'Machine My DE1 failed to connect.',
      suggestion: 'Make sure the DE1 is powered on and in range, then retry.',
    );

    testWidgets('offers exit label action when nothing was found', (
      tester,
    ) async {
      var exited = false;
      mockCm.emitStatus(
        ConnectionStatus(phase: ConnectionPhase.idle, error: connectError()),
      );

      await tester.pumpWidget(
        buildView(
          initialConnectionIntent: () => mockCm.scanAndConnect(),
          onExit: () => exited = true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Continue to Dashboard'), findsOneWidget);
      expect(find.text('View found devices'), findsNothing);

      await tester.tap(find.text('Continue to Dashboard'));
      await tester.pump();
      expect(exited, isTrue);
    });

    testWidgets('machine list is reachable after a connect failure', (
      tester,
    ) async {
      final machine = FakeDe1(deviceId: 'm1', name: 'DE1 #1');
      discovery.addDevice(machine);
      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          foundMachines: [machine],
          error: connectError(),
        ),
      );

      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Connection Error'), findsOneWidget);

      await tester.tap(find.text('View found devices'));
      await tester.pumpAndSettle();

      expect(find.text('Connection Error'), findsNothing);
      expect(find.text('DE1 #1'), findsOneWidget);
      expect(find.text('ReScan'), findsOneWidget);
    });

    testWidgets('uses the caller-provided exit label', (tester) async {
      var exited = false;
      mockCm.emitStatus(
        ConnectionStatus(phase: ConnectionPhase.idle, error: connectError()),
      );

      await tester.pumpWidget(
        buildView(
          initialConnectionIntent: () => mockCm.scanAndConnect(),
          onExit: () => exited = true,
          exitLabel: 'Cancel',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(exited, isTrue);
    });

    testWidgets(
      'session-only selection remains connectable without changing preference',
      (tester) async {
        final machine = FakeDe1(
          deviceId: 'usb-2e8a-a-unknown-7',
          name: 'Session DE1',
        );
        final other = FakeDe1(deviceId: 'usb-2e8a-a-OTHER', name: 'Other DE1');
        discovery.addDevice(machine);
        discovery.addDevice(other);
        await settingsController.setPreferredMachineId('usb-2e8a-a-KNOWN');
        mockCm.emitStatus(
          ConnectionStatus(
            phase: ConnectionPhase.idle,
            foundMachines: [machine, other],
            error: connectError(),
          ),
        );
        await tester.pumpWidget(
          buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('View found devices'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Session DE1'));
        await tester.pumpAndSettle();
        expect(settingsController.preferredMachineId, 'usb-2e8a-a-KNOWN');
        final button = tester.widget<ShadButton>(
          find.widgetWithText(ShadButton, 'Connect'),
        );
        expect(button.onPressed, isNotNull);
        await tester.tap(find.text('Connect'));
        await tester.pump();
        expect(mockCm.connectMachineCallCount, 1);
      },
    );

    testWidgets('escaped picker can connect the listed machine', (
      tester,
    ) async {
      final machine = FakeDe1(deviceId: 'm1', name: 'DE1 #1');
      discovery.addDevice(machine);
      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          foundMachines: [machine],
          error: connectError(),
        ),
      );

      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('View found devices'));
      await tester.pumpAndSettle();

      expect(find.text('DE1 #1'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);

      await tester.tap(find.text('Connect'));
      await tester.pump();
      expect(mockCm.connectMachineCallCount, 1);
    });

    testWidgets('device-list override resets when a new scan starts', (
      tester,
    ) async {
      final machine = FakeDe1(deviceId: 'm1', name: 'DE1 #1');
      discovery.addDevice(machine);
      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          foundMachines: [machine],
          error: connectError(),
        ),
      );

      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('View found devices'));
      await tester.pumpAndSettle();
      expect(find.text('Connection Error'), findsNothing);

      mockCm.emitStatus(
        const ConnectionStatus(phase: ConnectionPhase.scanning),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.textContaining('Scanning for your Decent machine'),
        findsOneWidget,
      );

      mockCm.emitStatus(
        ConnectionStatus(phase: ConnectionPhase.idle, error: connectError()),
      );
      await tester.pumpAndSettle();
      expect(find.text('Connection Error'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(mockCm.scanAndConnectCallCount, 2);
    });

    testWidgets('scanning view reports real progress copy', (tester) async {
      mockCm.emitStatus(
        const ConnectionStatus(phase: ConnectionPhase.scanning),
      );

      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.textContaining('Scanning for your Decent machine'),
        findsOneWidget,
      );

      discovery.addDevice(FakeDe1(deviceId: 'm1', name: 'DE1 #1'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.textContaining('Found 1 device. Still scanning'),
        findsOneWidget,
      );

      await tester.pump(
        ScanFlowView.scanTooLongThreshold + const Duration(seconds: 1),
      );
      expect(
        find.textContaining('Scanning is taking longer than usual'),
        findsOneWidget,
      );
      expect(
        find.textContaining('devices are powered on and in range'),
        findsOneWidget,
      );
    });
  });

  group('stale-scan recovery', () {
    testWidgets('triggers scanAndConnect on stale event', (tester) async {
      mockCm.emitStatus(
        const ConnectionStatus(phase: ConnectionPhase.scanning),
      );

      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pump();

      final callsBefore = mockCm.scanAndConnectCallCount;

      scanStateGuardian.onAppResumed();
      await tester.pump();

      expect(mockCm.scanAndConnectCallCount, greaterThan(callsBefore));
    });
  });

  group('live discovery during scanning', () {
    testWidgets('shows the role and name of a recognized machine', (
      tester,
    ) async {
      discovery.addDevice(FakeDe1(deviceId: 'm1', name: 'DE1-Cafe'));
      await tester.pumpWidget(buildView());
      await tester.pump();
      await flushDiscovery(tester);

      expect(find.text('Machine'), findsOneWidget);
      expect(find.text('DE1-Cafe'), findsOneWidget);
      expect(find.text('Found 1 device. Still scanning...'), findsOneWidget);
      expect(find.byType(ShadProgress), findsOneWidget);
    });

    testWidgets('shows machine and scale roles when both are found', (
      tester,
    ) async {
      discovery.addDevice(FakeDe1(deviceId: 'm1', name: 'DE1-Cafe'));
      discovery.addDevice(TestScale(deviceId: 's1', name: 'Decent Scale Cafe'));
      await tester.pumpWidget(buildView());
      await tester.pump();
      await flushDiscovery(tester);

      expect(find.text('Machine'), findsOneWidget);
      expect(find.text('Scale'), findsOneWidget);
      expect(find.text('DE1-Cafe'), findsOneWidget);
      expect(find.text('Decent Scale Cafe'), findsOneWidget);
    });

    testWidgets('keeps searching copy when nothing is recognized', (
      tester,
    ) async {
      await tester.pumpWidget(buildView());
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.text('Scanning for your Decent machine and scale...'),
        findsOneWidget,
      );
      expect(find.text('Machine'), findsNothing);
      expect(find.text('Scale'), findsNothing);
    });

    testWidgets('deduplicates repeats of the same device id', (tester) async {
      final machine = FakeDe1(deviceId: 'm1', name: 'DE1-Cafe');
      discovery.addDevice(machine);
      discovery.addDevice(machine);
      await tester.pumpWidget(buildView());
      await tester.pump();
      await flushDiscovery(tester);

      expect(find.text('DE1-Cafe'), findsOneWidget);
    });

    testWidgets('counts each unique recognized device once in the copy', (
      tester,
    ) async {
      final machine = FakeDe1(deviceId: 'm1', name: 'DE1-Cafe');
      discovery.addDevice(machine);
      discovery.addDevice(machine);
      discovery.addDevice(TestScale(deviceId: 's1', name: 'Decent Scale'));
      await tester.pumpWidget(buildView());
      await tester.pump();
      await flushDiscovery(tester);

      expect(find.text('Found 2 devices. Still scanning...'), findsOneWidget);
      expect(find.text('DE1-Cafe'), findsOneWidget);
      expect(find.text('Decent Scale'), findsOneWidget);
    });

    testWidgets('keeps searching when only unsupported peripherals appear', (
      tester,
    ) async {
      discovery.addDevice(_UnsupportedPeripheral());
      await tester.pumpWidget(buildView());
      await tester.pump();
      await flushDiscovery(tester);

      expect(find.text('Kitchen Lamp'), findsNothing);
      expect(find.text('Machine'), findsNothing);
      expect(find.text('Scale'), findsNothing);
      expect(
        find.text('Scanning for your Decent machine and scale...'),
        findsOneWidget,
      );
    });

    testWidgets('keeps distinct devices that share a display name', (
      tester,
    ) async {
      discovery.addDevice(FakeDe1(deviceId: 'm1', name: 'DE1'));
      discovery.addDevice(FakeDe1(deviceId: 'm2', name: 'DE1'));
      await tester.pumpWidget(buildView());
      await tester.pump();
      await flushDiscovery(tester);

      expect(find.text('DE1'), findsNWidgets(2));
    });

    testWidgets('reflects a renamed device that keeps its id', (tester) async {
      discovery.addDevice(FakeDe1(deviceId: 'm1', name: 'DE1-Old'));
      await tester.pumpWidget(buildView());
      await tester.pump();
      await flushDiscovery(tester);
      expect(find.text('DE1-Old'), findsOneWidget);

      discovery.removeDevice('m1');
      discovery.addDevice(FakeDe1(deviceId: 'm1', name: 'DE1-New'));
      await flushDiscovery(tester);

      expect(find.text('DE1-Old'), findsNothing);
      expect(find.text('DE1-New'), findsOneWidget);
    });

    testWidgets('keeps devices with empty ids distinct', (tester) async {
      discovery.addDevice(FakeDe1(deviceId: '', name: 'DE1-Alpha'));
      discovery.addDevice(FakeDe1(deviceId: '', name: 'DE1-Beta'));
      await tester.pumpWidget(buildView());
      await tester.pump();
      await flushDiscovery(tester);

      expect(find.text('DE1-Alpha'), findsOneWidget);
      expect(find.text('DE1-Beta'), findsOneWidget);
    });

    testWidgets('falls back to role names for missing display names', (
      tester,
    ) async {
      discovery.addDevice(FakeDe1(deviceId: 'm1', name: ''));
      discovery.addDevice(TestScale(deviceId: 's1', name: '   '));
      await tester.pumpWidget(buildView());
      await tester.pump();
      await flushDiscovery(tester);

      expect(find.text('Decent machine'), findsOneWidget);
      expect(find.text('Decent scale'), findsOneWidget);
    });

    testWidgets('trims padded display names', (tester) async {
      discovery.addDevice(FakeDe1(deviceId: 'm1', name: '  DE1-Cafe  '));
      await tester.pumpWidget(buildView());
      await tester.pump();
      await flushDiscovery(tester);

      expect(find.text('DE1-Cafe'), findsOneWidget);
    });

    testWidgets('renders long display names without failing', (tester) async {
      final longName = 'DE1 ${'X' * 120}';
      discovery.addDevice(FakeDe1(deviceId: 'm1', name: longName));
      await tester.pumpWidget(buildView());
      await tester.pump();
      await flushDiscovery(tester);

      expect(find.text(longName), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tracks additions and removals from the device stream', (
      tester,
    ) async {
      discovery.addDevice(FakeDe1(deviceId: 'm1', name: 'DE1-Cafe'));
      await tester.pumpWidget(buildView());
      await tester.pump();
      await flushDiscovery(tester);
      expect(find.text('DE1-Cafe'), findsOneWidget);

      discovery.removeDevice('m1');
      await flushDiscovery(tester);
      expect(find.text('DE1-Cafe'), findsNothing);
      expect(find.text('Machine'), findsNothing);

      discovery.addDevice(TestScale(deviceId: 's1', name: 'Decent Scale'));
      await flushDiscovery(tester);
      expect(find.text('Decent Scale'), findsOneWidget);
      expect(find.text('Scale'), findsOneWidget);
    });

    testWidgets('hides the live list outside the scanning phase', (
      tester,
    ) async {
      final machine = FakeDe1(deviceId: 'm1', name: 'DE1-Cafe');
      discovery.addDevice(machine);
      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pump();
      await flushDiscovery(tester);
      expect(find.text('DE1-Cafe'), findsOneWidget);

      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          pendingAmbiguity: AmbiguityReason.machinePicker,
          foundMachines: [machine],
        ),
      );
      await tester.pump();

      expect(find.text('Machine'), findsNothing);
      expect(find.text('Machines'), findsOneWidget);
      expect(find.text('DE1-Cafe'), findsOneWidget);
    });

    testWidgets('makes no connection calls while scanning', (tester) async {
      final first = FakeDe1(deviceId: 'm1', name: 'DE1-One');
      final second = FakeDe1(deviceId: 'm2', name: 'DE1-Two');
      discovery.addDevice(first);
      discovery.addDevice(second);
      discovery.addDevice(TestScale(deviceId: 's1', name: 'Decent Scale'));
      await settingsController.setPreferredMachineId('m1');
      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pump();
      await flushDiscovery(tester);
      final scansBefore = mockCm.scanAndConnectCallCount;

      await tester.tap(find.text('DE1-One'));
      await tester.pump();
      await tester.tap(find.text('Machine'));
      await tester.pump();
      await tester.tap(find.text('Decent Scale'));
      await tester.pump();

      expect(mockCm.selectMachineCallCount, 0);
      expect(mockCm.selectScaleCallCount, 0);
      expect(mockCm.connectMachineCallCount, 0);
      expect(mockCm.scanAndConnectCallCount, scansBefore);
    });

    testWidgets('announces discovery rows by role and name', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        discovery.addDevice(FakeDe1(deviceId: 'm1', name: 'DE1-Cafe'));
        discovery.addDevice(TestScale(deviceId: 's1', name: 'Decent Scale'));
        await tester.pumpWidget(buildView());
        await tester.pump();
        await flushDiscovery(tester);

        expect(find.bySemanticsLabel('Machine DE1-Cafe'), findsOneWidget);
        expect(find.bySemanticsLabel('Scale Decent Scale'), findsOneWidget);
        expect(find.bySemanticsLabel('Scanning for devices'), findsOneWidget);
      } finally {
        handle.dispose();
      }
    });

    testWidgets('keeps a single live-region announcement while scanning', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        discovery.addDevice(FakeDe1(deviceId: 'm1', name: 'DE1-One'));
        discovery.addDevice(FakeDe1(deviceId: 'm2', name: 'DE1-Two'));
        discovery.addDevice(TestScale(deviceId: 's1', name: 'Decent Scale'));
        await tester.pumpWidget(buildView());
        await tester.pump();
        await flushDiscovery(tester);

        final liveRegions = find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.liveRegion == true,
        );
        expect(liveRegions, findsOneWidget);
      } finally {
        handle.dispose();
      }
    });
  });

  group('live discovery layout', () {
    testWidgets('does not overflow a small tablet viewport', (tester) async {
      tester.view.physicalSize = const Size(1024, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (var i = 0; i < 6; i++) {
        discovery.addDevice(
          FakeDe1(deviceId: 'm$i', name: 'DE1 machine number $i'),
        );
      }
      for (var i = 0; i < 3; i++) {
        discovery.addDevice(
          TestScale(deviceId: 's$i', name: 'Decent scale number $i'),
        );
      }
      await tester.pumpWidget(
        buildView(exitLabel: skipLabel, exitHelp: skipHelp, textScale: 1.5),
      );
      await tester.pump();
      await flushDiscovery(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Machine'), findsOneWidget);
      expect(find.text(skipLabel), findsOneWidget);
      expect(find.text(skipHelp), findsOneWidget);
    });

    testWidgets('does not overflow a small phone viewport at large text', (
      tester,
    ) async {
      var exits = 0;
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (var i = 0; i < 6; i++) {
        discovery.addDevice(
          FakeDe1(deviceId: 'm$i', name: 'DE1 machine number $i'),
        );
      }
      for (var i = 0; i < 3; i++) {
        discovery.addDevice(
          TestScale(deviceId: 's$i', name: 'Decent scale number $i'),
        );
      }
      await tester.pumpWidget(
        buildView(
          exitLabel: skipLabel,
          exitHelp: skipHelp,
          textScale: 2.0,
          onExit: () => exits++,
        ),
      );
      await tester.pump();
      await flushDiscovery(tester);

      expect(tester.takeException(), isNull);
      expect(find.text(skipLabel), findsOneWidget);
      expect(find.text(skipHelp), findsOneWidget);

      await tester.tap(find.text(skipLabel));
      await tester.pump();

      expect(exits, 1);
      expect(mockCm.cancelActiveScanCallCount, 1);
    });
  });

  group('exit label and help seam', () {
    testWidgets('launcher configuration keeps Cancel without onboarding help', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildView(
          exitLabel: 'Cancel',
          initialConnectionIntent: () => mockCm.scanAndConnect(),
        ),
      );
      await tester.pump();

      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text(skipLabel), findsNothing);
      expect(find.textContaining('connect your machine later'), findsNothing);
    });

    testWidgets('onboarding configuration shows skip label and help copy', (
      tester,
    ) async {
      var exits = 0;
      await tester.pumpWidget(
        buildView(
          exitLabel: skipLabel,
          exitHelp: skipHelp,
          onExit: () => exits++,
          initialConnectionIntent: () => mockCm.scanAndConnect(),
        ),
      );
      await tester.pump();

      expect(find.text(skipLabel), findsOneWidget);
      expect(find.text(skipHelp), findsOneWidget);

      await tester.tap(find.text(skipLabel));
      await tester.pump();

      expect(exits, 1);
      expect(mockCm.cancelActiveScanCallCount, 1);
      expect(deviceController.stopScanCalls, 1);
    });

    testWidgets('connecting view keeps the skip label and help copy', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildView(
          exitLabel: skipLabel,
          exitHelp: skipHelp,
          initialConnectionIntent: () => mockCm.scanAndConnect(),
        ),
      );
      await tester.pump();
      mockCm.emitStatus(
        const ConnectionStatus(phase: ConnectionPhase.connectingMachine),
      );
      await tester.pump();

      expect(find.text('Connecting to your machine...'), findsOneWidget);
      expect(find.text(skipLabel), findsOneWidget);
      expect(find.text(skipHelp), findsOneWidget);
    });

    testWidgets('default label remains a dashboard continue action', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildView(initialConnectionIntent: () => mockCm.scanAndConnect()),
      );
      await tester.pump();

      expect(find.text('Continue to Dashboard'), findsOneWidget);
      expect(find.textContaining('connect your machine later'), findsNothing);
    });

    testWidgets('progress uses the theme primary treatment', (tester) async {
      await tester.pumpWidget(
        buildView(
          exitLabel: skipLabel,
          exitHelp: skipHelp,
          initialConnectionIntent: () => mockCm.scanAndConnect(),
        ),
      );
      await tester.pump();

      final progress = tester.widget<ShadProgress>(find.byType(ShadProgress));
      expect(progress.color, isNull);
      final exitButton = tester.widget<ShadButton>(
        find.widgetWithText(ShadButton, skipLabel),
      );
      expect(
        exitButton.variant,
        anyOf(ShadButtonVariant.secondary, ShadButtonVariant.outline),
      );
    });

    testWidgets('picker connection action stays visually primary', (
      tester,
    ) async {
      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          pendingAmbiguity: AmbiguityReason.machinePicker,
          foundMachines: [FakeDe1(deviceId: 'm1', name: 'DE1 #1')],
        ),
      );
      await tester.pumpWidget(
        buildView(
          exitLabel: skipLabel,
          exitHelp: skipHelp,
          initialConnectionIntent: () => mockCm.scanAndConnect(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('DE1 #1'));
      await tester.pump();

      final connectButton = tester.widget<ShadButton>(
        find.widgetWithText(ShadButton, 'Connect'),
      );
      expect(connectButton.variant, ShadButtonVariant.primary);
      expect(find.text(skipLabel), findsOneWidget);
      expect(find.text(skipHelp), findsNothing);
    });
  });

  group('skip availability in every state', () {
    ConnectionError connectError() => ConnectionError(
      kind: ConnectionErrorKind.machineConnectFailed,
      severity: ConnectionErrorSeverity.error,
      timestamp: DateTime.utc(2026),
      message: 'Machine My DE1 failed to connect.',
    );

    testWidgets('picker keeps skip available while connecting', (tester) async {
      var exits = 0;
      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.connectingMachine,
          pendingAmbiguity: AmbiguityReason.machinePicker,
          foundMachines: [FakeDe1(deviceId: 'm1', name: 'DE1 #1')],
        ),
      );
      await tester.pumpWidget(
        buildView(
          exitLabel: skipLabel,
          exitHelp: skipHelp,
          onExit: () => exits++,
          initialConnectionIntent: () => mockCm.scanAndConnect(),
        ),
      );
      await tester.pump();

      expect(find.text(skipLabel), findsOneWidget);
      await tester.tap(find.text(skipLabel));
      await tester.pump();

      expect(exits, 1);
      expect(mockCm.cancelActiveScanCallCount, 1);
      expect(deviceController.stopScanCalls, 1);
    });

    testWidgets('error view keeps skip available', (tester) async {
      var exits = 0;
      mockCm.emitStatus(
        ConnectionStatus(phase: ConnectionPhase.idle, error: connectError()),
      );
      await tester.pumpWidget(
        buildView(
          exitLabel: skipLabel,
          exitHelp: skipHelp,
          onExit: () => exits++,
          initialConnectionIntent: () => mockCm.scanAndConnect(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Connection Error'), findsOneWidget);
      await tester.tap(find.text(skipLabel));
      await tester.pump();

      expect(exits, 1);
      expect(mockCm.cancelActiveScanCallCount, 1);
    });

    testWidgets('bluetooth unavailable view offers a usable skip', (
      tester,
    ) async {
      var exits = 0;
      final condition = TransportCondition(
        transportType: TransportType.ble,
        affectedDeviceTypes: const {DeviceType.machine, DeviceType.scale},
        connectionError: ConnectionError(
          kind: ConnectionErrorKind.adapterOff,
          severity: ConnectionErrorSeverity.error,
          timestamp: DateTime.utc(2026),
          message: 'Bluetooth is turned off.',
        ),
      );
      mockCm.emitStatus(
        ConnectionStatus(
          pendingAmbiguity: AmbiguityReason.machinePicker,
          foundMachines: [
            FakeDe1(
              deviceId: 'ble-machine',
              name: 'BLE Machine',
              transportType: TransportType.ble,
            ),
          ],
          error: condition.connectionError,
          conditions: [condition],
        ),
      );
      await tester.pumpWidget(
        buildView(
          exitLabel: skipLabel,
          exitHelp: skipHelp,
          onExit: () => exits++,
          initialConnectionIntent: () => mockCm.scanAndConnect(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Bluetooth Unavailable'), findsOneWidget);
      await tester.tap(find.text(skipLabel));
      await tester.pump();

      expect(exits, 1);
      expect(mockCm.cancelActiveScanCallCount, 1);
    });

    testWidgets('serial picker with a Bluetooth notice keeps skip available', (
      tester,
    ) async {
      var exits = 0;
      final serialMachine = FakeDe1(
        deviceId: 'usb-machine',
        name: 'USB Machine',
        transportType: TransportType.serial,
      );
      final condition = TransportCondition(
        transportType: TransportType.ble,
        affectedDeviceTypes: const {DeviceType.machine, DeviceType.scale},
        connectionError: ConnectionError(
          kind: ConnectionErrorKind.adapterOff,
          severity: ConnectionErrorSeverity.error,
          timestamp: DateTime.utc(2026),
          message: 'Bluetooth is turned off.',
        ),
      );
      mockCm.emitStatus(
        ConnectionStatus(
          pendingAmbiguity: AmbiguityReason.machinePicker,
          foundMachines: [serialMachine],
          error: condition.connectionError,
          conditions: [condition],
        ),
      );
      await tester.pumpWidget(
        buildView(
          exitLabel: skipLabel,
          exitHelp: skipHelp,
          onExit: () => exits++,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('USB Machine'), findsOneWidget);
      expect(
        find.text('Bluetooth is unavailable. USB devices remain available.'),
        findsOneWidget,
      );
      await tester.tap(find.text(skipLabel));
      await tester.pump();

      expect(exits, 1);
      expect(mockCm.cancelActiveScanCallCount, 1);
    });

    testWidgets('preferred machine not found keeps skip available', (
      tester,
    ) async {
      await settingsController.setPreferredMachineId('missing-machine');
      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          pendingAmbiguity: AmbiguityReason.machinePicker,
          foundMachines: [FakeDe1(deviceId: 'other', name: 'DE1 Other')],
        ),
      );
      await tester.pumpWidget(
        buildView(exitLabel: skipLabel, exitHelp: skipHelp),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          "Your preferred machine wasn't found, but we discovered these:",
        ),
        findsOneWidget,
      );
      expect(find.text(skipLabel), findsOneWidget);
    });

    testWidgets('no-devices view without a report offers a usable skip', (
      tester,
    ) async {
      var exits = 0;
      mockCm.emitStatus(const ConnectionStatus(phase: ConnectionPhase.idle));
      await tester.pumpWidget(
        buildView(
          exitLabel: skipLabel,
          exitHelp: skipHelp,
          onExit: () => exits++,
          initialConnectionIntent: () => mockCm.scanAndConnect(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Scan Again'), findsOneWidget);
      await tester.tap(find.text(skipLabel));
      await tester.pump();

      expect(exits, 1);
      expect(mockCm.cancelActiveScanCallCount, 1);
    });

    testWidgets('scan summary uses the supplied skip label', (tester) async {
      var exits = 0;
      mockCm.setLastScanReport(
        const ScanReport(
          totalBleDevicesSeen: 0,
          matchedDevices: [],
          scanDuration: Duration(seconds: 5),
          adapterStateAtStart: AdapterState.poweredOn,
          adapterStateAtEnd: AdapterState.poweredOn,
          scanTerminationReason: ScanTerminationReason.completed,
        ),
      );
      mockCm.emitStatus(const ConnectionStatus(phase: ConnectionPhase.idle));
      await tester.pumpWidget(
        buildView(
          exitLabel: skipLabel,
          exitHelp: skipHelp,
          onExit: () => exits++,
          initialConnectionIntent: () => mockCm.scanAndConnect(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No Bluetooth Devices Found'), findsOneWidget);
      expect(find.text(skipLabel), findsOneWidget);
      expect(find.text('Continue to Dashboard'), findsNothing);
      await tester.tap(find.text(skipLabel));
      await tester.pump();

      expect(exits, 1);
      expect(mockCm.cancelActiveScanCallCount, 1);
    });

    testWidgets('taking-too-long sheet uses the supplied skip label', (
      tester,
    ) async {
      var exits = 0;
      await tester.pumpWidget(
        buildView(
          exitLabel: skipLabel,
          exitHelp: skipHelp,
          onExit: () => exits++,
          initialConnectionIntent: () => mockCm.scanAndConnect(),
        ),
      );
      await tester.pump();
      await tester.pump(ScanFlowView.scanTooLongThreshold);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('This is taking a while...'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.widgetWithText(ListTile, skipLabel), findsOneWidget);
      expect(
        find.widgetWithText(ListTile, 'Continue to Dashboard'),
        findsNothing,
      );
      await tester.tap(find.widgetWithText(ListTile, skipLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(exits, 1);
      expect(mockCm.cancelActiveScanCallCount, 1);
    });
  });

  group('skip cancellation guards', () {
    testWidgets(
      'skip while connecting ignores late ready and guardian events',
      (tester) async {
        var connections = 0;
        var exits = 0;
        await tester.pumpWidget(
          buildView(
            exitLabel: skipLabel,
            exitHelp: skipHelp,
            onConnected: () => connections++,
            onExit: () => exits++,
          ),
        );
        await tester.pump();
        mockCm.emitStatus(
          const ConnectionStatus(phase: ConnectionPhase.connectingMachine),
        );
        await tester.pump();

        await tester.tap(find.text(skipLabel));
        await tester.pump();
        expect(exits, 1);
        expect(mockCm.cancelActiveScanCallCount, 1);

        await tester.tap(find.text(skipLabel));
        await tester.pump();
        expect(exits, 1);

        mockCm.emitStatus(const ConnectionStatus(phase: ConnectionPhase.ready));
        scanStateGuardian.onAppResumed();
        await tester.pump(
          ScanFlowView.scanTooLongThreshold + const Duration(seconds: 1),
        );

        expect(connections, 0);
        expect(mockCm.scanAndConnectCallCount, 0);
        expect(mockCm.cancelActiveScanCallCount, 1);
        expect(deviceController.stopScanCalls, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('skip from the picker ignores late ready', (tester) async {
      var connections = 0;
      var exits = 0;
      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          pendingAmbiguity: AmbiguityReason.machinePicker,
          foundMachines: [FakeDe1(deviceId: 'm1', name: 'DE1 #1')],
        ),
      );
      await tester.pumpWidget(
        buildView(
          exitLabel: skipLabel,
          exitHelp: skipHelp,
          onConnected: () => connections++,
          onExit: () => exits++,
          initialConnectionIntent: () => mockCm.scanAndConnect(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(skipLabel));
      await tester.pump();
      expect(exits, 1);

      mockCm.emitStatus(const ConnectionStatus(phase: ConnectionPhase.ready));
      await tester.pump();

      expect(connections, 0);
      expect(mockCm.cancelActiveScanCallCount, 1);
      expect(mockCm.selectMachineCallCount, 0);
    });
  });

  group('successful connection', () {
    testWidgets('advances once after a picker selection without another scan', (
      tester,
    ) async {
      var connections = 0;
      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          pendingAmbiguity: AmbiguityReason.machinePicker,
          foundMachines: [FakeDe1(deviceId: 'm1', name: 'DE1 #1')],
        ),
      );
      await tester.pumpWidget(
        buildView(
          onConnected: () => connections++,
          initialConnectionIntent: () => mockCm.scanAndConnect(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('DE1 #1'));
      await tester.pump();
      await tester.tap(find.text('Connect'));
      await tester.pump();
      expect(mockCm.selectMachineCallCount, 1);
      final scans = mockCm.scanAndConnectCallCount;

      mockCm.emitStatus(const ConnectionStatus(phase: ConnectionPhase.ready));
      await tester.pump();
      mockCm.emitStatus(const ConnectionStatus(phase: ConnectionPhase.ready));
      await tester.pump();

      expect(connections, 1);
      expect(mockCm.scanAndConnectCallCount, scans);
      expect(mockCm.cancelActiveScanCallCount, 0);
      expect(deviceController.stopScanCalls, 0);
    });
  });

  group('direct connect policy', () {
    testWidgets('auto-selects the discovered machine through the manager', (
      tester,
    ) async {
      final machine = FakeDe1(deviceId: 'm1', name: 'DE1-Cafe');
      discovery.addDevice(machine);
      await tester.pumpWidget(
        buildView(
          directConnect: true,
          initialConnectionIntent: () => mockCm.scanAndConnect(),
        ),
      );
      await tester.pump();
      await flushDiscovery(tester);

      mockCm.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          pendingAmbiguity: AmbiguityReason.machinePicker,
          foundMachines: [machine],
        ),
      );
      await tester.pump();

      expect(mockCm.selectMachineCallCount, 1);
    });
  });
}
