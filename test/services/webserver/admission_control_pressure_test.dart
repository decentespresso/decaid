import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
  test('100-request burst is bounded without an admission queue', () {
    final gate = _gate();
    var peakActive = 0;
    var accepted = 0;
    var rejected = 0;

    for (var i = 0; i < 100; i++) {
      final decision = gate.acquire('noisy');
      if (decision == AdmissionDecision.accepted) {
        accepted++;
        peakActive = gate.activeCount > peakActive
            ? gate.activeCount
            : peakActive;
      } else {
        expect(decision, AdmissionDecision.perClientLimit);
        rejected++;
      }
    }

    expect(accepted, 2);
    expect(rejected, 98);
    expect(peakActive, 2);
    expect(peakActive, lessThanOrEqualTo(4));
    for (var i = 0; i < accepted; i++) {
      gate.release('noisy');
    }
    expect(gate.activeCount, 0);
  });

  test('one client cannot consume another client capacity', () {
    final gate = _gate();

    expect(gate.acquire('a'), AdmissionDecision.accepted);
    expect(gate.acquire('a'), AdmissionDecision.accepted);
    expect(gate.acquire('a'), AdmissionDecision.perClientLimit);
    expect(gate.acquire('b'), AdmissionDecision.accepted);
    expect(gate.activeCount, 3);

    gate.release('a');
    gate.release('a');
    gate.release('b');
    expect(gate.activeCount, 0);
  });

  test('client tracking stays bounded and expires exactly at the window', () {
    var now = 0;
    final gate = _gate(nowMs: () => now);

    for (var i = 0; i < 100; i++) {
      final key = 'client-$i';
      final decision = gate.acquire(key);
      expect(gate.trackedClientCount, lessThanOrEqualTo(8));
      if (decision == AdmissionDecision.accepted) gate.release(key);
    }
    expect(gate.trackedClientCount, 8);

    now = 1000;
    expect(gate.acquire('fresh'), AdmissionDecision.accepted);
    expect(gate.trackedClientCount, 1);
    gate.release('fresh');
    expect(gate.activeCount, 0);
  });

  test('accepted-request budget resets without wall-clock delay', () {
    var now = 0;
    final gate = _gate(nowMs: () => now);

    for (var i = 0; i < 4; i++) {
      expect(gate.acquire('a'), AdmissionDecision.accepted);
      gate.release('a');
    }
    expect(gate.acquire('a'), AdmissionDecision.perClientLimit);

    now = 1000;
    expect(gate.acquire('a'), AdmissionDecision.accepted);
    gate.release('a');
    expect(gate.activeCount, 0);
  });

  test('WebSocket connection and handshake limits are exact', () async {
    var now = 0;
    final gate = _gate(
      globalConcurrent: 3,
      perClientConcurrent: 2,
      globalRate: 20,
      perClientRate: 10,
      nowMs: () => now,
    );
    final connected = StreamController<WebSocketChannel>.broadcast();
    final admitted = admittedWebSocketHandler((channel, _) {
      channel.stream.listen((_) {});
      connected.add(channel);
    }, gate: gate);
    FutureOr<Response> handler(Request request) {
      final client = request.requestedUri.queryParameters['client'] ?? 'a';
      return admitted(
        request.change(
          context: {
            'shelf.io.connection_info': _ConnectionInfo('10.0.0.$client'),
          },
        ),
      );
    }

    final server = await shelf_io.serve(handler, 'localhost', 0);
    addTearDown(() async {
      await connected.close();
      await server.close(force: true);
    });
    final base = 'ws://localhost:${server.port}';

    Future<(WebSocket, WebSocketChannel)> open(String client) async {
      final serverSide = connected.stream.first;
      final socket = await WebSocket.connect('$base?client=$client');
      return (socket, await serverSide);
    }

    Future<void> close((WebSocket, WebSocketChannel) pair) async {
      await pair.$1.close();
      await pair.$2.sink.done;
    }

    final a1 = await open('1');
    final a2 = await open('1');
    await _expectWebSocketRejection('$base?client=1', 429);
    final b1 = await open('2');
    await _expectWebSocketRejection('$base?client=2', 503);
    expect(gate.activeCount, 3);

    await close(a1);
    final b2 = await open('2');
    await close(a2);
    await close(b1);
    await close(b2);
    expect(gate.activeCount, 0);

    final rateGate = _gate(
      globalConcurrent: 3,
      perClientConcurrent: 3,
      globalRate: 3,
      perClientRate: 2,
      nowMs: () => now,
    );
    final rateConnected = StreamController<WebSocketChannel>.broadcast();
    final rateHandler = admittedWebSocketHandler((channel, _) {
      channel.stream.listen((_) {});
      rateConnected.add(channel);
    }, gate: rateGate);
    final rateServer = await shelf_io.serve(rateHandler, 'localhost', 0);
    addTearDown(() async {
      await rateConnected.close();
      await rateServer.close(force: true);
    });
    final rateBase = 'ws://localhost:${rateServer.port}';

    Future<(WebSocket, WebSocketChannel)> openRate() async {
      final serverSide = rateConnected.stream.first;
      final socket = await WebSocket.connect(rateBase);
      return (socket, await serverSide);
    }

    final rate1 = await openRate();
    await close(rate1);
    final rate2 = await openRate();
    await close(rate2);
    await _expectWebSocketRejection(rateBase, 429);
    now = 1000;
    final reset = await openRate();
    await close(reset);
    expect(rateGate.activeCount, 0);
  });
}

AdmissionGate _gate({
  int globalConcurrent = 4,
  int perClientConcurrent = 2,
  int globalRate = 8,
  int perClientRate = 4,
  int maxTrackedClients = 8,
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

Future<void> _expectWebSocketRejection(String uri, int status) {
  return expectLater(
    WebSocket.connect(uri),
    throwsA(
      isA<WebSocketException>().having(
        (error) => error.toString(),
        'status',
        contains('$status'),
      ),
    ),
  );
}
