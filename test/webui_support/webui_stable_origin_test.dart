import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_info_plus/network_info_plus.dart';
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
    await File(
      '${dir.path}/index.html',
    ).writeAsString('<html><body>$body</body></html>');
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
    await expectLater(
      client.getUrl(Uri.parse('http://localhost:$portA/')),
      throwsA(isA<SocketException>()),
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
