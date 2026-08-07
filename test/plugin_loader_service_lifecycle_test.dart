import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';

import 'plugins/plugin_test_helpers.dart';

void main() {
  test('dispose is shared and rejects later loader work', () async {
    final service = PluginLoaderService(kvStore: FakeKeyValueStoreService());

    final first = service.dispose();
    final second = service.dispose();

    expect(identical(first, second), isTrue);
    expect(service.lifecycle, PluginLoaderLifecycle.disposing);
    await Future.wait([first, second]);
    expect(service.lifecycle, PluginLoaderLifecycle.disposed);
    expect(service.pluginManager.lifecycle.name, 'disposed');
    expect(service.initialize, throwsStateError);
    expect(() => service.loadPlugin('late.plugin'), throwsStateError);
    await expectLater(service.reloadPlugin('late.plugin'), throwsStateError);
    await expectLater(service.removePlugin('late.plugin'), throwsStateError);
    await service.dispose();
  });
}
