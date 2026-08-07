abstract class KeyValueStoreService {
  Future<void> initialize();
  Future<void> set({
    String namespace = "default",
    required String key,
    required Object value,
  });
  Future<bool> delete({String namespace = "default", required String key});
  Future<Object?> get({String namespace = "default", required String key});

  Future<List<String>> keys({String namespace = "default"});

  List<String> get namespaces;

  Future<Map<String, Object>> getAll({String namespace = "default"});
}
