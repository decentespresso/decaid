import 'package:hive_ce_flutter/adapters.dart';
import 'package:reaprime/src/services/storage/kv_store_service.dart';

void ensureFlutterTypeAdaptersRegistered() {
  for (final TypeAdapter adapter in [ColorAdapter(), TimeOfDayAdapter()]) {
    if (!Hive.isAdapterRegistered(adapter.typeId)) {
      Hive.registerAdapter(adapter);
    }
  }
}

class HiveStoreService implements KeyValueStoreService {
  final String defaultNamespace;
  final Map<String, Box> _boxes = {};
  HiveStoreService({required this.defaultNamespace});

  @override
  Future<bool> delete({String? namespace, required String key}) async {
    final box = await _getOrCreateNamespace(namespace ?? defaultNamespace);
    await box.delete(key);
    return true;
  }

  @override
  Future<Object?> get({String? namespace, required String key}) async {
    final box = await _getOrCreateNamespace(namespace ?? defaultNamespace);
    return await box.get(key);
  }

  @override
  Future<void> initialize() async {
    _boxes["default"] = await Hive.openBox(defaultNamespace);
  }

  @override
  Future<List<String>> keys({String? namespace}) async {
    final box = await _getOrCreateNamespace(namespace ?? defaultNamespace);
    return box.keys.map((e) => e.toString()).toList();
  }

  @override
  Future<void> set({
    String? namespace,
    required String key,
    required Object value,
  }) async {
    final box = await _getOrCreateNamespace(namespace ?? defaultNamespace);
    await box.put(key, value);
  }

  @override
  List<String> get namespaces {
    final result = <String>{defaultNamespace};
    for (final key in _boxes.keys) {
      if (key != 'default') {
        result.add(key);
      }
    }
    return result.toList();
  }

  @override
  Future<Map<String, Object>> getAll({String? namespace}) async {
    final box = await _getOrCreateNamespace(namespace ?? defaultNamespace);
    final result = <String, Object>{};
    for (final key in box.keys) {
      final value = box.get(key);
      if (value != null) {
        result[key.toString()] = value;
      }
    }
    return result;
  }

  Future<Box> _getOrCreateNamespace(String namespace) async {
    if (_boxes.containsKey(namespace)) {
      return _boxes[namespace]!;
    }
    _boxes[namespace] = await Hive.openBox(namespace);
    return _boxes[namespace]!;
  }
}
