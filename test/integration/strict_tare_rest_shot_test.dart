import 'package:flutter/widgets.dart' show GlobalKey, NavigatorState;
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/de1_state_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/shot_state_event.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/shot_event_storage.dart';
import '../helpers/test_scale.dart';
import '../helpers/test_scale_controller.dart';

final class _RecordingMockDe1 extends MockDe1 {
  final List<MachineState> requestedStates = [];

  @override
  Future<void> requestState(MachineState newState) async {
    requestedStates.add(newState);
    await super.requestState(newState);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a REST-started blockOnNoScale shot with a silent connected scale '
      'aborts on tareUnconfirmed and saves nothing', () async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    final de1Controller = De1Controller(controller: deviceController);
    final machine = _RecordingMockDe1();
    de1Controller.adoptDevice(machine);
    await machine.onConnect();
    await de1Controller.initSettled.firstWhere(
      (generation) => generation != null,
    );

    final settingsService = MockSettingsService();
    await settingsService.updateGatewayMode(GatewayMode.tracking);
    await settingsService.setBlockOnNoScale(true);
    final settingsController = SettingsController(settingsService);
    await settingsController.loadSettings();

    final scale = TestScale();
    final scaleController = TestScaleController(scale);
    final workflowController = WorkflowController();
    final storage = ShotEventStorage();

    final manager = De1StateManager(
      de1Controller: de1Controller,
      scaleController: scaleController,
      workflowController: workflowController,
      persistenceController: PersistenceController(storageService: storage),
      settingsController: settingsController,
      connectionManager: ConnectionManager(
        deviceScanner: deviceController,
        de1Controller: de1Controller,
        scaleController: scaleController,
        settingsController: settingsController,
      ),
      navigatorKey: GlobalKey<NavigatorState>(),
    );
    final events = <ShotStateEvent>[];
    final subscription = de1Controller.shotState.listen(events.add);
    addTearDown(() async {
      await subscription.cancel();
      manager.dispose();
      await machine.disconnect();
      await de1Controller.dispose();
      scale.dispose();
    });

    final app = Router().plus;
    De1Handler(
      controller: de1Controller,
      settingsController: settingsController,
      scaleController: scaleController,
      workflowController: workflowController,
    ).addRoutes(app);

    final response = await app.call(
      Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/machine/state/espresso'),
      ),
    );
    expect(response.statusCode, 200);

    final abort = await de1Controller.shotState
        .firstWhere(
          (e) =>
              e.event == 'decision' &&
              e.decision?.kind == ShotDecisionKind.abort,
        )
        .timeout(const Duration(seconds: 10));

    expect(abort.decision?.reason, ShotDecisionReason.tareUnconfirmed);
    expect(scale.tareCallCount, greaterThan(0));
    expect(machine.requestedStates.first, MachineState.espresso);
    expect(machine.requestedStates, contains(MachineState.idle));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(storage.shots, isEmpty);
  });
}
