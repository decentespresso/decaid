import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _FakeConnectionInfo implements HttpConnectionInfo {
  _FakeConnectionInfo(String address) : _address = InternetAddress(address);

  final InternetAddress _address;

  @override
  InternetAddress get remoteAddress => _address;

  @override
  int get remotePort => 0;

  @override
  int get localPort => 0;
}

void main() {
  group('AdmissionGate', () {
    test('enforces per-client concurrency and releases capacity', () {
      final gate = _gate(perClientConcurrent: 1);

      expect(gate.acquire('a'), AdmissionDecision.accepted);
      expect(gate.acquire('a'), AdmissionDecision.perClientLimit);

      gate.release('a');
      expect(gate.acquire('a'), AdmissionDecision.accepted);
      gate.release('a');
      expect(gate.activeCount, 0);
    });

    test('enforces global concurrency across clients', () {
      final gate = _gate(globalConcurrent: 1);

      expect(gate.acquire('a'), AdmissionDecision.accepted);
      expect(gate.acquire('b'), AdmissionDecision.globalLimit);
    });

    test('enforces accepted-request rates and resets after one second', () {
      var now = 0;
      final perClient = _gate(perClientRate: 1, nowMs: () => now);
      expect(perClient.acquire('a'), AdmissionDecision.accepted);
      perClient.release('a');
      expect(perClient.acquire('a'), AdmissionDecision.perClientLimit);

      now = 1000;
      expect(perClient.acquire('a'), AdmissionDecision.accepted);

      final global = _gate(globalRate: 1, nowMs: () => now);
      expect(global.acquire('a'), AdmissionDecision.accepted);
      global.release('a');
      expect(global.acquire('b'), AdmissionDecision.globalLimit);
    });

    test('bounds clients and removes expired inactive entries', () {
      var now = 0;
      final gate = _gate(maxTrackedClients: 2, nowMs: () => now);

      expect(gate.acquire('a'), AdmissionDecision.accepted);
      gate.release('a');
      expect(gate.acquire('b'), AdmissionDecision.accepted);
      gate.release('b');
      expect(gate.acquire('c'), AdmissionDecision.globalLimit);
      expect(gate.trackedClientCount, 2);

      now = 1000;
      expect(gate.acquire('c'), AdmissionDecision.accepted);
      expect(gate.trackedClientCount, 1);
    });
  });

  group('API admission middleware', () {
    test('returns 429 with CORS and admits work after release', () async {
      final blocked = Completer<void>();
      final entered = Completer<void>();
      final handler = const Pipeline()
          .addMiddleware(corsHeaders())
          .addMiddleware(apiAdmissionMiddleware(_gate(perClientConcurrent: 1)))
          .addHandler((_) async {
            if (!entered.isCompleted) entered.complete();
            await blocked.future;
            return Response.ok('ok');
          });
      final request = _request('10.0.0.1');

      final first = handler(request);
      await entered.future;
      final rejected = await handler(request);

      expect(rejected.statusCode, 429);
      expect(rejected.headers['retry-after'], '1');
      expect(
        rejected.headers['access-control-allow-origin'],
        'http://localhost',
      );

      blocked.complete();
      expect((await first).statusCode, 200);
      expect((await handler(request)).statusCode, 200);
    });

    test('returns 503 for global saturation', () async {
      final blocked = Completer<void>();
      final entered = Completer<void>();
      final handler = apiAdmissionMiddleware(_gate(globalConcurrent: 1))((
        request,
      ) async {
        if (!entered.isCompleted) entered.complete();
        await blocked.future;
        return Response.ok('ok');
      });

      final first = handler(_request('10.0.0.1'));
      await entered.future;
      final rejected = await handler(_request('10.0.0.2'));

      expect(rejected.statusCode, 503);
      expect(rejected.headers['retry-after'], '1');
      blocked.complete();
      await first;
    });

    test('skips OPTIONS, static, and WebSocket paths', () async {
      final gate = _gate(globalRate: 1);
      final handler = apiAdmissionMiddleware(gate)(
        (_) async => Response.ok('ok'),
      );

      expect(
        (await handler(_request('10.0.0.1', method: 'OPTIONS'))).statusCode,
        200,
      );
      expect((await handler(_request('10.0.0.1', path: '/'))).statusCode, 200);
      expect(
        (await handler(
          _request('10.0.0.1', path: '/ws/v1/devices'),
        )).statusCode,
        200,
      );
      expect((await handler(_request('10.0.0.1'))).statusCode, 200);
    });
  });

  test('WebSocket admission releases a closed connection', () async {
    final gate = _gate(perClientConcurrent: 1);
    final connected = StreamController<WebSocketChannel>.broadcast();
    final handler = admittedWebSocketHandler((channel, _) {
      channel.stream.listen((_) {});
      connected.add(channel);
    }, gate: gate);
    final server = await shelf_io.serve(handler, 'localhost', 0);
    addTearDown(() async {
      await connected.close();
      await server.close(force: true);
    });
    final uri = 'ws://localhost:${server.port}';

    final serverSideFuture = connected.stream.first;
    final first = await WebSocket.connect(uri);
    final serverSide = await serverSideFuture;
    await expectLater(
      WebSocket.connect(uri),
      throwsA(
        isA<WebSocketException>().having(
          (error) => error.toString(),
          'status',
          contains('429'),
        ),
      ),
    );

    await first.close();
    await serverSide.sink.done;
    final nextServerSide = connected.stream.first;
    final next = await WebSocket.connect(uri);
    final nextChannel = await nextServerSide;
    await next.close();
    await nextChannel.sink.done;
    expect(gate.activeCount, 0);
  });

  test('WebSocket admission releases when setup fails after hijack', () async {
    final gate = _gate(perClientConcurrent: 1);
    final errors = <Object>[];

    await runZonedGuarded(() async {
      final handler = admittedWebSocketHandler(
        (_, _) {},
        gate: gate,
        webSocketHandlerBuilder: (_) {
          return (_) {
            Future<void>.microtask(
              () => throw StateError('upgrade setup failed'),
            );
            throw const HijackException();
          };
        },
      );

      await expectLater(
        Future<Response>.sync(() => handler(_request('10.0.0.1'))),
        throwsA(isA<HijackException>()),
      );
      await Future<void>.delayed(Duration.zero);
    }, (error, _) => errors.add(error));

    expect(errors, [isA<StateError>()]);
    expect(gate.activeCount, 0);
  });
}

AdmissionGate _gate({
  int globalConcurrent = 10,
  int perClientConcurrent = 10,
  int globalRate = 10,
  int perClientRate = 10,
  int maxTrackedClients = 10,
  int Function()? nowMs,
}) {
  return AdmissionGate(
    globalConcurrent: globalConcurrent,
    perClientConcurrent: perClientConcurrent,
    globalRate: globalRate,
    perClientRate: perClientRate,
    maxTrackedClients: maxTrackedClients,
    nowMs: nowMs,
  );
}

Request _request(
  String client, {
  String method = 'GET',
  String path = '/api/v1/info',
}) {
  return Request(
    method,
    Uri.parse('http://localhost$path'),
    headers: {'origin': 'http://localhost'},
    context: {'shelf.io.connection_info': _FakeConnectionInfo(client)},
  );
}
