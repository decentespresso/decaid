import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:web_socket_channel/io.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/shot_state_event.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/webserver_service.dart';

import 'helpers/mock_device_discovery_service.dart';
import 'helpers/mock_settings_service.dart';

void main() {
  late De1Controller de1Controller;
  late De1Handler de1Handler;
  late HttpServer server;
  late Uri wsUri;

  setUp(() async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();

    de1Controller = De1Controller(controller: deviceController);

    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();

    de1Handler = De1Handler(
      controller: de1Controller,
      settingsController: settingsController,
      scaleController: ScaleController(),
      workflowController: WorkflowController(),
    );

    final app = Router().plus;
    de1Handler.addRoutes(app);

    server = await io.serve(app.call, 'localhost', 0);
    wsUri = Uri.parse('ws://localhost:${server.port}/ws/v1/machine/shotState');
  });

  tearDown(() async {
    await server.close(force: true);
  });

  (IOWebSocketChannel, Stream<Map<String, dynamic>>) connectWs() {
    final channel = IOWebSocketChannel.connect(wsUri);
    final messages = channel.stream
        .map((msg) => jsonDecode(msg.toString()) as Map<String, dynamic>)
        .asBroadcastStream();
    return (channel, messages);
  }

  group('shotState WebSocket', () {
    test('sends the current shot state on connect', () async {
      final (channel, messages) = connectWs();

      final first = await messages.first.timeout(const Duration(seconds: 2));

      expect(first['event'], 'state');
      expect(first['state'], 'idle');
      expect(first['decision'], isNull);

      await channel.sink.close();
    });

    test('streams published events to connected clients', () async {
      final (channel, messages) = connectWs();
      await messages.first.timeout(const Duration(seconds: 2));

      final decisionFrame = messages
          .where((m) => m['event'] == 'decision')
          .first
          .timeout(const Duration(seconds: 2));

      de1Controller.publishShotEvent(
        ShotStateEvent(
          event: 'decision',
          timestamp: DateTime.now(),
          shotId: 'shot-1',
          state: ShotState.pouring,
          machineState: MachineState.espresso,
          machineSubstate: MachineSubstate.pouring,
          profileFrame: 1,
          scaleConnected: true,
          scaleLost: false,
          machineHasAutonomousSAW: false,
          decision: const ShotDecision(
            kind: ShotDecisionKind.stop,
            reason: ShotDecisionReason.targetWeight,
            details: 'Target weight 36.0g reached',
          ),
        ),
      );

      final frame = await decisionFrame;
      expect(frame['shotId'], 'shot-1');
      expect(frame['state'], 'pouring');
      expect(frame['decision']['kind'], 'stop');
      expect(frame['decision']['reason'], 'targetWeight');

      await channel.sink.close();
    });

    test('a late joiner replays the latest event', () async {
      de1Controller.publishShotEvent(
        ShotStateEvent(
          event: 'state',
          timestamp: DateTime.now(),
          shotId: 'shot-2',
          state: ShotState.pouring,
          machineState: MachineState.espresso,
          machineSubstate: MachineSubstate.pouring,
          profileFrame: 0,
          scaleConnected: false,
          scaleLost: false,
          machineHasAutonomousSAW: false,
        ),
      );

      final (channel, messages) = connectWs();
      final first = await messages.first.timeout(const Duration(seconds: 2));

      expect(first['state'], 'pouring');
      expect(first['shotId'], 'shot-2');

      await channel.sink.close();
    });
  });
}
