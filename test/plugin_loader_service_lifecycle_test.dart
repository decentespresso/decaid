import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';

import 'plugins/plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('failed initialization can be retried', () async {
    var attempts = 0;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          attempts += 1;
          throw StateError('path unavailable');
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final service = PluginLoaderService(kvStore: FakeKeyValueStoreService());

    final first = service.initialize();
    final concurrent = service.initialize();
    expect(identical(first, concurrent), isTrue);
    await expectLater(first, throwsA(isA<PlatformException>()));

    await expectLater(service.initialize(), throwsA(isA<PlatformException>()));
    expect(attempts, 2);

    await service.dispose();
  });
}
