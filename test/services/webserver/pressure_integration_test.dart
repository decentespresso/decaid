import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_plus/shelf_plus.dart';

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
      final router = Router().plus
        ..get('/api/v1/info', (_) async {
          entered.complete();
          await release.future;
          return Response.ok('info');
        })
        ..put('/api/v1/workflow', (Request request) async {
          return Response.ok(await request.readAsString());
        });
      final handler = const Pipeline()
          .addMiddleware(corsHeaders())
          .addMiddleware(apiAdmissionMiddleware(gate))
          .addHandler(router.call);
      final get = handler(_request('GET', '/api/v1/info'));
      await entered.future;

      final rejected = await handler(
        _request(
          'PUT',
          '/api/v1/workflow',
          body: jsonEncode({
            'rinseData': {'flow': 3.0},
          }),
        ),
      );
      expect(rejected.statusCode, 429);
      expect(rejected.headers['retry-after'], '1');
      expect(
        rejected.headers['access-control-allow-origin'],
        'http://localhost',
      );

      release.complete();
      expect((await get).statusCode, 200);
      final admitted = await handler(
        _request(
          'PUT',
          '/api/v1/workflow',
          body: jsonEncode({
            'rinseData': {'flow': 3.0},
          }),
        ),
      );
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
