import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/storage/kv_store_service.dart';

class FakeKeyValueStoreService implements KeyValueStoreService {
  final Map<String, Map<String, Object>> _store = {};

  @override
  Future<void> initialize() async {}

  @override
  Future<void> set({
    String namespace = 'default',
    required String key,
    required Object value,
  }) async {
    _store.putIfAbsent(namespace, () => {})[key] = value;
  }

  @override
  Future<bool> delete({
    String namespace = 'default',
    required String key,
  }) async {
    return _store[namespace]?.remove(key) != null;
  }

  @override
  Future<Object?> get({
    String namespace = 'default',
    required String key,
  }) async {
    return _store[namespace]?[key];
  }

  @override
  Future<List<String>> keys({String namespace = 'default'}) async {
    return _store[namespace]?.keys.toList() ?? [];
  }

  @override
  List<String> get namespaces => _store.keys.toList();

  @override
  Future<Map<String, Object>> getAll({String namespace = 'default'}) async {
    return Map<String, Object>.from(_store[namespace] ?? {});
  }
}

PluginManifest testManifest(
  String id, {
  Set<PluginPermissions> permissions = const {
    PluginPermissions.log,
    PluginPermissions.api,
    PluginPermissions.emit,
    PluginPermissions.pluginStorage,
  },
  List<PluginDriverDeclaration> drivers = const [],
  PluginApi? api,
}) {
  return PluginManifest(
    id: id,
    name: id,
    author: 'Test',
    description: 'Test',
    version: '1.0.0',
    apiVersion: 1,
    permissions: permissions,
    drivers: drivers,
    settings: {},
    api: api ?? PluginApi(endpoints: []),
  );
}
