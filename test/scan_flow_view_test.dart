import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scan_state_guardian.dart';
import 'package:reaprime/src/device_discovery_feature/scan_flow_view.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'helpers/mock_connection_manager.dart';
import 'helpers/mock_de1_controller.dart';
import 'helpers/mock_device_discovery_service.dart';
import 'helpers/mock_device_scanner.dart';
import 'helpers/mock_scale_controller.dart';
import 'helpers/mock_settings_service.dart';
import 'helpers/test_scale.dart';

void main() {
  late MockConnectionManager mockCm;
  late MockDeviceScanner mockScanner;
  late DeviceController deviceController;
  late SettingsController settingsController;
  late ScanStateGuardian scanStateGuardian;

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

    final discovery = MockBleDiscoveryService();
    deviceController = DeviceController([discovery]);
    await deviceController.initialize();
    settingsController = settings;
    scanStateGuardian = ScanStateGuardian(bleService: discovery);
  });

  Widget buildView({VoidCallback? initialConnectionIntent}) {
    return ShadApp(
      home: ScanFlowView(
        connectionManager: mockCm,
        deviceController: deviceController,
        settingsController: settingsController,
        scanStateGuardian: scanStateGuardian,
        initialConnectionIntent: initialConnectionIntent,
        onConnected: () {},
        onExit: () {},
      ),
    );
  }

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

        // Picker must still be visible with both candidates.
        expect(find.text('DE1 #1'), findsOneWidget);
        expect(find.text('DE1 #2'), findsOneWidget);
        expect(find.text('Connect'), findsOneWidget);

        // Failure text must be visible.
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

        // Select the scale — call selectScale, not a new scan.
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
}
