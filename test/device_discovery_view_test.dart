import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/device_discovery_feature/device_discovery_view.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:reaprime/src/shared/connection_error_banner.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'helpers/fake_connection_manager.dart';
import 'helpers/mock_device_discovery_service.dart';
import 'helpers/mock_settings_service.dart';
import 'helpers/test_scale.dart';

void main() {
  late MockDeviceDiscoveryService mockService;
  late DeviceController deviceController;
  late De1Controller de1Controller;
  late ScaleController scaleController;
  late SettingsController settingsController;
  late ConnectionManager connectionManager;
  late WebUIService webUIService;
  late WebUIStorage webUIStorage;

  setUp(() async {
    mockService = MockDeviceDiscoveryService();
    deviceController = DeviceController([mockService]);
    await deviceController.initialize();

    de1Controller = De1Controller(controller: deviceController);
    scaleController = ScaleController();
    settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();

    connectionManager = ConnectionManager(
      deviceScanner: deviceController,
      de1Controller: de1Controller,
      scaleController: scaleController,
      settingsController: settingsController,
    );

    webUIService = WebUIService();
    webUIStorage = WebUIStorage(settingsController);
  });

  tearDown(() {
    connectionManager.dispose();
    deviceController.dispose();
    mockService.dispose();
  });

  Widget buildDiscoveryView() {
    return MediaQuery(
      data: MediaQueryData(size: Size(1024, 768)),
      child: ShadApp(
        home: Scaffold(
          body: Center(
            child: DeviceDiscoveryView(
              connectionManager: connectionManager,
              deviceController: deviceController,
              settingsController: settingsController,
              webUIService: webUIService,
              webUIStorage: webUIStorage,
              logger: Logger('test'),
            ),
          ),
        ),
      ),
    );
  }

  group('DeviceDiscoveryView', () {
    testWidgets('shows no devices found when scan finds nothing', (
      tester,
    ) async {
      final origOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.toString().contains('overflowed') ||
            details.toString().contains('deactivated')) {
          return;
        }
        origOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = origOnError);

      await tester.runAsync(() async {
        await tester.pumpWidget(buildDiscoveryView());
        await tester.pump();

        await Future.delayed(Duration(milliseconds: 500));
        await tester.pump();

        expect(find.text('No Decent Machines Found'), findsOneWidget);
        expect(find.text('Scan Again'), findsOneWidget);
        expect(find.text('Try Demo Mode'), findsOneWidget);
      });
    });

    testWidgets('Try Demo Mode button enables simulated devices and rescans', (
      tester,
    ) async {
      final origOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.toString().contains('overflowed') ||
            details.toString().contains('deactivated')) {
          return;
        }
        origOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = origOnError);

      await tester.runAsync(() async {
        await tester.pumpWidget(buildDiscoveryView());
        await tester.pump();

        await Future.delayed(Duration(milliseconds: 500));
        await tester.pump();

        expect(settingsController.simulatedDevices, isEmpty);

        final demoButton = find.text('Try Demo Mode');
        expect(demoButton, findsOneWidget);
        await tester.tap(demoButton);
        await tester.pump();

        expect(
          settingsController.simulatedDevices,
          contains(SimulatedDevicesTypes.machine),
        );
        expect(
          settingsController.simulatedDevices,
          contains(SimulatedDevicesTypes.scale),
        );

        await Future.delayed(Duration(milliseconds: 500));
        await tester.pump();
      });
    });

    testWidgets('shows a connected scale when no machine is found', (
      tester,
    ) async {
      final origOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.toString().contains('overflowed') ||
            details.toString().contains('deactivated')) {
          return;
        }
        origOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = origOnError);

      await tester.runAsync(() async {
        mockService.addDevice(TestScale());

        await tester.pumpWidget(buildDiscoveryView());
        await Future.delayed(Duration(milliseconds: 500));
        await tester.pump();

        expect(find.text('No Decent Machines Found'), findsNothing);
        expect(find.text('Scales'), findsOneWidget);
        expect(find.text('Mock Scale'), findsOneWidget);
      });
    });

    testWidgets('shows device picker when multiple machines found', (
      tester,
    ) async {
      final origOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.toString().contains('overflowed') ||
            details.toString().contains('deactivated')) {
          return;
        }
        origOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = origOnError);

      await tester.runAsync(() async {
        mockService.addDevice(MockDe1());
        mockService.addDevice(MockDe1(deviceId: 'mock-de1-2'));

        await tester.pumpWidget(buildDiscoveryView());

        await Future.delayed(Duration(milliseconds: 500));
        await tester.pump();

        expect(find.text('Machines'), findsOneWidget);
        expect(find.text('MockDe1'), findsWidgets);
      });
    });

    testWidgets('shows scales alongside machines in results view', (
      tester,
    ) async {
      final origOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.toString().contains('overflowed') ||
            details.toString().contains('deactivated')) {
          return;
        }
        origOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = origOnError);

      await tester.runAsync(() async {
        mockService.addDevice(MockDe1());
        mockService.addDevice(MockDe1(deviceId: 'mock-de1-2'));
        mockService.addDevice(TestScale());

        await tester.pumpWidget(buildDiscoveryView());

        await Future.delayed(Duration(milliseconds: 500));
        await tester.pump();

        expect(find.text('Machines'), findsOneWidget);
        expect(find.text('Scales'), findsOneWidget);
        expect(find.text('MockDe1'), findsWidgets);
        expect(find.text('Mock Scale'), findsOneWidget);
      });
    });

    testWidgets('mounts ConnectionErrorBanner when error present', (
      tester,
    ) async {
      final origOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.toString().contains('overflowed') ||
            details.toString().contains('deactivated')) {
          return;
        }
        origOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = origOnError);

      final fakeCm = FakeConnectionManager();
      addTearDown(fakeCm.dispose);

      Widget view() => MediaQuery(
        data: MediaQueryData(size: Size(1024, 768)),
        child: ShadApp(
          home: Scaffold(
            body: DeviceDiscoveryView(
              connectionManager: fakeCm,
              deviceController: deviceController,
              settingsController: settingsController,
              webUIService: webUIService,
              webUIStorage: webUIStorage,
              logger: Logger('test'),
            ),
          ),
        ),
      );

      await tester.runAsync(() async {
        fakeCm.setError(
          ConnectionError(
            kind: ConnectionErrorKind.scaleConnectFailed,
            severity: ConnectionErrorSeverity.error,
            timestamp: DateTime.now().toUtc(),
            message: 'Scale connect timed out.',
          ),
        );

        await tester.pumpWidget(view());
        await tester.pump();

        expect(find.byType(ConnectionErrorBanner), findsOneWidget);
        expect(find.text('Connect failed'), findsOneWidget);
        expect(
          find.textContaining('Scale connect timed out'),
          findsAtLeastNWidgets(1),
        );
      });
    });

    testWidgets('shows machine connection progress for connectingMachine '
        'status', (tester) async {
      final origOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.toString().contains('overflowed') ||
            details.toString().contains('deactivated')) {
          return;
        }
        origOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = origOnError);

      final fakeCm = FakeConnectionManager();
      addTearDown(fakeCm.dispose);
      fakeCm.emitStatus(
        const ConnectionStatus(phase: ConnectionPhase.connectingMachine),
      );

      Widget view() => MediaQuery(
        data: MediaQueryData(size: Size(1024, 768)),
        child: ShadApp(
          home: Scaffold(
            body: DeviceDiscoveryView(
              connectionManager: fakeCm,
              deviceController: deviceController,
              settingsController: settingsController,
              webUIService: webUIService,
              webUIStorage: webUIStorage,
              logger: Logger('test'),
            ),
          ),
        ),
      );

      await tester.runAsync(() async {
        await tester.pumpWidget(view());
        await tester.pump();

        expect(find.text('Connecting to your machine...'), findsOneWidget);
        expect(find.text('Retry'), findsNothing);
      });
    });
  });
}
