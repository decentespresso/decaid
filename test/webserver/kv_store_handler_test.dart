import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/storage/storage_operation_coordinator.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../plugins/plugin_test_helpers.dart';

class _GatedStore extends FakeKeyValueStoreService {
  final log = <String>[];
  Completer<void>? gate;

  @override
  Future<void> set({
    String namespace = 'default',
    required String key,
    required Object value,
  }) async {
    final pending = gate;
    gate = null;
    if (pending != null) await pending.future;
    log.add('set $value');
    await super.set(namespace: namespace, key: key, value: value);
  }

  @override
  Future<bool> delete({
    String namespace = 'default',
    required String key,
  }) async {
    log.add('delete');
    return super.delete(namespace: namespace, key: key);
  }
}

void main() {
  late _GatedStore store;
  late StorageOperationCoordinator coordinator;
  late RouterPlus app;

  setUp(() {
    store = _GatedStore();
    coordinator = StorageOperationCoordinator(
      limits: const StorageOperationLimits(
        operationTimeout: Duration(seconds: 2),
        drainTimeout: Duration(seconds: 2),
      ),
    );
    app = Router().plus;
    KvStoreHandler(coordinator: coordinator, store: store).addRoutes(app);
  });

  Future<Response> send(String method, String path, [String? body]) async =>
      await app.call(
        Request(method, Uri.parse('http://localhost$path'), body: body),
      );

  test('writes and deletes succeed outside maintenance', () async {
    expect((await send('POST', '/api/v1/store/ns/k', '"v"')).statusCode, 200);
    expect(await store.get(namespace: 'ns', key: 'k'), 'v');
    expect((await send('DELETE', '/api/v1/store/ns/k')).statusCode, 200);
    expect(await store.get(namespace: 'ns', key: 'k'), isNull);

    final missing = await send('DELETE', '/api/v1/store/ns/missing');
    expect(missing.statusCode, 200);
    expect(jsonDecode(await missing.readAsString()), <String, dynamic>{});
  });

  test('writes and deletes are refused while restore holds the namespace '
      '(case-insensitively)', () async {
    final hold = Completer<void>();
    final maintenance = coordinator.runMaintenance({
      'Plugin.A',
    }, () => hold.future);
    await Future<void>.delayed(Duration.zero);

    for (final response in [
      await send('POST', '/api/v1/store/plugin.a/k', '"v"'),
      await send('DELETE', '/api/v1/store/plugin.a/k'),
    ]) {
      expect(response.statusCode, 503);
      expect(jsonDecode(await response.readAsString()), {
        'error': 'maintenance',
        'message': StorageErrorCode.maintenance.message,
      });
    }
    expect(store.log, isEmpty);
    expect(
      (await send('POST', '/api/v1/store/other/k', '"v"')).statusCode,
      200,
    );

    hold.complete();
    await maintenance;
    expect(
      (await send('POST', '/api/v1/store/plugin.a/k', '"v"')).statusCode,
      200,
    );
  });

  test('a REST write is ordered after a queued plugin write', () async {
    final gate = Completer<void>();
    store.gate = gate;
    final pluginWrite = coordinator.write(
      'plugin.a',
      'k',
      () => store.set(namespace: 'plugin.a', key: 'k', value: 'plugin'),
    );
    final rest = send('POST', '/api/v1/store/plugin.a/k', '"rest"');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(store.log, isEmpty);

    gate.complete();
    await pluginWrite;
    expect((await rest).statusCode, 200);
    expect(store.log, ['set plugin', 'set rest']);
    expect(await store.get(namespace: 'plugin.a', key: 'k'), 'rest');
  });

  test('a backend failure returns a bounded 500', () async {
    final failing = _FailingStore();
    app = Router().plus;
    KvStoreHandler(coordinator: coordinator, store: failing).addRoutes(app);

    final response = await send('POST', '/api/v1/store/ns/k', '"v"');
    expect(response.statusCode, 500);
    final body = await response.readAsString();
    expect(jsonDecode(body)['error'], 'storage_error');
    expect(body, isNot(contains('secret')));
  });
}

class _FailingStore extends FakeKeyValueStoreService {
  @override
  Future<void> set({
    String namespace = 'default',
    required String key,
    required Object value,
  }) async => throw StateError('secret');
}
