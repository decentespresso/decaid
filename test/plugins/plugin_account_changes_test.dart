import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'account changes reach only account-reading plugins and detach on disposal',
    () async {
      final changes = StreamController<void>.broadcast();
      final loader = PluginLoaderService(
        kvStore: FakeKeyValueStoreService(),
        decentAccountChanges: changes.stream,
      );
      addTearDown(changes.close);
      addTearDown(loader.dispose);
      final manager = loader.pluginManager;
      const code = '''
function createPlugin(host) {
  return { id: "PLUGIN_ID", onLoad() {}, onEvent(event) {
    if (event.name === "decentAccountChanged") host.emit("changed", event.payload);
  } };
}
''';
      for (final authorized in [false, true]) {
        final id = authorized ? 'reader.reaplugin' : 'unrelated.reaplugin';
        await manager.loadPlugin(
          id: id,
          manifest: testManifest(
            id,
            permissions: {
              PluginPermissions.emit,
              if (authorized) PluginPermissions.proxyDecentApi,
            },
          ),
          settings: {},
          jsCode: code.replaceFirst('PLUGIN_ID', id),
        );
      }
      final delivered = manager.emitStream.first;
      changes.add(null);
      final event = await delivered.timeout(const Duration(seconds: 5));
      expect(event['pluginId'], 'reader.reaplugin');
      expect(event['event'], 'changed');
      expect(event['payload'], isEmpty);
      await loader.dispose();
      expect(changes.hasListener, isFalse);
    },
  );
}
