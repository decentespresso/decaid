import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scan_state_guardian.dart';
import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/scan_report.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/steps/scan_step.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_connection_manager.dart';
import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_device_scanner.dart';
import '../helpers/mock_scale_controller.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_scale.dart';

class _TrackingOnboardingController extends OnboardingController {
  int advanceCallCount = 0;

  _TrackingOnboardingController()
    : super(
        steps: [
          OnboardingStep(
            id: 'scan',
            shouldShow: () async => true,
            builder: (_) => const SizedBox(),
          ),
          OnboardingStep(
            id: 'next',
            shouldShow: () async => true,
            builder: (_) => const SizedBox(),
          ),
        ],
      );

  @override
  void advance() {
    advanceCallCount++;
    super.advance();
  }
}

void main() {
  late MockConnectionManager mockConnectionManager;
  late MockBleDiscoveryService mockBleService;
  late ScanStateGuardian scanStateGuardian;
  late _TrackingOnboardingController onboardingController;
  late SettingsController settingsController;
  late MockDeviceScanner mockDeviceScanner;
  late MockDe1Controller mockDe1Controller;
  late MockScaleController mockScaleController;

  setUp(() async {
    mockDeviceScanner = MockDeviceScanner();
    mockDe1Controller = MockDe1Controller(controller: DeviceController([]));
    mockScaleController = MockScaleController();
    settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();

    mockConnectionManager = MockConnectionManager(
      deviceScanner: mockDeviceScanner,
      de1Controller: mockDe1Controller,
      scaleController: mockScaleController,
      settingsController: settingsController,
    );

    mockBleService = MockBleDiscoveryService();
    scanStateGuardian = ScanStateGuardian(bleService: mockBleService);

    onboardingController = _TrackingOnboardingController();
    await onboardingController.initialize();
  });

  tearDown(() {
    mockConnectionManager.dispose();
    scanStateGuardian.dispose();
    mockBleService.dispose();
    mockDeviceScanner.dispose();
  });

  Widget buildSubject() {
    return ShadApp(
      home: Scaffold(
        body: ScanStepView(
          onboardingController: onboardingController,
          connectionManager: mockConnectionManager,
          deviceController: DeviceController([]),
          settingsController: settingsController,
          scanStateGuardian: scanStateGuardian,
        ),
      ),
    );
  }

  group('scanning phase', () {
    testWidgets('shows progress indicator during scanning', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();

      expect(find.byType(ShadProgress), findsOneWidget);
    });

    testWidgets('does not show "taking too long" button initially', (
      tester,
    ) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();

      expect(find.text('This is taking a while...'), findsOneWidget);
      final animatedOpacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animatedOpacity.opacity, 0.0);
    });

    testWidgets('shows "taking too long" button after 8 seconds', (
      tester,
    ) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();

      await tester.pump(ScanStepView.scanTooLongThreshold);
      await tester.pump(const Duration(milliseconds: 500));

      final animatedOpacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animatedOpacity.opacity, 1.0);
    });
  });

  group('taking too long bottom sheet', () {
    testWidgets('opens bottom sheet with 4 options', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();

      await tester.pump(ScanStepView.scanTooLongThreshold);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('This is taking a while...'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Re-start scan'), findsOneWidget);
      expect(find.text('Troubleshoot'), findsOneWidget);
      expect(find.text('Export logs'), findsOneWidget);
      expect(find.text('Continue to Dashboard'), findsOneWidget);
    });

    testWidgets('Re-start scan uses the scan-first connection path', (
      tester,
    ) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      await tester.pump(ScanStepView.scanTooLongThreshold);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('This is taking a while...'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final before = mockConnectionManager.scanAndConnectCallCount;
      await tester.tap(find.text('Re-start scan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(mockConnectionManager.scanAndConnectCallCount, before + 1);
    });

    testWidgets('Continue to Dashboard calls advance', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      await tester.pump(ScanStepView.scanTooLongThreshold);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('This is taking a while...'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final before = onboardingController.advanceCallCount;
      await tester.tap(find.text('Continue to Dashboard'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(onboardingController.advanceCallCount, before + 1);
    });
  });

  group('connecting phase', () {
    testWidgets('shows "Connecting to your machine..." for connectingMachine', (
      tester,
    ) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();

      mockConnectionManager.emitStatus(
        const ConnectionStatus(phase: ConnectionPhase.connectingMachine),
      );
      await tester.pump();

      expect(find.text('Connecting to your machine...'), findsOneWidget);
      expect(find.byType(ShadProgress), findsOneWidget);
    });

    testWidgets('shows "Connecting to your scale..." for connectingScale', (
      tester,
    ) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();

      mockConnectionManager.emitStatus(
        const ConnectionStatus(phase: ConnectionPhase.connectingScale),
      );
      await tester.pump();

      expect(find.text('Connecting to your scale...'), findsOneWidget);
    });
  });

  group('ready phase', () {
    testWidgets('calls onboardingController.advance() on ready', (
      tester,
    ) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();

      mockConnectionManager.emitStatus(
        const ConnectionStatus(phase: ConnectionPhase.ready),
      );
      await tester.pump();

      expect(onboardingController.advanceCallCount, 1);
    });

    testWidgets('only advances once even if ready emitted multiple times', (
      tester,
    ) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();

      mockConnectionManager.emitStatus(
        const ConnectionStatus(phase: ConnectionPhase.ready),
      );
      await tester.pump();

      mockConnectionManager.emitStatus(
        const ConnectionStatus(phase: ConnectionPhase.ready),
      );
      await tester.pump();

      expect(onboardingController.advanceCallCount, 1);
    });
  });

  group('error states', () {
    testWidgets('shows error view with retry on connection error', (
      tester,
    ) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();

      mockConnectionManager.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          error: ConnectionError(
            kind: ConnectionErrorKind.machineConnectFailed,
            severity: ConnectionErrorSeverity.error,
            timestamp: DateTime.utc(2026),
            message: 'Connection timed out',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Connection Error'), findsOneWidget);
      expect(find.text('Connection timed out'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('retry button calls connect', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();

      mockConnectionManager.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          error: ConnectionError(
            kind: ConnectionErrorKind.machineConnectFailed,
            severity: ConnectionErrorSeverity.error,
            timestamp: DateTime.utc(2026),
            message: 'Connection timed out',
          ),
        ),
      );
      await tester.pump();

      final before = mockConnectionManager.connectCallCount;
      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(mockConnectionManager.connectCallCount, before + 1);
    });
  });

  group('no devices found', () {
    testWidgets('shows no devices view when idle with no machines', (
      tester,
    ) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();

      mockConnectionManager.setLastScanReport(
        const ScanReport(
          totalBleDevicesSeen: 0,
          matchedDevices: [],
          scanDuration: Duration(seconds: 5),
          adapterStateAtStart: AdapterState.poweredOn,
          adapterStateAtEnd: AdapterState.poweredOn,
          scanTerminationReason: ScanTerminationReason.completed,
        ),
      );

      mockConnectionManager.emitStatus(
        const ConnectionStatus(phase: ConnectionPhase.idle),
      );
      await tester.pump();

      expect(find.text('No Bluetooth Devices Found'), findsOneWidget);
      expect(find.text('Scan Again'), findsOneWidget);
      expect(find.text('Continue to Dashboard'), findsOneWidget);
    });

    testWidgets('Continue to Dashboard advances onboarding', (tester) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();

      mockConnectionManager.setLastScanReport(
        const ScanReport(
          totalBleDevicesSeen: 0,
          matchedDevices: [],
          scanDuration: Duration(seconds: 5),
          adapterStateAtStart: AdapterState.poweredOn,
          adapterStateAtEnd: AdapterState.poweredOn,
          scanTerminationReason: ScanTerminationReason.completed,
        ),
      );

      mockConnectionManager.emitStatus(
        const ConnectionStatus(phase: ConnectionPhase.idle),
      );
      await tester.pump();

      await tester.tap(find.text('Continue to Dashboard'));
      await tester.pump();

      expect(onboardingController.advanceCallCount, 1);
    });
  });

  group('connection status authority', () {
    testWidgets('guardian adapter events do not create independent errors', (
      tester,
    ) async {
      mockBleService.setAdapterState(AdapterState.poweredOn);
      await tester.runAsync(() => Future.delayed(Duration.zero));
      await tester.pumpWidget(buildSubject());
      await tester.pump();

      mockBleService.setAdapterState(AdapterState.poweredOff);
      await tester.runAsync(() => Future.delayed(Duration.zero));
      await tester.pump();

      expect(find.text('Bluetooth Unavailable'), findsNothing);
    });

    testWidgets('connection status shows and clears the adapter condition', (
      tester,
    ) async {
      await tester.pumpWidget(buildSubject());
      await tester.pump();
      final error = ConnectionError(
        kind: ConnectionErrorKind.adapterOff,
        severity: ConnectionErrorSeverity.error,
        timestamp: DateTime.utc(2025),
        message: 'Bluetooth is turned off.',
      );

      mockConnectionManager.emitStatus(
        ConnectionStatus(
          error: error,
          conditions: [
            TransportCondition(
              transportType: TransportType.ble,
              affectedDeviceTypes: const {DeviceType.machine, DeviceType.scale},
              connectionError: error,
            ),
          ],
        ),
      );
      await tester.pump();
      expect(find.text('Bluetooth Unavailable'), findsOneWidget);

      mockConnectionManager.emitStatus(const ConnectionStatus());
      await tester.pump();
      expect(find.text('Bluetooth Unavailable'), findsNothing);
    });
  });

  group('createScanStep factory', () {
    test('creates step with id "scan" that always shows', () async {
      final step = createScanStep(
        connectionManager: mockConnectionManager,
        deviceController: DeviceController([]),
        settingsController: settingsController,
        scanStateGuardian: scanStateGuardian,
      );

      expect(step.id, 'scan');
      expect(await step.shouldShow(), isTrue);
    });
  });

  group('preferred device not found messaging', () {
    late MockDeviceDiscoveryService deviceDiscoveryService;
    late DeviceController deviceControllerWithDevices;

    Widget buildSubjectWithDevices() {
      return ShadApp(
        home: Scaffold(
          body: ScanStepView(
            onboardingController: onboardingController,
            connectionManager: mockConnectionManager,
            deviceController: deviceControllerWithDevices,
            settingsController: settingsController,
            scanStateGuardian: scanStateGuardian,
          ),
        ),
      );
    }

    setUp(() {
      deviceDiscoveryService = MockDeviceDiscoveryService();
      deviceControllerWithDevices = DeviceController([deviceDiscoveryService]);
    });

    tearDown(() {
      deviceDiscoveryService.dispose();
    });

    testWidgets(
      'shows preferred machine not found message when preferred is set but not among found machines',
      (tester) async {
        await settingsController.setPreferredMachineId('preferred-123');

        final differentMachine = FakeDe1(deviceId: 'other-456');

        deviceDiscoveryService.addDevice(differentMachine);
        await deviceControllerWithDevices.initialize();
        await tester.pump();

        await tester.pumpWidget(buildSubjectWithDevices());
        await tester.pump();

        mockConnectionManager.emitStatus(
          ConnectionStatus(
            phase: ConnectionPhase.idle,
            foundMachines: [differentMachine],
            pendingAmbiguity: AmbiguityReason.machinePicker,
          ),
        );
        await tester.pump();

        expect(
          find.text(
            "Your preferred machine wasn't found, but we discovered these:",
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'shows normal header when preferred machine is among found machines',
      (tester) async {
        final machine = FakeDe1(deviceId: 'preferred-123');
        await settingsController.setPreferredMachineId('preferred-123');

        deviceDiscoveryService.addDevice(machine);
        await deviceControllerWithDevices.initialize();
        await tester.pump();

        await tester.pumpWidget(buildSubjectWithDevices());
        await tester.pump();

        mockConnectionManager.emitStatus(
          ConnectionStatus(
            phase: ConnectionPhase.idle,
            foundMachines: [machine],
            pendingAmbiguity: AmbiguityReason.machinePicker,
          ),
        );
        await tester.pump();

        expect(find.text('Machines'), findsOneWidget);
        expect(
          find.text(
            "Your preferred machine wasn't found, but we discovered these:",
          ),
          findsNothing,
        );
      },
    );

    testWidgets('shows normal header when no preferred machine is configured', (
      tester,
    ) async {
      final machine = FakeDe1(deviceId: 'some-machine');

      deviceDiscoveryService.addDevice(machine);
      await deviceControllerWithDevices.initialize();
      await tester.pump();

      await tester.pumpWidget(buildSubjectWithDevices());
      await tester.pump();

      mockConnectionManager.emitStatus(
        ConnectionStatus(
          phase: ConnectionPhase.idle,
          foundMachines: [machine],
          pendingAmbiguity: AmbiguityReason.machinePicker,
        ),
      );
      await tester.pump();

      expect(find.text('Machines'), findsOneWidget);
    });

    testWidgets(
      'shows preferred scale not found message when preferred is set but not among found scales',
      (tester) async {
        await settingsController.setPreferredScaleId('preferred-scale-123');

        final differentScale = TestScale(
          deviceId: 'other-scale-456',
          name: 'Other Scale',
        );
        final machine = FakeDe1(deviceId: 'machine-1');

        deviceDiscoveryService.addDevice(machine);
        deviceDiscoveryService.addDevice(differentScale);
        await deviceControllerWithDevices.initialize();
        await tester.pump();

        await tester.pumpWidget(buildSubjectWithDevices());
        await tester.pump();

        mockConnectionManager.emitStatus(
          ConnectionStatus(
            phase: ConnectionPhase.idle,
            foundMachines: [machine],
            foundScales: [differentScale],
            pendingAmbiguity: AmbiguityReason.scalePicker,
          ),
        );
        await tester.pump();

        expect(
          find.text(
            "Your preferred scale wasn't found, but we discovered these:",
          ),
          findsOneWidget,
        );
      },
    );
  });

  group('directConnect', () {
    testWidgets(
      'ScanFlowView receives directConnect: true when set on ScanStepView',
      (tester) async {
        await tester.pumpWidget(
          ShadApp(
            home: Scaffold(
              body: ScanStepView(
                onboardingController: onboardingController,
                connectionManager: mockConnectionManager,
                deviceController: DeviceController([]),
                settingsController: settingsController,
                scanStateGuardian: scanStateGuardian,
                directConnect: true,
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(ShadProgress), findsOneWidget);
      },
    );

    testWidgets('does not crash with directConnect: false (default)', (
      tester,
    ) async {
      await tester.pumpWidget(
        ShadApp(
          home: Scaffold(
            body: ScanStepView(
              onboardingController: onboardingController,
              connectionManager: mockConnectionManager,
              deviceController: DeviceController([]),
              settingsController: settingsController,
              scanStateGuardian: scanStateGuardian,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(ShadProgress), findsOneWidget);
    });
  });
}
