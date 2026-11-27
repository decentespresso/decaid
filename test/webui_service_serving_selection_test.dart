import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reaprime/src/webui_support/webui_service.dart';

void main() {
  const entryPort = 3017;
  const testRangeStart = 27100;
  const testRangeSize = 32;

  late Directory skinA;
  late Directory skinB;
  WebUIService? serving;

  Future<Directory> createSkin(String prefix) async {
    final dir = await Directory.systemTemp.createTemp(prefix);
    await File(p.join(dir.path, 'index.html'))
        .writeAsString('<html>$prefix</html>');
    return dir;
  }

  Future<String> fetchBody(int port) async {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/'))
          .timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 2));
    } finally {
      client.close(force: true);
    }
  }

  WebUIService createService({Future<Map<String, int>> Function()? load}) {
    final service = WebUIService(
      listLocalAddresses: () async => const <String>[],
      loadSkinPortAssignments: load,
    );
    serving = service;
    return service;
  }

  setUp(() async {
    WebUIService.resolveWifiIP = () async => 'localhost';
    WebUIService.skinPortRangeStart = testRangeStart;
    WebUIService.skinPortRangeSize = testRangeSize;
    WebUIService.aliasBindBarrier = null;
    skinA = await createSkin('serving_selection_a');
    skinB = await createSkin('serving_selection_b');
  });

  tearDown(() async {
    WebUIService.aliasBindBarrier = null;
    await serving?.stopServing();
    serving = null;
    for (final dir in [skinA, skinB]) {
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  });

  test('reports no served package before the owner starts serving', () async {
    final service = createService();

    final selection = service.observeServingSelection();

    expect(selection.isServing, isFalse);
    expect(selection.servedPath, isNull);
    expect(selection.declaredOverride.source, SkinSource.registry);
    expect(service.isServing, isFalse);
  });

  test('reports the package the owner is serving', () async {
    final service = createService();
    await service.serveFolderAtPath(skinA.path, port: entryPort);

    final selection = service.observeServingSelection();

    expect(selection.isServing, isTrue);
    expect(selection.servedPath, skinA.path);
    expect(service.serverPath(), skinA.path);
  });

  test('reports no served package after the owner stops serving', () async {
    final service = createService();
    await service.serveFolderAtPath(skinA.path, port: entryPort);

    await service.stopServing();

    final selection = service.observeServingSelection();

    expect(selection.isServing, isFalse);
    expect(selection.servedPath, isNull);
  });

  test(
    'reports the declared runtime override with the served package',
    () async {
      final service = createService();
      service.skinOverride = const SkinOverride.id('insight');

      final idle = service.observeServingSelection();
      expect(idle.isServing, isFalse);
      expect(idle.declaredOverride.source, SkinSource.id);
      expect(idle.declaredOverride.value, 'insight');

      await service.serveFolderAtPath(skinA.path, port: entryPort);

      final served = service.observeServingSelection();
      expect(served.declaredOverride.value, 'insight');
      expect(served.servedPath, skinA.path);
    },
  );

  test('reports the package actually served during a rebind', () async {
    final service = createService(
      load: () async => {'alias-skin': testRangeStart + 5},
    );
    await service.serveFolderAtPath(skinA.path, port: entryPort);
    expect(service.serverPath(), skinA.path);

    final reached = Completer<void>();
    final release = Completer<void>();
    WebUIService.aliasBindBarrier = () {
      if (!reached.isCompleted) reached.complete();
      return release.future;
    };

    final rebind = service.serveFolderAtPath(skinB.path, port: entryPort);
    try {
      await reached.future.timeout(const Duration(seconds: 5));
      expect(service.isServing, isTrue);
      expect(service.observeServingSelection().servedPath, skinB.path);
    } finally {
      if (!release.isCompleted) release.complete();
      await rebind.timeout(const Duration(seconds: 15));
    }
    expect(service.observeServingSelection().servedPath, skinB.path);
  });

  test('keeps the served package across a skin listener recovery', () async {
    final service = createService();
    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final generation = service.serveGeneration.value;
    final port = service.port;

    await service.closeSkinListenerForTesting();
    expect(service.isServing, isTrue);
    expect(await service.checkHealth(), isFalse);
    expect(service.observeServingSelection().servedPath, skinA.path);

    await service.recover().timeout(const Duration(seconds: 15));

    expect(await service.checkHealth(), isTrue);
    expect(service.port, port);
    expect(service.serveGeneration.value, generation + 1);
    expect(service.observeServingSelection().servedPath, skinA.path);
    expect(service.serverPath(), skinA.path);
    expect(await fetchBody(service.port), contains('serving_selection_a'));
  });

  test(
    'drops the snapshot when a cancelled recovery retires a replacement',
    () async {
      final service = createService();
      await service.serveFolderAtPath(skinA.path, port: entryPort);
      final generation = service.serveGeneration.value;
      await service.closeSkinListenerForTesting();

      var checks = 0;
      await service
          .recover(isCancelled: () => ++checks >= 5)
          .timeout(const Duration(seconds: 15));

      expect(checks, greaterThanOrEqualTo(5));
      expect(service.isServing, isFalse);
      expect(service.observeServingSelection().isServing, isFalse);
      expect(service.serveGeneration.value, generation);

      await service.recover().timeout(const Duration(seconds: 15));

      expect(await service.checkHealth(), isTrue);
      expect(service.serveGeneration.value, generation + 1);
      expect(service.observeServingSelection().servedPath, skinA.path);
      expect(await fetchBody(service.port), contains('serving_selection_a'));
    },
  );

  test('reports nothing when recovery runs on an idle owner', () async {
    final service = createService();

    await service.recover().timeout(const Duration(seconds: 15));

    expect(service.isServing, isFalse);
    expect(service.observeServingSelection().isServing, isFalse);
    expect(service.port, 3000);
  });
}
