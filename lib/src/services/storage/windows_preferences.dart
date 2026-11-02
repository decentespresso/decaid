import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

Future<void> initializeWindowsPreferences() async {
  final backend = SharedPreferencesStorePlatform.instance;
  await backend.getAllWithParameters(
    GetAllParameters(filter: PreferencesFilter(prefix: '')),
  );
  final store = _WindowsPreferencesStore(backend);
  SharedPreferencesStorePlatform.instance = store;
  SharedPreferencesAsyncPlatform.instance = _WindowsAsyncPreferences(store);
}

final class _WindowsPreferencesStore extends SharedPreferencesStorePlatform {
  _WindowsPreferencesStore(this.backend);

  final SharedPreferencesStorePlatform backend;
  Future<void> _queue = Future.value();

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final next = _queue.then((_) => operation());
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _restore(
    PreferencesFilter filter,
    Map<String, Object> previous,
  ) async {
    final current = await backend.getAllWithParameters(
      GetAllParameters(filter: filter),
    );
    for (final key in {...previous.keys, ...current.keys}) {
      if (previous[key] == current[key]) continue;
      final value = previous[key];
      if (value == null) {
        await backend.remove(key);
      } else {
        final (type, restoredValue) = switch (value) {
          bool() => ('Bool', value),
          int() => ('Int', value),
          double() => ('Double', value),
          String() => ('String', value),
          List() => ('StringList', List<String>.from(value)),
          _ => throw StateError('Unsupported preferences value'),
        };
        await backend.setValue(type, key, restoredValue);
      }
    }
  }

  Future<bool> _mutate(
    PreferencesFilter filter,
    Future<bool> Function() operation,
  ) => _serialize(() async {
    final previous = await backend.getAllWithParameters(
      GetAllParameters(filter: filter),
    );
    try {
      if (await operation()) return true;
    } catch (_) {
      await _restore(filter, previous);
      rethrow;
    }
    await _restore(filter, previous);
    return false;
  });

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    final savedValue = value is List<String> ? List<String>.of(value) : value;
    return _mutate(
      PreferencesFilter(prefix: '', allowList: {key}),
      () => backend.setValue(valueType, key, savedValue),
    );
  }

  @override
  Future<bool> remove(String key) => _mutate(
    PreferencesFilter(prefix: '', allowList: {key}),
    () => backend.remove(key),
  );

  @override
  Future<bool> clear() => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: 'flutter.')),
  );

  @override
  Future<bool> clearWithPrefix(String prefix) => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: prefix)),
  );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) =>
      _mutate(parameters.filter, () => backend.clearWithParameters(parameters));

  @override
  Future<Map<String, Object>> getAll() => getAllWithPrefix('flutter.');

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: prefix)),
      );

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) => _serialize(() => backend.getAllWithParameters(parameters));
}

final class _WindowsAsyncPreferences extends SharedPreferencesAsyncPlatform {
  _WindowsAsyncPreferences(this.store);

  final SharedPreferencesStorePlatform store;

  Future<void> _set(String type, String key, Object value) async {
    if (!await store.setValue(type, key, value)) {
      throw StateError('Preferences could not be saved');
    }
  }

  Future<T?> _get<T>(String key) async =>
      (await store.getAllWithParameters(
            GetAllParameters(
              filter: PreferencesFilter(prefix: '', allowList: {key}),
            ),
          ))[key]
          as T?;

  @override
  Future<void> setBool(
    String key,
    bool value,
    SharedPreferencesOptions options,
  ) => _set('Bool', key, value);

  @override
  Future<void> setInt(
    String key,
    int value,
    SharedPreferencesOptions options,
  ) => _set('Int', key, value);

  @override
  Future<void> setDouble(
    String key,
    double value,
    SharedPreferencesOptions options,
  ) => _set('Double', key, value);

  @override
  Future<void> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) => _set('String', key, value);

  @override
  Future<void> setStringList(
    String key,
    List<String> value,
    SharedPreferencesOptions options,
  ) => _set('StringList', key, List<String>.of(value));

  @override
  Future<bool?> getBool(String key, SharedPreferencesOptions options) =>
      _get<bool>(key);

  @override
  Future<int?> getInt(String key, SharedPreferencesOptions options) =>
      _get<int>(key);

  @override
  Future<double?> getDouble(String key, SharedPreferencesOptions options) =>
      _get<double>(key);

  @override
  Future<String?> getString(String key, SharedPreferencesOptions options) =>
      _get<String>(key);

  @override
  Future<List<String>?> getStringList(
    String key,
    SharedPreferencesOptions options,
  ) async => (await _get<List<Object?>>(key))?.cast<String>().toList();

  @override
  Future<Map<String, Object>> getPreferences(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) => store.getAllWithParameters(
    GetAllParameters(
      filter: PreferencesFilter(
        prefix: '',
        allowList: parameters.filter.allowList,
      ),
    ),
  );

  @override
  Future<Set<String>> getKeys(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async => (await getPreferences(parameters, options)).keys.toSet();

  @override
  Future<void> clear(
    ClearPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async {
    if (!await store.clearWithParameters(
      ClearParameters(
        filter: PreferencesFilter(
          prefix: '',
          allowList: parameters.filter.allowList,
        ),
      ),
    )) {
      throw StateError('Preferences could not be removed');
    }
  }
}
