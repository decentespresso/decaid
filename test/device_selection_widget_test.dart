import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/home_feature/widgets/device_selection_widget.dart';
import 'package:reaprime/src/models/device/device.dart' as dev;
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'helpers/mock_device_discovery_service.dart';
import 'helpers/test_scale.dart';

Widget buildTestApp(Widget child) {
  return ShadApp(home: Scaffold(body: child));
}

void main() {
  late MockDeviceDiscoveryService mockService;
  late DeviceController deviceController;

  setUp(() async {
    mockService = MockDeviceDiscoveryService();
    deviceController = DeviceController([mockService]);
    await deviceController.initialize();
  });

  tearDown(() {
    deviceController.dispose();
    mockService.dispose();
  });

  group('DeviceSelectionWidget', () {
    testWidgets('shows empty state when no machines found', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          DeviceSelectionWidget(
            deviceController: deviceController,
            deviceType: dev.DeviceType.machine,
            onDeviceTapped: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No machines found.'), findsOneWidget);
    });

    testWidgets('shows empty state when no scales found', (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          DeviceSelectionWidget(
            deviceController: deviceController,
            deviceType: dev.DeviceType.scale,
            onDeviceTapped: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No scales found.'), findsOneWidget);
    });

    testWidgets('displays discovered machines', (tester) async {
      mockService.addDevice(MockDe1());
      await tester.pump();

      await tester.pumpWidget(
        buildTestApp(
          DeviceSelectionWidget(
            deviceController: deviceController,
            deviceType: dev.DeviceType.machine,
            onDeviceTapped: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('MockDe1'), findsOneWidget);
      expect(find.text('No machines found.'), findsNothing);
    });

    testWidgets('displays discovered scales', (tester) async {
      mockService.addDevice(TestScale());
      await tester.pump();

      await tester.pumpWidget(
        buildTestApp(
          DeviceSelectionWidget(
            deviceController: deviceController,
            deviceType: dev.DeviceType.scale,
            onDeviceTapped: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Mock Scale'), findsOneWidget);
      expect(find.text('No scales found.'), findsNothing);
    });

    testWidgets('filters: machine widget only shows machines', (tester) async {
      mockService.addDevice(MockDe1());
      mockService.addDevice(TestScale());
      await tester.pump();

      await tester.pumpWidget(
        buildTestApp(
          DeviceSelectionWidget(
            deviceController: deviceController,
            deviceType: dev.DeviceType.machine,
            onDeviceTapped: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('MockDe1'), findsOneWidget);
      expect(find.text('Mock Scale'), findsNothing);
    });

    testWidgets('filters: scale widget only shows scales', (tester) async {
      mockService.addDevice(MockDe1());
      mockService.addDevice(TestScale());
      await tester.pump();

      await tester.pumpWidget(
        buildTestApp(
          DeviceSelectionWidget(
            deviceController: deviceController,
            deviceType: dev.DeviceType.scale,
            onDeviceTapped: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Mock Scale'), findsOneWidget);
      expect(find.text('MockDe1'), findsNothing);
    });

    testWidgets('tap callback fires with correct device', (tester) async {
      dev.Device? tappedDevice;

      final machine = MockDe1(deviceId: 'test-de1');
      mockService.addDevice(machine);
      await tester.pump();

      await tester.pumpWidget(
        buildTestApp(
          DeviceSelectionWidget(
            deviceController: deviceController,
            deviceType: dev.DeviceType.machine,
            onDeviceTapped: (device) {
              tappedDevice = device;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('MockDe1'));
      await tester.pumpAndSettle();

      expect(tappedDevice, isNotNull);
      expect(tappedDevice!.deviceId, equals('test-de1'));
    });

    testWidgets('shows connecting indicator for connecting device', (
      tester,
    ) async {
      final machine = MockDe1(deviceId: 'connecting-de1');
      mockService.addDevice(machine);
      await tester.pump();

      await tester.pumpWidget(
        buildTestApp(
          DeviceSelectionWidget(
            deviceController: deviceController,
            deviceType: dev.DeviceType.machine,
            onDeviceTapped: (_) {},
            connectingDeviceId: 'connecting-de1',
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('displays error message when set', (tester) async {
      mockService.addDevice(MockDe1());
      await tester.pump();

      await tester.pumpWidget(
        buildTestApp(
          DeviceSelectionWidget(
            deviceController: deviceController,
            deviceType: dev.DeviceType.machine,
            onDeviceTapped: (_) {},
            showHeader: true,
            headerText: 'Machines',
            errorMessage: 'Connection failed: timeout',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Connection failed: timeout'), findsOneWidget);
    });
  });
}
