part of '../webserver_service.dart';

final class KvStoreHandler {
  final store = HiveStoreService(defaultNamespace: "kvStore");

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
      await store.delete(key: key, namespace: namespace);
      return jsonOk({});
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
      await store.set(
        key: key,
        value: maybeJson ?? value,
        namespace: namespace,
      );
      return jsonOk({});
    });
  }
}
