import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/skin_feature/skin_switch_coordinator.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';

void main() {
  const entryPort = 3013;
  const testRangeStart = 26800;
  const testRangeSize = 32;

  late Directory skinA;
  late Directory skinB;
  final services = <WebUIService>[];

  Future<Directory> createSkin(String prefix) async {
    final dir = await Directory.systemTemp.createTemp(prefix);
    await File(
      '${dir.path}/index.html',
    ).writeAsString('<html><body>$prefix</body></html>');
    return dir;
  }

  WebUIService createService() {
    final service = WebUIService(
      listLocalAddresses: () async => const <String>[],
    );
    services.add(service);
    return service;
  }

  setUp(() async {
    WebUIService.resolveWifiIP = () async => 'localhost';
    WebUIService.skinPortRangeStart = testRangeStart;
    WebUIService.skinPortRangeSize = testRangeSize;
    skinA = await createSkin('skin_switch_a');
    skinB = await createSkin('skin_switch_b');
  });

  tearDown(() async {
    for (final service in services) {
      await service.stopServing();
    }
    services.clear();
    for (final dir in [skinA, skinB]) {
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  });

  test('skin API exposes switchSkin bound to the active skin origin', () {
    final script = buildSkinApiJavaScript(port: 24801);

    expect(script, contains('window.decentApp.switchSkin'));
    expect(script, contains('http://localhost:24801$skinSwitchPath'));
    expect(script, contains('__DECENT_HOST__'));
    expect(script, contains('encodeURIComponent'));
  });

  test('serveGeneration advances once per successful serve', () async {
    final service = createService();
    expect(service.serveGeneration.value, 0);

    await service.serveFolderAtPath(skinA.path, port: entryPort);
    final first = service.serveGeneration.value;
    final firstPort = service.port;
    expect(first, 1);

    await service.serveFolderAtPath(skinB.path, port: entryPort);
    expect(service.serveGeneration.value, 2);
    expect(service.port, isNot(firstPort));
  });

  test('serveGeneration does not advance when serving fails', () async {
    final service = createService();
    await service.serveFolderAtPath(skinA.path, port: entryPort);

    await expectLater(
      service.serveFolderAtPath('${skinA.path}/missing', port: entryPort),
      throwsA(anything),
    );

    expect(service.serveGeneration.value, 1);
  });

  group('SkinSwitchCoordinator', () {
    late WebUIService service;
    late List<String> persisted;
    late Map<String, String> skins;
    late SkinSwitchCoordinator coordinator;

    setUp(() async {
      service = createService();
      persisted = [];
      skins = {'a': skinA.path, 'b': skinB.path};
      coordinator = SkinSwitchCoordinator(
        service: service,
        skinPath: (id) => skins[id],
        setDefaultSkin: (id) async => persisted.add(id),
        entryPort: entryPort,
      );
      await service.serveFolderAtPath(skinA.path, port: entryPort);
    });

    test('switches to an installed skin and persists the selection', () async {
      final generation = service.serveGeneration.value;

      expect(await coordinator.switchTo('b'), SkinSwitchOutcome.switched);
      expect(service.serverPath(), skinB.path);
      expect(service.serveGeneration.value, generation + 1);
      expect(persisted, ['b']);
    });

    test('rejects an uninstalled skin id without restarting', () async {
      final generation = service.serveGeneration.value;

      expect(await coordinator.switchTo('nope'), SkinSwitchOutcome.unknownSkin);
      expect(service.serverPath(), skinA.path);
      expect(service.serveGeneration.value, generation);
      expect(persisted, isEmpty);
    });

    test('treats the already served skin as a no-op', () async {
      final generation = service.serveGeneration.value;
      final port = service.port;

      expect(await coordinator.switchTo('a'), SkinSwitchOutcome.unchanged);
      expect(service.serveGeneration.value, generation);
      expect(service.port, port);
      expect(persisted, isEmpty);
    });

    test('is single-flight for concurrent requests', () async {
      final first = coordinator.switchTo('b');
      final second = coordinator.switchTo('a');

      expect(await second, SkinSwitchOutcome.busy);
      expect(await first, SkinSwitchOutcome.switched);
      expect(service.serverPath(), skinB.path);
      expect(persisted, ['b']);
    });

    test('restores the previous skin when the new one fails', () async {
      skins['broken'] = '${skinA.path}/missing';

      expect(await coordinator.switchTo('broken'), SkinSwitchOutcome.failed);
      expect(service.isServing, isTrue);
      expect(service.serverPath(), skinA.path);
      expect(persisted, isEmpty);
    });

    test('allows a later switch after a failed one', () async {
      skins['broken'] = '${skinA.path}/missing';

      expect(await coordinator.switchTo('broken'), SkinSwitchOutcome.failed);
      expect(await coordinator.switchTo('b'), SkinSwitchOutcome.switched);
      expect(service.serverPath(), skinB.path);
    });
  });
}
