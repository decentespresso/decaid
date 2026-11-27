import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/storage/storage_operation_coordinator.dart';

import 'plugin_test_helpers.dart';

const _pluginId = 'storage.v2';
const _timeout = Duration(milliseconds: 250);

class _ControlledStore extends FakeKeyValueStoreService {
  Future<Object?> Function(String namespace, String key)? onGet;
  Future<void> Function(String namespace, String key, Object value)? onSet;

  @override
  Future<Object?> get({String namespace = 'default', required String key}) =>
      onGet?.call(namespace, key) ?? super.get(namespace: namespace, key: key);

  @override
  Future<void> set({
    String namespace = 'default',
    required String key,
    required Object value,
  }) =>
      onSet?.call(namespace, key, value) ??
      super.set(namespace: namespace, key: key, value: value);

  Future<void> setDirect(String namespace, String key, Object value) =>
      super.set(namespace: namespace, key: key, value: value);
}

class _Harness {
  _Harness({
    int maxOutstanding = 32,
    Duration operationTimeout = _timeout,
    Duration drainTimeout = _timeout,
  }) : store = _ControlledStore(),
       coordinator = StorageOperationCoordinator(
         limits: StorageOperationLimits(
           operationTimeout: operationTimeout,
           drainTimeout: drainTimeout,
           maxOutstandingPerNamespace: maxOutstanding,
         ),
       ) {
    manager = PluginManager(kvStore: store, storageCoordinator: coordinator);
    _subscription = manager.emitStream.listen((event) {
      events.add({'name': event['event'], 'payload': event['payload']});
    });
  }

  final _ControlledStore store;
  final StorageOperationCoordinator coordinator;
  late final PluginManager manager;
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  final List<Map<String, dynamic>> events = [];

  Future<void> load({
    Set<PluginPermissions> permissions = const {
      PluginPermissions.emit,
      PluginPermissions.pluginStorage,
    },
    String onUnload = '',
  }) => manager.loadPlugin(
    id: _pluginId,
    manifest: testManifest(_pluginId, permissions: permissions),
    settings: const {},
    jsCode:
        '''
      function createPlugin(host) {
        return {
          id: "$_pluginId",
          onLoad() {
            host.emit("loaded", {
              generation: globalThis.__generationCounter =
                (globalThis.__generationCounter || 0) + 1,
              storageVersion: host.storageVersion ?? null
            });
          },
          onUnload() { $onUnload },
          onEvent(event) {
            if (event.name === "command") {
              try {
                host.storage(event.payload);
              } catch (error) {
                host.emit("thrown", { name: error.name });
              }
              return;
            }
            if (event.name.startsWith("storage")) {
              host.emit(event.name, event.payload ?? null);
            }
          }
        };
      }
    ''',
  );

  void command(Map<String, dynamic> command) =>
      manager.dispatchEvent(_pluginId, 'command', command);

  List<Map<String, dynamic>> named(String name) => [
    for (final event in events)
      if (event['name'] == name) Map<String, dynamic>.from(event['payload']),
  ];

  Future<void> settle([Duration duration = const Duration(milliseconds: 20)]) =>
      Future<void>.delayed(duration);

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 500 && !condition(); i++) {
      await settle(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  Future<void> dispose() async {
    await manager.dispose();
    await _subscription.cancel();
  }
}

Map<String, dynamic> _read(int requestId, String key) => {
  'type': 'read',
  'key': key,
  'version': 2,
  'requestId': requestId,
};

Map<String, dynamic> _write(int requestId, String key, Object? data) => {
  'type': 'write',
  'key': key,
  'data': data,
  'version': 2,
  'requestId': requestId,
};

void main() {
  late _Harness harness;

  setUp(() async {
    harness = _Harness();
    await harness.load();
  });

  tearDown(() => harness.dispose());

  test('advertises the storage protocol version', () async {
    await harness.waitFor(() => harness.named('loaded').isNotEmpty);
    expect(harness.named('loaded').single['storageVersion'], 2);
  });

  test('correlates reads, missing-key reads and writes', () async {
    await harness.store.set(namespace: _pluginId, key: 'present', value: 'v');
    final generation = harness.manager.pluginGeneration(_pluginId);

    harness.command(_read(0, 'present'));
    harness.command(_read(1, 'missing'));
    harness.command(_write(2, 'saved', {'a': 1}));
    await harness.waitFor(() => harness.named('storageResult').length == 3);

    final results = {
      for (final r in harness.named('storageResult')) r['requestId']: r,
    };
    expect(results[0], {
      'requestId': 0,
      'operation': 'read',
      'generation': generation,
      'ok': true,
      'value': 'v',
    });
    expect(results[1], {
      'requestId': 1,
      'operation': 'read',
      'generation': generation,
      'ok': true,
      'value': null,
    });
    expect(results[2], {
      'requestId': 2,
      'operation': 'write',
      'generation': generation,
      'ok': true,
    });
    expect(await harness.store.get(namespace: _pluginId, key: 'saved'), {
      'a': 1,
    });
    expect(harness.named('storageRead'), isEmpty);
    expect(harness.named('storageWrite'), isEmpty);
  });

  test('legacy commands keep their events and payloads', () async {
    await harness.store.set(namespace: _pluginId, key: 'k', value: 'v');

    harness.command({'type': 'read', 'key': 'k', 'namespace': 'ignored'});
    harness.command({
      'type': 'write',
      'key': 'w',
      'namespace': 'ignored',
      'data': {'x': 1},
    });
    await harness.waitFor(
      () =>
          harness.named('storageRead').isNotEmpty &&
          harness.events.any((e) => e['name'] == 'storageWrite'),
    );

    expect(harness.named('storageRead').single, {'key': 'k', 'value': 'v'});
    expect(
      harness.events.firstWhere((e) => e['name'] == 'storageWrite')['payload'],
      {'x': 1},
    );
    expect(await harness.store.get(namespace: _pluginId, key: 'w'), {'x': 1});
    expect(await harness.store.get(namespace: 'ignored', key: 'w'), isNull);
    expect(harness.named('storageResult'), isEmpty);
  });

  test('backend failures return a bounded error without internals', () async {
    harness.store.onGet = (_, _) async =>
        throw StateError('secret token at /data/user');
    harness.store.onSet = (_, _, _) async =>
        throw StateError('secret token at /data/user');

    harness.command(_read(1, 'k'));
    harness.command(_write(2, 'k', 'stored-secret'));
    harness.command({'type': 'read', 'key': 'legacy'});
    await harness.waitFor(() => harness.named('storageResult').length == 2);
    await harness.settle();

    for (final result in harness.named('storageResult')) {
      expect(result['ok'], isFalse);
      expect(result['error'], {
        'code': 'storage_error',
        'message': StorageErrorCode.storageError.message,
      });
      expect(result.toString(), isNot(contains('secret')));
    }
    expect(harness.named('storageRead'), isEmpty);
  });

  test('never-settling reads and writes time out', () async {
    harness.store.onGet = (_, _) => Completer<Object?>().future;
    harness.store.onSet = (_, _, _) => Completer<void>().future;

    harness.command(_read(1, 'k'));
    harness.command(_write(2, 'k', 1));
    await harness.waitFor(() => harness.named('storageResult').length == 2);

    final codes = {
      for (final r in harness.named('storageResult'))
        r['requestId']: r['error']['code'],
    };
    expect(codes, {1: 'timeout', 2: 'write_indeterminate'});
    expect(harness.coordinator.isQuarantined(_pluginId, 'k'), isTrue);

    harness.command(_write(3, 'k', 2));
    await harness.waitFor(() => harness.named('storageResult').length == 3);
    expect(harness.named('storageResult').last['error']['code'], 'quarantined');
  });

  test('concurrent requests settle out of order with their own IDs', () async {
    final gates = {'a': Completer<void>(), 'b': Completer<void>()};
    harness.store.onGet = (_, key) async {
      await gates[key]!.future;
      return 'value-$key';
    };

    harness.command(_read(10, 'a'));
    harness.command(_read(11, 'b'));
    await harness.settle();
    gates['b']!.complete();
    await harness.waitFor(() => harness.named('storageResult').length == 1);
    gates['a']!.complete();
    await harness.waitFor(() => harness.named('storageResult').length == 2);

    expect(
      harness
          .named('storageResult')
          .map((r) => (r['requestId'], r['value']))
          .toList(),
      [(11, 'value-b'), (10, 'value-a')],
    );
  });

  test('duplicate, lower and malformed IDs produce no result', () async {
    harness.command(_read(5, 'k'));
    await harness.waitFor(() => harness.named('storageResult').length == 1);

    harness.command(_read(5, 'k'));
    harness.command(_read(4, 'k'));
    for (final id in [-1, 1.5, 9007199254740992, '6', null]) {
      harness.command({..._read(0, 'k'), 'requestId': id});
    }
    await harness.settle(const Duration(milliseconds: 100));
    expect(harness.named('storageResult').map((r) => r['requestId']), [5]);

    harness.command(_read(6, 'k'));
    await harness.waitFor(() => harness.named('storageResult').length == 2);
  });

  test('invalid commands with a valid ID return invalid_command', () async {
    harness.command({
      'type': 'delete',
      'key': 'k',
      'version': 2,
      'requestId': 1,
    });
    harness.command({'type': 'read', 'version': 2, 'requestId': 2});
    harness.command(_write(3, 'k', null));
    await harness.waitFor(() => harness.named('storageResult').length == 3);

    for (final result in harness.named('storageResult')) {
      expect(result['ok'], isFalse);
      expect(result['error']['code'], 'invalid_command');
    }
    expect(harness.named('storageResult').first['operation'], isNull);
  });

  test('unsupported storage versions return invalid_command', () async {
    harness.command({..._read(1, 'k'), 'version': 3});
    harness.command({..._read(2, 'k'), 'version': null});
    harness.command({'type': 'read', 'key': 'k', 'version': 1});
    await harness.waitFor(() => harness.named('storageResult').length == 2);
    await harness.settle(const Duration(milliseconds: 100));

    expect(harness.named('storageResult').map((r) => r['error']['code']), [
      'invalid_command',
      'invalid_command',
    ]);
    expect(harness.named('storageRead'), isEmpty);
  });

  test('the drain deadline bounds unload independently of the operation '
      'deadline', () async {
    await harness.dispose();
    harness = _Harness(
      operationTimeout: const Duration(minutes: 5),
      drainTimeout: const Duration(milliseconds: 200),
    );
    await harness.load();
    harness.store.onSet = (_, _, _) => Completer<void>().future;
    harness.command({'type': 'write', 'key': 'stuck', 'data': 1});
    harness.command(_write(1, 'stuck2', 1));
    await harness.settle();

    final stopwatch = Stopwatch()..start();
    await harness.manager.unloadPlugin(_pluginId);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 20)));
    expect(harness.manager.loadedPlugins, isEmpty);
    expect(harness.coordinator.outstanding(_pluginId), 2);
  });

  test(
    'unload and reload stay bounded when the backend never settles',
    () async {
      harness.store.onGet = (_, _) => Completer<Object?>().future;
      harness.store.onSet = (_, _, _) => Completer<void>().future;
      harness.command(_read(1, 'k'));
      harness.command({'type': 'write', 'key': 'legacy', 'data': 1});
      await harness.settle();

      final stopwatch = Stopwatch()..start();
      await harness.load();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      await harness.manager.unloadPlugin(_pluginId);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    },
  );

  test('late completion after replacement reaches no runtime', () async {
    final read = Completer<Object?>();
    harness.store.onGet = (_, _) => read.future;
    harness.command(_read(1, 'k'));
    harness.command({'type': 'read', 'key': 'k'});
    await harness.settle();

    await harness.load();
    await harness.waitFor(() => harness.named('loaded').length == 2);
    harness.events.removeWhere((e) => e['name'] != 'loaded');

    read.complete('stale');
    await harness.settle(const Duration(milliseconds: 400));
    expect(harness.named('storageResult'), isEmpty);
    expect(harness.named('storageRead'), isEmpty);

    harness.store.onGet = null;
    harness.command(_read(1, 'k'));
    await harness.waitFor(() => harness.named('storageResult').length == 1);
    expect(
      harness.named('storageResult').single['generation'],
      harness.manager.pluginGeneration(_pluginId),
    );
  });

  test('backend budget persists across generations', () async {
    await harness.dispose();
    harness = _Harness(maxOutstanding: 2);
    await harness.load();
    harness.store.onGet = (_, _) => Completer<Object?>().future;
    harness.command(_read(1, 'a'));
    harness.command({'type': 'read', 'key': 'b'});
    await harness.settle();
    expect(harness.coordinator.outstanding(_pluginId), 2);

    await harness.load();
    harness.store.onGet = null;
    harness.command(_read(1, 'c'));
    await harness.waitFor(() => harness.named('storageResult').isNotEmpty);
    expect(harness.named('storageResult').last['error']['code'], 'capacity');
  });

  test('a late old write cannot overwrite a newer generation write', () async {
    final oldWrite = Completer<void>();
    harness.store.onSet = (namespace, key, value) async {
      if (value == 'old') await oldWrite.future;
      await harness.store.setDirect(namespace, key, value);
    };
    harness.command(_write(1, 'k', 'old'));
    await harness.waitFor(() => harness.named('storageResult').isNotEmpty);
    expect(
      harness.named('storageResult').single['error']['code'],
      'write_indeterminate',
    );

    await harness.load();
    harness.events.clear();
    harness.command(_write(1, 'k', 'new'));
    await harness.waitFor(() => harness.named('storageResult').isNotEmpty);
    expect(
      harness.named('storageResult').single['error']['code'],
      'quarantined',
    );

    oldWrite.complete();
    await harness.waitFor(
      () => !harness.coordinator.isQuarantined(_pluginId, 'k'),
    );
    expect(harness.named('storageResult'), hasLength(1));
    harness.command(_write(2, 'k', 'new'));
    await harness.waitFor(() => harness.named('storageResult').length == 2);
    expect(harness.named('storageResult').last['ok'], isTrue);
    expect(await harness.store.get(namespace: _pluginId, key: 'k'), 'new');
  });

  test('unload-time legacy writes still persist', () async {
    await harness.load(
      onUnload: 'host.storage({type: "write", key: "bye", data: 7});',
    );
    await harness.load();
    expect(await harness.store.get(namespace: _pluginId, key: 'bye'), 7);
  });

  test('maintenance rejects plugin access until released', () async {
    final release = Completer<void>();
    final maintenance = harness.coordinator.runMaintenance({
      _pluginId,
    }, () => release.future);
    await harness.settle();

    harness.command(_read(1, 'k'));
    await harness.waitFor(() => harness.named('storageResult').isNotEmpty);
    expect(
      harness.named('storageResult').single['error']['code'],
      'maintenance',
    );

    release.complete();
    await maintenance;
    harness.command(_read(2, 'k'));
    await harness.waitFor(() => harness.named('storageResult').length == 2);
    expect(harness.named('storageResult').last['ok'], isTrue);
  });

  test('missing permission keeps throwing for version 2 commands', () async {
    await harness.load(permissions: const {PluginPermissions.emit});
    harness.command(_read(1, 'k'));
    await harness.waitFor(() => harness.named('thrown').isNotEmpty);
    expect(harness.named('thrown').single['name'], 'PluginPermissionError');
    expect(harness.named('storageResult'), isEmpty);
  });
}
