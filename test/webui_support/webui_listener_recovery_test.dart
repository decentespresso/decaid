import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/listener_recovery_coordinator.dart';
import 'package:reaprime/src/services/webserver/api_listener.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:shelf/shelf.dart';

Future<({int statusCode, String body, String? location})> _request(
  Uri uri,
) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 1));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 1));
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 1));
    return (
      statusCode: response.statusCode,
      body: body,
      location: response.headers.value(HttpHeaders.locationHeader),
    );
  } finally {
    client.close(force: true);
  }
}

Future<bool> _responds(Uri uri) async {
  try {
    await _request(uri);
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  const entryPort = 3021;
  const skinPort = 26900;
  late Directory skin;
  late WebUIService webUI;
  late ApiListener api;
  late ListenerRecoveryCoordinator coordinator;

  Uri skinUri() => Uri.parse('http://127.0.0.1:${webUI.port}/');
  String skinBody() =>
      '<script src="http://127.0.0.1:${webUI.port}/__decent/skin-api.js"></script>skin';
  Uri entryUri() => Uri.parse('http://127.0.0.1:$entryPort/');
  Uri apiUri() => Uri.parse('http://127.0.0.1:${api.port}/api/v1/info');

  setUp(() async {
    WebUIService.resolveWifiIP = () async => 'localhost';
    WebUIService.aliasBindBarrier = null;
    WebUIService.skinPortRangeStart = skinPort;
    WebUIService.skinPortRangeSize = 1;
    skin = await Directory.systemTemp.createTemp('listener_recovery');
    await File('${skin.path}/index.html').writeAsString('skin');
    webUI = WebUIService(listLocalAddresses: () async => const []);
    await webUI.serveFolderAtPath(skin.path, port: entryPort);
    api = ApiListener(
      handler: (request) =>
          Response.ok('{}', headers: {'content-type': 'application/json'}),
      port: 0,
    );
    await api.start();
    coordinator = ListenerRecoveryCoordinator(
      apiListener: api,
      webUIService: webUI,
      retryDelay: Duration.zero,
    );
  });

  tearDown(() async {
    coordinator.dispose();
    await api.stop();
    await webUI.stopServing();
    if (skin.existsSync()) await skin.delete(recursive: true);
    WebUIService.aliasBindBarrier = null;
    WebUIService.skinPortRangeStart = 24800;
    WebUIService.skinPortRangeSize = 4096;
  });

  test('healthy resume does not restart listeners', () async {
    final apiStarts = api.startCount;
    final entryStarts = webUI.entryStartCount;
    final generation = webUI.serveGeneration.value;

    await coordinator.onResumed();

    expect(api.startCount, apiStarts);
    expect(webUI.entryStartCount, entryStarts);
    expect(webUI.serveGeneration.value, generation);
    expect((await _request(apiUri())).statusCode, HttpStatus.ok);
    expect((await _request(skinUri())).body, skinBody());
    expect(
      (await _request(entryUri())).statusCode,
      HttpStatus.temporaryRedirect,
    );
  });

  test(
    'disposal during a pending health check has no late side effects',
    () async {
      final healthStarted = Completer<void>();
      final releaseHealth = Completer<void>();
      var healthRequests = 0;
      final gatedApi = ApiListener(
        handler: (request) async {
          if (request.url.path == 'api/v1/info') {
            healthRequests++;
            if (!healthStarted.isCompleted) healthStarted.complete();
            await releaseHealth.future;
          }
          return Response.ok(
            '{}',
            headers: {'content-type': 'application/json'},
          );
        },
        port: 0,
      );
      final gatedCoordinator = ListenerRecoveryCoordinator(
        apiListener: gatedApi,
        webUIService: webUI,
        retryDelay: Duration.zero,
      );
      addTearDown(() async {
        gatedCoordinator.dispose();
        await gatedApi.stop();
      });

      await gatedApi.start();
      final starts = gatedApi.startCount;
      final generation = webUI.serveGeneration.value;
      final pendingRecovery = gatedCoordinator.onResumed();
      await healthStarted.future.timeout(const Duration(seconds: 1));

      gatedCoordinator.dispose();
      releaseHealth.complete();
      expect(await pendingRecovery, isFalse);

      expect(healthRequests, 1);
      expect(gatedApi.startCount, starts);
      expect(gatedApi.isStarted, isTrue);
      expect(webUI.serveGeneration.value, generation);
    },
  );

  test(
    'coordinator disposal inside alias bind closes owned recovery sockets',
    () async {
      final other = await Directory.systemTemp.createTemp('recovery_alias');
      await File('${other.path}/index.html').writeAsString('other');
      WebUIService.skinPortRangeStart = 26920;
      WebUIService.skinPortRangeSize = 3;
      final service = WebUIService(listLocalAddresses: () async => const [])
        ..skinIdentityProvider = (path) => path;
      final owner = ListenerRecoveryCoordinator(
        apiListener: api,
        webUIService: service,
      );
      addTearDown(() async {
        owner.dispose();
        await service.stopServing();
        await other.delete(recursive: true);
      });
      await service.serveFolderAtPath(skin.path, port: 3023);
      await service.serveFolderAtPath(other.path, port: 3023);
      final aliasPort = service.port;
      await service.serveFolderAtPath(skin.path, port: 3023);
      final activePort = service.port;
      final generation = service.serveGeneration.value;
      await service.closeListenersForTesting();
      final entered = Completer<void>();
      final release = Completer<void>();
      WebUIService.aliasBindBarrier = () async {
        entered.complete();
        await release.future;
      };
      final pending = owner.onResumed();
      await entered.future.timeout(const Duration(seconds: 2));
      owner.dispose();
      release.complete();
      await pending;
      expect(service.serveGeneration.value, generation);
      expect(api.isStarted, isTrue);
      for (final port in [aliasPort, activePort, 3023]) {
        final socket = await ServerSocket.bind('0.0.0.0', port);
        await socket.close();
      }
    },
  );

  test(
    'individual skin loss recovers without restarting API or entry',
    () async {
      final apiStarts = api.startCount;
      final entryStarts = webUI.entryStartCount;
      final port = webUI.port;
      final generation = webUI.serveGeneration.value;
      await webUI.closeSkinListenerForTesting();

      expect(webUI.isServing, isTrue);
      expect(await webUI.checkHealth(), isFalse);
      expect(await _responds(skinUri()), isFalse);
      expect(
        (await _request(entryUri())).statusCode,
        HttpStatus.temporaryRedirect,
      );

      await coordinator.onResumed();

      expect(api.startCount, apiStarts);
      expect(webUI.entryStartCount, entryStarts);
      expect(webUI.port, port);
      expect(webUI.serveGeneration.value, generation + 1);
      expect(await webUI.checkHealth(), isTrue);
      expect((await _request(skinUri())).body, skinBody());
      expect(
        (await _request(entryUri())).statusCode,
        HttpStatus.temporaryRedirect,
      );
    },
  );

  test('individual entry loss recovers without restarting skin', () async {
    final apiStarts = api.startCount;
    final entryStarts = webUI.entryStartCount;
    final generation = webUI.serveGeneration.value;
    final port = webUI.port;
    await webUI.closeEntryListenerForTesting();

    expect(webUI.isServing, isTrue);
    expect(await webUI.checkHealth(), isFalse);
    expect((await _request(skinUri())).body, skinBody());
    expect(await _responds(entryUri()), isFalse);

    await coordinator.onResumed();

    expect(api.startCount, apiStarts);
    expect(webUI.entryStartCount, entryStarts + 1);
    expect(webUI.port, port);
    expect(webUI.serveGeneration.value, generation);
    expect(await webUI.checkHealth(), isTrue);
    expect((await _request(skinUri())).body, skinBody());
    expect(
      (await _request(entryUri())).statusCode,
      HttpStatus.temporaryRedirect,
    );
  });

  test('in-flight recovery cannot overwrite a newer skin selection', () async {
    WebUIService.skinPortRangeStart = 26910;
    WebUIService.skinPortRangeSize = 3;
    final firstSkin = await Directory.systemTemp.createTemp('listener_race_a');
    final secondSkin = await Directory.systemTemp.createTemp('listener_race_b');
    final selectedSkin = await Directory.systemTemp.createTemp(
      'listener_race_c',
    );
    await File('${firstSkin.path}/index.html').writeAsString('A');
    await File('${secondSkin.path}/index.html').writeAsString('B');
    await File('${selectedSkin.path}/index.html').writeAsString('C');
    final raceService = WebUIService(listLocalAddresses: () async => const [])
      ..skinIdentityProvider = (path) => path;
    addTearDown(() async {
      WebUIService.aliasBindBarrier = null;
      await raceService.stopServing();
      for (final directory in [firstSkin, secondSkin, selectedSkin]) {
        if (directory.existsSync()) await directory.delete(recursive: true);
      }
    });

    await raceService.serveFolderAtPath(firstSkin.path, port: 3022);
    await raceService.serveFolderAtPath(secondSkin.path, port: 3022);
    final secondPort = raceService.port;
    await raceService.serveFolderAtPath(selectedSkin.path, port: 3022);
    final selectedPort = raceService.port;
    await raceService.serveFolderAtPath(firstSkin.path, port: 3022);
    final generation = raceService.serveGeneration.value;
    final firstPort = raceService.port;
    expect(firstPort, isNot(selectedPort));
    await raceService.closeListenersForTesting();

    final barrierEntered = Completer<void>();
    final releaseBarrier = Completer<void>();
    WebUIService.aliasBindBarrier = () async {
      if (!barrierEntered.isCompleted) barrierEntered.complete();
      await releaseBarrier.future;
    };
    final pendingRecovery = raceService.recover();
    await barrierEntered.future.timeout(const Duration(seconds: 1));

    await raceService.stopServing();
    final pendingSelection = raceService.serveFolderAtPath(
      selectedSkin.path,
      port: 3022,
    );
    releaseBarrier.complete();
    await Future.wait([pendingRecovery, pendingSelection]);

    expect(raceService.serverPath(), selectedSkin.path);
    expect(raceService.port, selectedPort);
    expect(raceService.serveGeneration.value, generation + 1);
    expect(
      (await _request(Uri.parse('http://127.0.0.1:$selectedPort/'))).body,
      '<script src="http://127.0.0.1:$selectedPort/__decent/skin-api.js"></script>C',
    );
    expect(
      (await _request(Uri.parse('http://127.0.0.1:3022/'))).location,
      'http://127.0.0.1:$selectedPort/',
    );

    expect(
      (await _request(Uri.parse('http://127.0.0.1:$secondPort/'))).location,
      'http://127.0.0.1:3022/',
    );
    await raceService.stopServing();
    final releasedAlias = await ServerSocket.bind('0.0.0.0', secondPort);
    await releasedAlias.close();
  });

  test('combined listener loss recovers API and skin once', () async {
    final apiStarts = api.startCount;
    final entryStarts = webUI.entryStartCount;
    final apiPort = api.port;
    final skinPort = webUI.port;
    await api.closeForTesting();
    await webUI.closeListenersForTesting();
    final generation = webUI.serveGeneration.value;

    expect(api.isStarted, isTrue);
    expect(webUI.isServing, isTrue);
    expect(await api.checkHealth(), isFalse);
    expect(await webUI.checkHealth(), isFalse);
    expect(await _responds(apiUri()), isFalse);
    expect(await _responds(skinUri()), isFalse);
    expect(await _responds(entryUri()), isFalse);

    await Future.wait([coordinator.onResumed(), coordinator.onResumed()]);

    expect(api.startCount, apiStarts + 1);
    expect(webUI.entryStartCount, entryStarts + 1);
    expect(api.port, apiPort);
    expect(webUI.port, skinPort);
    expect(webUI.serveGeneration.value, generation + 1);
    expect(await api.checkHealth(), isTrue);
    expect(await webUI.checkHealth(), isTrue);
    expect((await _request(apiUri())).statusCode, HttpStatus.ok);
    expect((await _request(skinUri())).body, skinBody());
    expect(
      (await _request(entryUri())).statusCode,
      HttpStatus.temporaryRedirect,
    );
  });

  test(
    'retry publishes a replacement skin generation after entry bind failure',
    () async {
      final oldPort = webUI.port;
      final generation = webUI.serveGeneration.value;
      final entryStarts = webUI.entryStartCount;
      await webUI.closeListenersForTesting();
      expect(webUI.isServing, isTrue);
      final skinSquatter = await ServerSocket.bind('0.0.0.0', oldPort);
      addTearDown(skinSquatter.close);
      final entrySquatter = await ServerSocket.bind('0.0.0.0', entryPort);
      var entrySquatterClosed = false;
      addTearDown(() async {
        if (!entrySquatterClosed) await entrySquatter.close();
      });

      await expectLater(
        coordinator.onResumed().timeout(const Duration(seconds: 15)),
        throwsA(isA<SocketException>()),
      );
      final replacementPort = webUI.port;
      expect(replacementPort, isNot(oldPort));
      expect(coordinator.failure.value, isNotNull);
      expect(webUI.serveGeneration.value, generation);
      expect(webUI.entryStartCount, entryStarts);
      expect((await _request(skinUri())).body, skinBody());

      await entrySquatter.close();
      entrySquatterClosed = true;
      await coordinator.retry().timeout(const Duration(seconds: 15));

      expect(coordinator.failure.value, isNull);
      expect(await api.checkHealth(), isTrue);
      expect(await webUI.checkHealth(), isTrue);
      expect(webUI.port, replacementPort);
      expect(webUI.entryStartCount, entryStarts + 1);
      final redirect = await _request(entryUri());
      expect(redirect.statusCode, HttpStatus.temporaryRedirect);
      expect(redirect.location, 'http://127.0.0.1:$replacementPort/');
      expect(webUI.serveGeneration.value, generation + 1);

      await coordinator.onResumed().timeout(const Duration(seconds: 15));
      expect(webUI.serveGeneration.value, generation + 1);
      expect(webUI.entryStartCount, entryStarts + 1);
    },
  );

  test('cancelling a retry retires an unpublished replacement skin', () async {
    final oldPort = webUI.port;
    final generation = webUI.serveGeneration.value;
    await webUI.closeListenersForTesting();
    final skinSquatter = await ServerSocket.bind('0.0.0.0', oldPort);
    addTearDown(skinSquatter.close);
    final entrySquatter = await ServerSocket.bind('0.0.0.0', entryPort);
    var entrySquatterClosed = false;
    addTearDown(() async {
      if (!entrySquatterClosed) await entrySquatter.close();
    });
    await expectLater(
      coordinator.onResumed().timeout(const Duration(seconds: 15)),
      throwsA(isA<SocketException>()),
    );
    final unpublishedPort = webUI.port;
    expect(unpublishedPort, isNot(oldPort));
    expect(webUI.serveGeneration.value, generation);
    expect((await _request(skinUri())).body, skinBody());

    await webUI
        .recover(isCancelled: () => true)
        .timeout(const Duration(seconds: 15));

    expect(webUI.isServing, isFalse);
    expect(webUI.hasActiveSkin, isTrue);
    expect(webUI.serveGeneration.value, generation);
    final released = await ServerSocket.bind('0.0.0.0', unpublishedPort);
    await released.close();
    await entrySquatter.close();
    entrySquatterClosed = true;
    await coordinator.retry().timeout(const Duration(seconds: 15));
    expect(await webUI.checkHealth(), isTrue);
    expect(webUI.port, isNot(oldPort));
    expect(webUI.serveGeneration.value, generation + 1);
    await coordinator.onResumed().timeout(const Duration(seconds: 15));
    expect(webUI.serveGeneration.value, generation + 1);
  });

  test('intentional WebUI stop is not undone by resume', () async {
    await webUI.stopServing();

    await coordinator.onResumed();

    expect(webUI.hasActiveSkin, isFalse);
    expect(webUI.isServing, isFalse);
    expect(coordinator.failure.value, isNull);
  });

  test(
    'failed recovery is retryable without continuing automatic attempts',
    () async {
      await api.closeForTesting();
      final apiPort = api.port;
      final attempts = api.startAttemptCount;
      final squatter = await ServerSocket.bind('0.0.0.0', apiPort);
      var squatterClosed = false;
      addTearDown(() async {
        if (!squatterClosed) await squatter.close();
      });

      await expectLater(coordinator.onResumed(), throwsA(anything));
      expect(coordinator.failure.value, isNotNull);
      expect(api.startAttemptCount, attempts + coordinator.maxAttempts);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(api.startAttemptCount, attempts + coordinator.maxAttempts);

      await squatter.close();
      squatterClosed = true;
      await coordinator.retry();

      expect(coordinator.failure.value, isNull);
      expect(api.port, apiPort);
      expect(await api.checkHealth(), isTrue);
      expect((await _request(apiUri())).statusCode, HttpStatus.ok);
    },
  );
}
