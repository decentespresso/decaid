import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';

import 'plugin_test_helpers.dart';

void main() {
  late PluginManager manager;

  setUp(() {
    manager = PluginManager(kvStore: FakeKeyValueStoreService());
  });

  tearDown(() async => manager.dispose());

  Future<List<String>> collectEvents(Duration window) async {
    final events = <String>[];
    final sub = manager.emitStream.listen(
      (e) => events.add(e['event'] as String),
    );
    await Future<void>.delayed(window);
    await sub.cancel();
    return events;
  }

  String jsTimerCount() => manager.js
      .evaluate('String(globalThis.__debugTimerCount())')
      .stringResult;

  Future<void> loadTimerPlugin(String jsBody) async {
    await manager.loadPlugin(
      id: 'timer.plugin',
      manifest: testManifest('timer.plugin'),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "timer.plugin",
            onLoad() {
              $jsBody
            }
          };
        }
      ''',
    );
  }

  test(
    'setTimeout fires exactly once and removes the registry entry',
    () async {
      await loadTimerPlugin('''
      setTimeout(() => host.emit("fired", "once"), 20);
    ''');

      final events = await collectEvents(const Duration(milliseconds: 300));

      expect(events, ['fired']);
      expect(manager.activeTimerCount, 0);
      expect(jsTimerCount(), '0');
    },
  );

  test('clearTimeout cancels the matching timer', () async {
    await loadTimerPlugin('''
      const id = setTimeout(() => host.emit("bad", "fired"), 20);
      clearTimeout(id);
      setTimeout(() => host.emit("good", "fired"), 60);
    ''');

    final events = await collectEvents(const Duration(milliseconds: 300));

    expect(events, ['good']);
    expect(manager.activeTimerCount, 0);
    expect(jsTimerCount(), '0');
  });

  test('plugin unload cancels armed timers', () async {
    await loadTimerPlugin('''
      setTimeout(() => host.emit("ghost", "fired"), 60);
    ''');

    await manager.unloadPlugin('timer.plugin');
    final events = await collectEvents(const Duration(milliseconds: 200));

    expect(events, isEmpty);
    expect(manager.activeTimerCount, 0);
    expect(jsTimerCount(), '0');
  });

  test('throwing callback still removes timer and registry entry', () async {
    await loadTimerPlugin('''
      setTimeout(() => { throw new Error("boom"); }, 20);
      setTimeout(() => host.emit("afterThrow", "stillFired"), 60);
    ''');

    final events = await collectEvents(const Duration(milliseconds: 300));

    expect(events, ['afterThrow']);
    expect(manager.activeTimerCount, 0);
    expect(jsTimerCount(), '0');
  });

  test(
    'failed plugin load cleans up async work created during onLoad',
    () async {
      await expectLater(
        manager.loadPlugin(
          id: 'timer.plugin',
          manifest: testManifest('timer.plugin'),
          settings: {},
          jsCode: r'''
          function createPlugin(host) {
            return {
              id: "timer.plugin",
              onLoad() {
                setTimeout(() => host.emit("ghost", "fired"), 1000);
                throw new Error("onLoad boom");
              }
            };
          }
        ''',
        ),
        throwsA(isA<Exception>()),
      );

      // Let any in-flight timerSet messages process against the removed plugin.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(manager.activeTimerCount, 0);
      expect(manager.activePendingOpCount, 0);
      expect(jsTimerCount(), '0');
    },
  );

  test('unload sweeps timers scheduled by rejection handlers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await Future<void>.delayed(const Duration(seconds: 10));
      try {
        await req.response.close();
      } catch (_) {}
    });
    addTearDown(server.close);

    await manager.loadPlugin(
      id: 'timer.plugin',
      manifest: testManifest('timer.plugin'),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "timer.plugin",
            onLoad() {
              fetch("http://127.0.0.1:${server.port}/slow")
                .then(() => host.emit("r", "unexpected"))
                .catch(() => {
                  setTimeout(() => host.emit("ghost", "fired"), 1000);
                });
            }
          };
        }
      ''',
    );
    // Let the fetch op register before unloading.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await manager.unloadPlugin('timer.plugin');

    // The rejection handler's setTimeout must be swept, not resurrected.
    expect(manager.activeTimerCount, 0);
    expect(jsTimerCount(), '0');

    final events = await collectEvents(const Duration(milliseconds: 1100));
    expect(events, isEmpty);
    expect(manager.activeTimerCount, 0);
    expect(jsTimerCount(), '0');
  });

  test('timer from a previous plugin generation is not registered', () async {
    await loadTimerPlugin(
      'setTimeout(() => host.emit("ghost", "fired"), 1000);',
    );
    // Reload the same id before the deferred timerSet message is processed.
    await manager.unloadPlugin('timer.plugin');
    await manager.loadPlugin(
      id: 'timer.plugin',
      manifest: testManifest('timer.plugin'),
      settings: {},
      jsCode: 'function createPlugin(host) { return { id: "timer.plugin" }; }',
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(manager.activeTimerCount, 0);
    expect(jsTimerCount(), '0');

    final events = await collectEvents(const Duration(milliseconds: 1100));
    expect(events, isEmpty);
  });

  test('cancelAllOperations cancels multiple plugin-owned timers', () async {
    await loadTimerPlugin('''
      setTimeout(() => host.emit("a", "fired"), 1000);
      setTimeout(() => host.emit("b", "fired"), 1000);
    ''');

    // Let the deferred timerSet messages register before asserting.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(manager.activeTimerCount, 2);
    manager.cancelAllOperations();
    expect(manager.activeTimerCount, 0);

    final events = await collectEvents(const Duration(milliseconds: 200));

    expect(events, isEmpty);
    expect(jsTimerCount(), '0');
  });
}
