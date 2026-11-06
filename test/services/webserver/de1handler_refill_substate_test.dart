import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.utils.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:web_socket_channel/io.dart';

import '../../helpers/mock_device_discovery_service.dart';
import '../../helpers/mock_settings_service.dart';
import '../../helpers/test_de1.dart';

MachineStateSnapshot _stateFromRaw(int state, int substate) {
  return MachineStateSnapshot(
    state: mapDe1ToMachineState(De1StateEnum.fromHexValue(state)),
    substate: mapDe1SubToMachineSubstate(De1SubState.fromHexValue(substate)!),
  );
}

Map<String, dynamic> _statePayload(Map<String, dynamic> snapshot) {
  return snapshot['state'] as Map<String, dynamic>;
}

void main() {
  late TestDe1 de1;
  late HttpServer server;
  late HttpClient client;

  setUp(() async {
    final deviceController = DeviceController([MockDeviceDiscoveryService()]);
    addTearDown(deviceController.dispose);
    await deviceController.initialize();
    final de1Controller = De1Controller(controller: deviceController);
    addTearDown(de1Controller.dispose);
    await de1Controller.connectToDe1(TestDe1());
    de1 = de1Controller.connectedDe1OrNull! as TestDe1;

    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();
    final scaleController = ScaleController();
    addTearDown(scaleController.dispose);
    final handler = De1Handler(
      controller: de1Controller,
      settingsController: settingsController,
      scaleController: scaleController,
      workflowController: WorkflowController(),
    );
    final app = Router().plus;
    handler.addRoutes(app);
    server = await shelf_io.serve(app.call, InternetAddress.loopbackIPv4, 0);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
  });

  Uri httpUri() =>
      Uri.parse('http://127.0.0.1:${server.port}/api/v1/machine/state');

  Uri wsUri() =>
      Uri.parse('ws://127.0.0.1:${server.port}/ws/v1/machine/snapshot');

  Future<Map<String, dynamic>> getMachineState() async {
    final request = await client.getUrl(httpUri());
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> nextState(
    Stream<Map<String, dynamic>> frames,
    String substate,
  ) {
    return frames.firstWhere(
      (frame) => _statePayload(frame)['substate'] == substate,
    );
  }

  test(
    'REST and WebSocket expose ordinary and stopped refill substates',
    () async {
      de1.emitSnapshot(
        de1.snapshotSubject.value.copyWith(state: _stateFromRaw(0x11, 0x00)),
      );
      final ordinaryRest = await getMachineState();
      expect(_statePayload(ordinaryRest), {
        'state': 'needsWater',
        'substate': 'idle',
      });

      final socket = IOWebSocketChannel.connect(wsUri());
      addTearDown(() => socket.sink.close());
      final frames = socket.stream
          .map(
            (message) => jsonDecode(message.toString()) as Map<String, dynamic>,
          )
          .asBroadcastStream();
      final ordinaryWs = await frames.first.timeout(const Duration(seconds: 2));
      expect(_statePayload(ordinaryWs), {
        'state': 'needsWater',
        'substate': 'idle',
      });

      final stoppedWsFuture = nextState(frames, 'refillStopped');
      de1.emitSnapshot(
        de1.snapshotSubject.value.copyWith(state: _stateFromRaw(0x11, 0x11)),
      );
      final stoppedRest = await getMachineState();
      final stoppedWs = await stoppedWsFuture.timeout(
        const Duration(seconds: 2),
      );

      expect(_statePayload(stoppedRest), {
        'state': 'needsWater',
        'substate': 'refillStopped',
      });
      expect(_statePayload(stoppedWs), {
        'state': 'needsWater',
        'substate': 'refillStopped',
      });
    },
  );
}
