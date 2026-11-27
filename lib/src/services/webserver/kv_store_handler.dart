part of '../webserver_service.dart';

final class KvStoreHandler {
  KvStoreHandler({required this.coordinator, KeyValueStoreService? store})
    : store = store ?? HiveStoreService(defaultNamespace: "kvStore");

  final StorageOperationCoordinator coordinator;
  final KeyValueStoreService store;

  Future<Response> _coordinatedWrite(
    String namespace,
    String key,
    Future<void> Function() backend,
  ) async {
    try {
      await coordinator.write(namespace, key, backend);
      return jsonOk({});
    } on StorageOperationException catch (e) {
      final body = {'error': e.code.wireName, 'message': e.code.message};
      return switch (e.code) {
        StorageErrorCode.storageError => jsonError(body),
        StorageErrorCode.timeout ||
        StorageErrorCode.writeIndeterminate => jsonGatewayTimeout(body),
        _ => jsonServiceUnavailable(body),
      };
    }
  }

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/store/<namespace>', (Request req) async {
      final namespace = req.params['namespace'];
      if (namespace == null) {
        return jsonBadRequest({'error': 'Missing namespace'});
      }
      if (req.url.queryParameters['full'] == '1') {
        return jsonOkConditional(req, await store.getAll(namespace: namespace));
      }
      return jsonOk(await store.keys(namespace: namespace));
    });

    app.get('/api/v1/store/<namespace>/<key>', (Request req) async {
      final namespace = req.params['namespace'];
      final key = req.params['key'];
      if (namespace == null || key == null) {
        return jsonBadRequest({'error': 'Missing namespace or key'});
      }
      return jsonOk(await store.get(namespace: namespace, key: key));
    });

    app.delete('/api/v1/store/<namespace>/<key>', (Request req) async {
      final namespace = req.params['namespace'];
      final key = req.params['key'];
      if (namespace == null || key == null) {
        return jsonBadRequest({'error': 'Missing namespace or key'});
      }
      return _coordinatedWrite(
        namespace,
        key,
        () => store.delete(key: key, namespace: namespace),
      );
    });

    app.post('/api/v1/store/<namespace>/<key>', (Request req) async {
      final namespace = req.params['namespace'];
      final key = req.params['key'];
      final value = await readBoundedRequestBodyString(
        req,
        maxBytes: largeRequestBodyBytes,
        timeout: largeRequestBodyTimeout,
      );
      final maybeJson = jsonDecode(value);
      if (namespace == null || key == null) {
        return jsonBadRequest({'error': 'Missing namespace or key'});
      }
      return _coordinatedWrite(
        namespace,
        key,
        () => store.set(
          key: key,
          value: maybeJson ?? value,
          namespace: namespace,
        ),
      );
    });
  }
}
