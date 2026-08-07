import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver/wifi_scale_handler.dart';
import 'package:reaprime/src/services/wifi/wifi_scale_discovery_service.dart';
import 'package:rxdart/subjects.dart';
import 'package:shelf_plus/shelf_plus.dart';

class _FakeBrowser implements WifiScaleBrowser {
  final _subject = BehaviorSubject<List<WifiScaleEndpoint>>.seeded(const []);
  @override
  Stream<List<WifiScaleEndpoint>> get endpoints => _subject.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

class _MemStore implements WifiManualEndpointStore {
  List<String> _hosts = [];
  @override
  Future<List<String>> load() async => List.of(_hosts);
  @override
  Future<void> save(List<String> hosts) async => _hosts = List.of(hosts);
}

void main() {
  late WifiScaleDiscoveryService service;
  late Handler handler;

  Future<Response> get(String path) async =>
      await handler(Request('GET', Uri.parse('http://localhost$path')));
  Future<Response> post(String path, Object body) async => await handler(
    Request('POST', Uri.parse('http://localhost$path'), body: jsonEncode(body)),
  );
  Future<Response> del(String path, [Object? body]) async => await handler(
    Request(
      'DELETE',
      Uri.parse('http://localhost$path'),
      body: body == null ? null : jsonEncode(body),
    ),
  );
  Future<List<dynamic>> endpoints(Response r) async =>
      (jsonDecode(await r.readAsString()) as Map)['endpoints'] as List;

  setUp(() async {
    service = WifiScaleDiscoveryService(
      browser: _FakeBrowser(),
      manualStore: _MemStore(),
    );
    await service.initialize();
    final app = Router().plus;
    WifiScaleHandler(service: service).addRoutes(app);
    handler = app.call;
  });

  test('GET lists manual endpoints (empty initially)', () async {
    final r = await get('/api/v1/devices/wifi');
    expect(r.statusCode, 200);
    expect(await endpoints(r), isEmpty);
  });

  test('POST adds an endpoint and returns the updated list', () async {
    final r = await post('/api/v1/devices/wifi', {'host': '192.168.1.42'});
    expect(r.statusCode, 200);
    expect(await endpoints(r), ['192.168.1.42']);
    expect(service.manualEndpoints, ['192.168.1.42']);

    final list = await get('/api/v1/devices/wifi');
    expect(await endpoints(list), ['192.168.1.42']);
  });

  test('POST is idempotent', () async {
    await post('/api/v1/devices/wifi', {'host': 'hds.local'});
    final r = await post('/api/v1/devices/wifi', {'host': 'hds.local'});
    expect(await endpoints(r), ['hds.local']);
  });

  test('POST without a host is a 400', () async {
    final r = await post('/api/v1/devices/wifi', {'nope': 'x'});
    expect(r.statusCode, 400);
  });

  test('DELETE removes an endpoint (body)', () async {
    await post('/api/v1/devices/wifi', {'host': '10.0.0.5'});
    final r = await del('/api/v1/devices/wifi', {'host': '10.0.0.5'});
    expect(r.statusCode, 200);
    expect(await endpoints(r), isEmpty);
    expect(service.manualEndpoints, isEmpty);
  });

  test('DELETE removes an endpoint (query param fallback)', () async {
    await post('/api/v1/devices/wifi', {'host': '10.0.0.9'});
    final r = await del('/api/v1/devices/wifi?host=10.0.0.9');
    expect(r.statusCode, 200);
    expect(await endpoints(r), isEmpty);
  });

  tearDown(() async => service.dispose());
}
