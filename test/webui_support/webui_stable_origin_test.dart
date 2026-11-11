import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';

void main() {
  const entryPort = 3011;
  const testRangeStart = 26700;
  const testRangeSize = 32;

  late Directory skinA;
  late Directory skinB;
  final services = <WebUIService>[];

  Future<Directory> createSkin(String prefix, String body) async {
    final dir = await Directory.systemTemp.createTemp(prefix);
    await File('${dir.path}/index.html')
        .writeAsString('<html><body>$body</body></html>');
    return dir;
  }

  WebUIService createService({
    Future<Map<String, int>> Function()? load,
    Future<void> Function(Map<String, int>)? save,
  }) {
    final service = WebUIService(
      listLocalAddresses: () async => const <String>[],
      loadSkinPortAssignments: load,
      saveSkinPortAssignments: save,
    );
    services.add(service);
    return service;
  }

  Future<String> fetchBody(int port) async {
    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.getUrl(Uri.parse('http://localhost:$port/'));
    final response = await request.close();
    return response.transform(utf8.decoder).join();
  }

  setUp(() async {
    WebUIService.resolveWifiIP = () async => 'localhost';
    WebUIService.skinPortRangeStart = testRangeStart;
    WebUIService.skinPortRangeSize = testRangeSize;
    skinA = await createSkin('webui_stable_a', 'skin-a');
    skinB = await createSkin('webui_stable_b', 'skin-b');
  });

  tearDown(() async {
    for (final service in services) {
      await service.stopServing();
    }
    services.clear();
    for (final dir in [skinA, skinB]) {
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
    WebUIService.resolveWifiIP = NetworkInfo().getWifiIP;
    WebUIService.skinPortRangeStart = 24800;
    WebUIService.skinPortRangeSize = 4096;
    WebUIService.aliasBindBarrier = null;
  });

  test('serves a skin on the same origin across restarts', () async {
    var saved = <String, int>{};
    final service = createService(
      load: () async => saved,
      save: (assignments) async => saved = assignments,
    );

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final assignedPort = service.port;

    expect(assignedPort, greaterThanOrEqualTo(testRangeStart));
    expect(assignedPort, lessThan(testRangeStart + testRangeSize));
    expect(saved, {skinA.path: assignedPort});

    await service.stopServing();
    await service.serveFolderAtPath(skinA.path, port: entryPort);

    expect(service.port, assignedPort);

    await service.stopServing();

    var relaunchSaves = 0;
    final relaunched = createService(
      load: () async => Map<String, int>.from(saved),
      save: (_) async => relaunchSaves++,
    );
    await relaunched.serveFolderAtPath(skinA.path, port: entryPort);

    expect(relaunched.port, assignedPort);
    expect(relaunchSaves, 0);
    expect(await fetchBody(relaunched.port), contains('skin-a'));
  });

  test('gives a different skin a different origin', () async {
    final service = createService();

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final portA = service.port;
    await service.serveFolderAtPath(skinB.path, port: entryPort);
    final portB = service.port;

    expect(portB, isNot(portA));
    expect(await fetchBody(portB), contains('skin-b'));

    final client = HttpClient();
    addTearDown(client.close);
    final aliasRequest = await client.getUrl(
      Uri.parse('http://localhost:$portA/'),
    );
    aliasRequest.followRedirects = false;
    final aliasResponse = await aliasRequest.close();
    await aliasResponse.drain<void>();
    expect(aliasResponse.statusCode, HttpStatus.temporaryRedirect);
    expect(
      aliasResponse.headers.value(HttpHeaders.locationHeader),
      'http://localhost:$entryPort/',
    );

    final entryRequest = await client.getUrl(
      Uri.parse('http://localhost:$entryPort/'),
    );
    entryRequest.followRedirects = false;
    final entryResponse = await entryRequest.close();
    await entryResponse.drain<void>();

    expect(entryResponse.statusCode, HttpStatus.temporaryRedirect);
    expect(
      entryResponse.headers.value(HttpHeaders.locationHeader),
      'http://localhost:$portB/',
    );
    expect(
      entryResponse.headers.value(HttpHeaders.cacheControlHeader),
      'no-store',
    );
  });

  test('keeps one origin for one identity served from two paths', () async {
    final service = createService();
    service.skinIdentityProvider = (_) => 'skin:reinstalled';

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final portA = service.port;
    await service.serveFolderAtPath(skinB.path, port: entryPort);

    expect(service.port, portA);
    expect(await fetchBody(service.port), contains('skin-b'));
  });

  test('never adopts a port already assigned to another skin', () async {
    final first = createService();
    await first.serveFolderAtPath(skinA.path, port: entryPort);
    final seededPort = first.port;
    await first.stopServing();

    var saved = <String, int>{};
    final service = createService(
      load: () async => {'skin:other': seededPort},
      save: (assignments) async => saved = assignments,
    );
    await service.serveFolderAtPath(skinA.path, port: entryPort);

    expect(service.port, isNot(seededPort));
    expect(saved['skin:other'], seededPort);
    expect(saved[skinA.path], service.port);
  });

  test('falls back to an ephemeral port when its own port is taken', () async {
    var saved = <String, int>{};
    var saves = 0;
    final service = createService(
      load: () async => Map<String, int>.from(saved),
      save: (assignments) async {
        saved = assignments;
        saves++;
      },
    );

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final assignedPort = service.port;
    await service.stopServing();

    final squatter = await ServerSocket.bind('0.0.0.0', assignedPort);

    await service.serveFolderAtPath(skinA.path, port: entryPort);

    expect(service.port, isNot(assignedPort));
    expect(saved, {skinA.path: assignedPort});
    expect(saves, 1);
    expect(await fetchBody(service.port), contains('skin-a'));

    await service.stopServing();
    await squatter.close();

    await service.serveFolderAtPath(skinA.path, port: entryPort);

    expect(service.port, assignedPort);
    expect(saves, 1);
  });

  test('serves and reassigns when the loader throws', () async {
    var saved = <String, int>{};
    final service = createService(
      load: () async => throw const FormatException('corrupt prefs'),
      save: (assignments) async => saved = assignments,
    );

    await service.serveFolderAtPath(skinA.path, port: entryPort);

    expect(service.port, greaterThanOrEqualTo(testRangeStart));
    expect(service.port, lessThan(testRangeStart + testRangeSize));
    expect(saved, {skinA.path: service.port});
    expect(await fetchBody(service.port), contains('skin-a'));
  });

  test('never adopts a stored port outside the skin range', () async {
    var saved = <String, int>{};
    final service = createService(
      load: () async => {skinA.path: 8080, 'skin:other': 65000},
      save: (assignments) async => saved = assignments,
    );

    await service.serveFolderAtPath(skinA.path, port: entryPort);

    expect(service.port, greaterThanOrEqualTo(testRangeStart));
    expect(service.port, lessThan(testRangeStart + testRangeSize));
    expect(saved, {skinA.path: service.port});
  });

  test('drops stored assignments that share one port', () async {
    final duplicatedPort = testRangeStart + 5;
    var saved = <String, int>{};
    final service = createService(
      load: () async => {'skin:x': duplicatedPort, 'skin:y': duplicatedPort},
      save: (assignments) async => saved = assignments,
    );

    await service.serveFolderAtPath(skinA.path, port: entryPort);

    expect(saved.keys, [skinA.path]);
  });

  test('serves a skin without an identity on a temporary port', () async {
    var saves = 0;
    final service = createService(
      load: () async => {},
      save: (_) async {
        saves++;
      },
    );
    service.skinIdentityProvider = (_) => null;

    await service.serveFolderAtPath(skinA.path, port: entryPort);

    expect(
      service.port,
      isNot(inInclusiveRange(testRangeStart, testRangeStart + testRangeSize)),
    );
    expect(saves, 0);
    expect(await fetchBody(service.port), contains('skin-a'));
  });

  test('keeps an inactive skin port as a redirect alias', () async {
    final service = createService();

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final portA = service.port;
    await service.serveFolderAtPath(skinB.path, port: entryPort);
    final portB = service.port;

    final client = HttpClient();
    addTearDown(client.close);
    final aliasRequest = await client.getUrl(
      Uri.parse('http://localhost:$portA/'),
    );
    aliasRequest.followRedirects = false;
    final aliasResponse = await aliasRequest.close();
    await aliasResponse.drain<void>();

    expect(aliasResponse.statusCode, HttpStatus.temporaryRedirect);
    expect(
      aliasResponse.headers.value(HttpHeaders.locationHeader),
      'http://localhost:$entryPort/',
    );

    final entryRequest = await client.getUrl(
      Uri.parse('http://localhost:$entryPort/'),
    );
    entryRequest.followRedirects = false;
    final entryResponse = await entryRequest.close();
    await entryResponse.drain<void>();
    expect(entryResponse.statusCode, HttpStatus.temporaryRedirect);
    expect(
      entryResponse.headers.value(HttpHeaders.locationHeader),
      'http://localhost:$portB/',
    );
  });

  test('alias redirect preserves host, path and query', () async {
    final service = createService();

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final aliasPort = service.port;
    await service.serveFolderAtPath(skinB.path, port: entryPort);

    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$aliasPort/some/path?x=1&y=2'),
    );
    request.followRedirects = false;
    final response = await request.close();
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.temporaryRedirect);
    expect(response.headers.value(HttpHeaders.cacheControlHeader), 'no-store');
    expect(
      response.headers.value(HttpHeaders.locationHeader),
      'http://127.0.0.1:$entryPort/some/path?x=1&y=2',
    );
  });

  test('reclaims its assigned port when switching back', () async {
    var saved = <String, int>{};
    final service = createService(
      load: () async => saved,
      save: (assignments) async => saved = Map<String, int>.from(assignments),
    );

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final portA = service.port;
    await service.serveFolderAtPath(skinB.path, port: entryPort);
    final portB = service.port;
    await service.serveFolderAtPath(skinA.path, port: entryPort);

    expect(service.port, portA);
    expect(saved, {skinA.path: portA, skinB.path: portB});

    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.getUrl(Uri.parse('http://localhost:$portB/'));
    request.followRedirects = false;
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, HttpStatus.temporaryRedirect);
    expect(
      response.headers.value(HttpHeaders.locationHeader),
      'http://localhost:$entryPort/',
    );
  });

  test('aliases persisted inactive ports on a fresh start', () async {
    final portA = testRangeStart + 1;
    final portB = testRangeStart + 2;
    final service = createService(
      load: () async => {skinA.path: portA, skinB.path: portB},
    );

    await service.serveFolderAtPath(skinB.path, port: entryPort);

    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.getUrl(Uri.parse('http://localhost:$portA/'));
    request.followRedirects = false;
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, HttpStatus.temporaryRedirect);
    expect(
      response.headers.value(HttpHeaders.locationHeader),
      'http://localhost:$entryPort/',
    );
  });

  test('serves only a redirect on an inactive alias port', () async {
    var tokenRequests = 0;
    final service = createService();
    service.skinProxyTokenProvider = (_) => 'alias-sentinel-${++tokenRequests}';

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final aliasPort = service.port;
    await service.serveFolderAtPath(skinB.path, port: entryPort);

    expect(await fetchBody(service.port), contains('alias-sentinel-2'));
    expect(tokenRequests, 2);

    final client = HttpClient();
    addTearDown(client.close);
    final rootRequest = await client.getUrl(
      Uri.parse('http://localhost:$aliasPort/'),
    );
    rootRequest.followRedirects = false;
    final rootResponse = await rootRequest.close();
    final rootBody = await rootResponse.transform(utf8.decoder).join();
    expect(rootResponse.statusCode, HttpStatus.temporaryRedirect);
    expect(rootBody, isEmpty);
    expect(rootBody, isNot(contains('skin-a')));
    expect(rootBody, isNot(contains('skin-b')));
    expect(rootBody, isNot(contains(skinApiScriptPath)));
    expect(rootBody, isNot(contains('reaprime-proxy-token')));
    expect(rootBody, isNot(contains('alias-sentinel')));

    final apiRequest = await client.getUrl(
      Uri.parse('http://localhost:$aliasPort$skinApiScriptPath'),
    );
    apiRequest.followRedirects = false;
    final apiResponse = await apiRequest.close();
    await apiResponse.drain<void>();
    expect(apiResponse.statusCode, HttpStatus.temporaryRedirect);

    expect(tokenRequests, 2);
    expect(service.skinProxyToken, 'alias-sentinel-2');
  });

  test('ignores an inactive alias port owned by another process', () async {
    final portA = testRangeStart + 1;
    final portB = testRangeStart + 2;
    final squatter = await ServerSocket.bind('0.0.0.0', portA);
    addTearDown(squatter.close);
    var saved = <String, int>{skinA.path: portA, skinB.path: portB};
    final service = createService(
      load: () async => Map<String, int>.from(saved),
      save: (assignments) async => saved = Map<String, int>.from(assignments),
    );

    await service.serveFolderAtPath(skinB.path, port: entryPort);

    expect(saved, {skinA.path: portA, skinB.path: portB});
    expect(await fetchBody(portB), contains('skin-b'));
    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.getUrl(
      Uri.parse('http://localhost:$entryPort/'),
    );
    request.followRedirects = false;
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, HttpStatus.temporaryRedirect);
    expect(
      response.headers.value(HttpHeaders.locationHeader),
      'http://localhost:${service.port}/',
    );
  });

  test('never aliases a temporary fallback port', () async {
    var saved = <String, int>{};
    final service = createService(
      load: () async => Map<String, int>.from(saved),
      save: (assignments) async => saved = Map<String, int>.from(assignments),
    );

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final assignedPort = service.port;
    await service.stopServing();
    final squatter = await ServerSocket.bind('0.0.0.0', assignedPort);
    addTearDown(squatter.close);

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final fallbackPort = service.port;
    expect(fallbackPort, isNot(assignedPort));
    await service.serveFolderAtPath(skinB.path, port: entryPort);

    expect(saved, {skinA.path: assignedPort, skinB.path: service.port});
    final client = HttpClient();
    addTearDown(client.close);
    await expectLater(
      client.getUrl(Uri.parse('http://localhost:$fallbackPort/')),
      throwsA(isA<SocketException>()),
    );
  });

  test('stopServing releases active, entry and alias ports', () async {
    final service = createService();

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final portA = service.port;
    await service.serveFolderAtPath(skinB.path, port: entryPort);
    final portB = service.port;

    final aliasClient = HttpClient();
    addTearDown(aliasClient.close);
    final aliasRequest = await aliasClient.getUrl(
      Uri.parse('http://localhost:$portA/'),
    );
    aliasRequest.followRedirects = false;
    final aliasResponse = await aliasRequest.close();
    await aliasResponse.drain<void>();
    expect(aliasResponse.statusCode, HttpStatus.temporaryRedirect);
    aliasClient.close();

    await service.stopServing();

    final client = HttpClient();
    addTearDown(client.close);
    for (final port in [portA, portB, entryPort]) {
      await expectLater(
        client.getUrl(Uri.parse('http://localhost:$port/')),
        throwsA(isA<SocketException>()),
      );
    }
  });

  test(
    'releases every listener when a serve fails after an alias exists',
    () async {
      final service = createService();

      await service.serveFolderAtPath(skinA.path, port: entryPort);
      final portA = service.port;
      await service.serveFolderAtPath(skinB.path, port: entryPort);
      final portB = service.port;
      service.skinIdentityProvider = (_) => throw StateError('no identity');

      await expectLater(
        service.serveFolderAtPath(skinA.path, port: entryPort),
        throwsA(isA<StateError>()),
      );

      expect(service.isServing, isFalse);
      final client = HttpClient();
      addTearDown(client.close);
      for (final port in [portA, portB, entryPort]) {
        await expectLater(
          client.getUrl(Uri.parse('http://localhost:$port/')),
          throwsA(isA<SocketException>()),
        );
      }
    },
  );

  test('releases every listener when the skin directory is invalid', () async {
    final service = createService();

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final portA = service.port;
    await service.serveFolderAtPath(skinB.path, port: entryPort);
    final portB = service.port;

    await expectLater(
      service.serveFolderAtPath('${skinA.path}/missing', port: entryPort),
      throwsA(anything),
    );

    expect(service.isServing, isFalse);
    final client = HttpClient();
    addTearDown(client.close);
    for (final port in [portA, portB, entryPort]) {
      await expectLater(
        client.getUrl(Uri.parse('http://localhost:$port/')),
        throwsA(isA<SocketException>()),
      );
    }
  });

  test('rejects an untrusted host on an inactive alias port', () async {
    final service = createService();

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final aliasPort = service.port;
    await service.serveFolderAtPath(skinB.path, port: entryPort);

    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.getUrl(
      Uri.parse('http://localhost:$aliasPort/'),
    );
    request.followRedirects = false;
    request.headers.set(HttpHeaders.hostHeader, 'example.invalid:$aliasPort');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    expect(response.statusCode, HttpStatus.notFound);
    expect(response.headers.value(HttpHeaders.locationHeader), isNull);
    expect(body, isNot(contains('skin-')));
    expect(body, isNot(contains('reaprime-proxy-token')));
  });

  test('a stop during alias reconciliation leaves no alias bound', () async {
    final service = createService();

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final portA = service.port;

    final reached = Completer<void>();
    final release = Completer<void>();
    WebUIService.aliasBindBarrier = () {
      if (!reached.isCompleted) reached.complete();
      return release.future;
    };

    final serving = service.serveFolderAtPath(skinB.path, port: entryPort);
    await reached.future;
    await service.stopServing();
    release.complete();
    await serving;

    expect(service.isServing, isFalse);
    expect(service.serverPath(), isEmpty);
    expect(service.serveGeneration.value, 1);
    final client = HttpClient();
    addTearDown(client.close);
    for (final port in [portA, entryPort]) {
      await expectLater(
        client.getUrl(Uri.parse('http://localhost:$port/')),
        throwsA(isA<SocketException>()),
      );
    }
  });

  test('a superseded serve keeps the newer identity and token', () async {
    var wifiCalls = 0;
    final reached = Completer<void>();
    final release = Completer<void>();
    WebUIService.resolveWifiIP = () async {
      wifiCalls++;
      if (wifiCalls == 1) {
        reached.complete();
        await release.future;
      }
      return 'localhost';
    };
    final service = createService();
    service.skinProxyTokenProvider = (path) =>
        path == skinA.path ? 'token-a' : 'token-b';

    final servingA = service.serveFolderAtPath(skinA.path, port: entryPort);
    await reached.future;
    await service.serveFolderAtPath(skinB.path, port: entryPort);
    final portB = service.port;

    release.complete();
    await servingA;

    expect(portB, isNot(entryPort));
    expect(service.isServing, isTrue);
    expect(service.port, portB);
    expect(service.skinProxyToken, 'token-b');
    expect(service.serverPath(), skinB.path);
    expect(await fetchBody(portB), contains('skin-b'));
  });

  test('a superseded failure leaves the newer serve intact', () async {
    var wifiCalls = 0;
    final reached = Completer<void>();
    final release = Completer<void>();
    WebUIService.resolveWifiIP = () async {
      wifiCalls++;
      if (wifiCalls == 1) {
        reached.complete();
        await release.future;
      }
      return 'localhost';
    };
    final service = createService();
    service.skinProxyTokenProvider = (path) =>
        path == skinA.path ? 'token-a' : 'token-b';

    final stale = service.serveFolderAtPath(
      '${skinA.path}/missing',
      port: entryPort,
    );
    await reached.future;
    await service.serveFolderAtPath(skinB.path, port: entryPort);
    final portB = service.port;
    final generation = service.serveGeneration.value;

    release.complete();
    await expectLater(stale, throwsA(anything));

    expect(service.isServing, isTrue);
    expect(service.port, portB);
    expect(service.skinProxyToken, 'token-b');
    expect(service.serverPath(), skinB.path);
    expect(service.serveGeneration.value, generation);
    expect(await fetchBody(portB), contains('skin-b'));

    final client = HttpClient();
    addTearDown(client.close);
    final entry = await client.getUrl(
      Uri.parse('http://localhost:$entryPort/'),
    );
    entry.followRedirects = false;
    final entryResponse = await entry.close();
    await entryResponse.drain<void>();
    expect(
      entryResponse.headers.value(HttpHeaders.locationHeader),
      'http://localhost:$portB/',
    );
  });

  test(
    'does not allowlist an inactive alias origin for the account proxy',
    () async {
      final service = createService();

      await service.serveFolderAtPath(skinA.path, port: entryPort);
      final aliasPort = service.port;
      await service.serveFolderAtPath(skinB.path, port: entryPort);

      final origins = accountProxyCorsAllowedOrigins(service);
      expect(origins, contains('http://localhost:${service.port}'));
      expect(origins, isNot(contains('http://localhost:$aliasPort')));
    },
  );

  test('saves an assignment once, not on every serve', () async {
    var saves = 0;
    var saved = <String, int>{};
    final service = createService(
      load: () async => Map<String, int>.from(saved),
      save: (assignments) async {
        saved = assignments;
        saves++;
      },
    );

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    await service.serveFolderAtPath(skinA.path, port: entryPort);
    await service.stopServing();
    await service.serveFolderAtPath(skinA.path, port: entryPort);

    expect(saves, 1);
  });
}
