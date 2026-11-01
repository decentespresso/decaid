import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

Future<void> initializeWindowsPreferences() async {
  final store = SharedPreferencesStorePlatform.instance;
  await store.getAllWithParameters(
    GetAllParameters(filter: PreferencesFilter(prefix: '')),
  );
  SharedPreferencesAsyncPlatform.instance = _WindowsAsyncPreferences(store);
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
