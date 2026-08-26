import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/services/webserver/info_handler.dart';
import 'package:reaprime/src/services/webserver/workflow_handler.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../helpers/mock_device_discovery_service.dart';

final class _ConnectionInfo implements HttpConnectionInfo {
  _ConnectionInfo(String address) : _address = InternetAddress(address);

  final InternetAddress _address;

  @override
  InternetAddress get remoteAddress => _address;

  @override
  int get remotePort => 0;

  @override
  int get localPort => 0;
}

void main() {
  test(
    'real API middleware rejects a burst and recovers after release',
    () async {
      final gate = AdmissionGate(
        globalConcurrent: 2,
        perClientConcurrent: 1,
        globalRate: 10,
        perClientRate: 10,
        maxTrackedClients: 4,
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final deviceController = DeviceController([MockDeviceDiscoveryService()]);
      await deviceController.initialize();
      addTearDown(deviceController.dispose);
      final de1Controller = De1Controller(controller: deviceController);
      addTearDown(de1Controller.dispose);
      await de1Controller.connectToDe1(MockDe1());
      await de1Controller.initSettled.firstWhere(
        (generation) => generation != null,
      );

      final router = Router().plus;
      InfoHandler().addRoutes(router);
      WorkflowHandler(
        controller: WorkflowController(),
        de1controller: de1Controller,
      ).addRoutes(router);
      final handler = buildWebServerHandler(router.call, admissionGate: gate);
      final activeWrite = de1Controller.runDeviceWrite((_) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final mutation = handler(
        _request(
          'PUT',
          '/api/v1/workflow',
          body: jsonEncode({
            'rinseData': {'flow': 3.0},
          }),
        ),
      );

      final rejected = await handler(_request('GET', '/api/v1/info'));
      expect(rejected.statusCode, 429);
      expect(rejected.headers['retry-after'], '1');
      expect(
        rejected.headers['access-control-allow-origin'],
        'http://localhost',
      );

      release.complete();
      await activeWrite;
      expect((await mutation).statusCode, 200);
      final admitted = await handler(_request('GET', '/api/v1/info'));
      expect(admitted.statusCode, 200);
      expect(gate.activeCount, 0);
    },
  );
}

Request _request(String method, String path, {Object? body}) {
  return Request(
    method,
    Uri.parse('http://localhost$path'),
    body: body,
    headers: {'origin': 'http://localhost', 'content-type': 'application/json'},
    context: {'shelf.io.connection_info': _ConnectionInfo('10.0.0.1')},
  );
}
