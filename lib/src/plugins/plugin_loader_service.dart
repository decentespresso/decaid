import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:reaprime/src/services/storage/app_directories.dart';
import 'package:reaprime/src/services/storage/kv_store_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_package.dart';
import 'package:reaprime/src/plugins/plugin_runtime.dart';
import 'package:reaprime/src/plugins/plugin_version.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart'
    show CredentialStore;
import 'package:reaprime/src/services/account/decent_proxy_service.dart';
import 'package:reaprime/src/util/safe_path.dart';

class PluginSettingsValidationException implements Exception {
  final String message;
  PluginSettingsValidationException(this.message);

  @override
  String toString() => message;
}

class PluginDowngradeException implements Exception {
  final String message;
  PluginDowngradeException(this.message);

  @override
  String toString() => message;
}

enum PluginLoaderLifecycle { active, disposing, disposed }

class PluginLoaderService {
  static const _loadTimeout = Duration(seconds: 1);
  static const _maxConsecutiveLoadFailures = 3;
  static const _loadingPluginKey = 'plugin.watchdog.loading';
  static const _stagingSuffix = '.staged';
  static const _backupSuffix = '.previous';

  final PluginManager pluginManager;
  final CredentialStore? _credentialStore;
  final _log = Logger('PluginLoaderService');

  late Directory _pluginsDir;
  late SharedPreferences _prefs;
  final Map<String, PluginManifest> _availablePluginsCache = {};
  Map<String, Map<String, dynamic>> _volatileSecureSettings = {};
  Future<void> _pluginLoadQueue = Future.value();
  final Map<String, Future<void>> _pluginSettingsLocks = {};
  final Map<String, Future<void>> _pluginMutationLocks = {};
  Future<void>? _initialization;
  Future<void>? _disposeFuture;
  PluginLoaderLifecycle _lifecycle = PluginLoaderLifecycle.active;

  PluginLoaderService({
    required KeyValueStoreService kvStore,
    DecentProxyService? decentProxyService,
    CredentialStore? credentialStore,
  }) : _credentialStore = credentialStore,
       pluginManager = PluginManager(
         kvStore: kvStore,
         decentProxyService: decentProxyService,
       );

  bool _initialized = false;
  PluginLoaderLifecycle get lifecycle => _lifecycle;

  void _ensureActive() {
    if (_lifecycle != PluginLoaderLifecycle.active) {
      throw StateError('PluginLoaderService is ${_lifecycle.name}');
    }
  }

  Future<void> initialize() {
    _ensureActive();
    if (_initialized) {
      _log.fine('PluginLoaderService already initialized');
      return Future.value();
    }
    return _initialization ??= _initializeWithRetry();
  }

  Future<void> _initializeWithRetry() async {
    try {
      await _initialize();
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  Future<void> _initialize() async {
    _pluginsDir = Directory(await AppDirectories.plugins);

    _prefs = await SharedPreferences.getInstance();
    await _recoverInterruptedPluginLoad();

    if (!_pluginsDir.existsSync()) {
      _pluginsDir.createSync(recursive: true);
      _log.info('Created plugins directory: ${_pluginsDir.path}');
    }

    await _copyBundledPlugins();

    await _scanAvailablePlugins();

    await _loadAutoLoadPlugins();

    _initialized = true;
  }

  Future<void> addPlugin(String sourcePath) async {
    if (File(sourcePath).existsSync()) {
      throw Exception(
        'File-based plugin installation not yet implemented. Please provide a directory path.',
      );
    }
    final sourceDir = Directory(sourcePath);
    if (!sourceDir.existsSync()) {
      throw Exception('Source does not exist: $sourcePath');
    }

    await installPluginPackage(sourceDir);
  }

  Future<PluginManifest> installPluginPackage(
    Directory stagedDir, {
    bool allowDowngrade = false,
  }) async {
    final package = resolvePluginPackage(stagedDir);
    final manifest = package.manifest;
    final pluginId = manifest.id;

    return _withPluginMutationLock(pluginId, () async {
      _ensureActive();
      if (!allowDowngrade) _ensureNotDowngrade(manifest);
      final settingsSnapshot = await _capturePersistedSettings(pluginId);

      final pluginDir = Directory('${_pluginsDir.path}/$pluginId');
      final backupDir = Directory('${pluginDir.path}$_backupSuffix');
      final previousManifest = _availablePluginsCache[pluginId];
      final wasLoaded = isPluginLoaded(pluginId);

      if (wasLoaded) {
        await _unloadPlugin(pluginId);
      }

      if (backupDir.existsSync()) backupDir.deleteSync(recursive: true);
      final hadPrevious = pluginDir.existsSync();
      if (hadPrevious) pluginDir.renameSync(backupDir.path);

      try {
        pluginDir.createSync(recursive: true);
        await _copyDirectory(package.root, pluginDir);
        _availablePluginsCache[pluginId] = manifest;

        if (wasLoaded) {
          await _queuedLoad(pluginId);
        }
      } catch (e) {
        _log.warning('Rolling back failed install of plugin $pluginId', e);
        // Restore settings before the previous version reloads: the reload
        // re-reads reconciled settings under the settings lock.
        await _restorePersistedSettings(pluginId, settingsSnapshot);
        if (pluginDir.existsSync()) pluginDir.deleteSync(recursive: true);
        if (hadPrevious) {
          backupDir.renameSync(pluginDir.path);
          if (previousManifest == null) {
            _availablePluginsCache.remove(pluginId);
          } else {
            _availablePluginsCache[pluginId] = previousManifest;
            if (wasLoaded) {
              try {
                await _queuedLoad(pluginId);
              } catch (e2) {
                _log.warning(
                  'Failed to reload previous version of plugin $pluginId',
                  e2,
                );
              }
            }
          }
        } else {
          _availablePluginsCache.remove(pluginId);
        }
        rethrow;
      }

      if (backupDir.existsSync()) backupDir.deleteSync(recursive: true);
      _log.info('Plugin installed: $pluginId (${manifest.version})');
      return manifest;
    });
  }

  Future<PluginManifest> updatePluginSource(
    String pluginId, {
    required Map<String, dynamic> manifestJson,
    required String pluginJs,
  }) async {
    if (!isSafePathComponent(pluginId)) {
      throw FormatException(
        'Unsafe plugin id "$pluginId": must be a single safe path component',
      );
    }

    final PluginManifest manifest;
    try {
      manifest = PluginManifest.fromJson(manifestJson);
    } catch (e) {
      throw FormatException('Invalid manifest: $e');
    }
    if (manifest.id != pluginId) {
      throw FormatException(
        'Manifest id "${manifest.id}" does not match plugin id "$pluginId"',
      );
    }

    return _withPluginMutationLock(pluginId, () async {
      _ensureActive();
      _ensureNotDowngrade(manifest);
      final settingsSnapshot = await _capturePersistedSettings(pluginId);

      final previousManifest = _availablePluginsCache[pluginId];
      final pluginDir = Directory('${_pluginsDir.path}/$pluginId');
      final manifestFile = File('${pluginDir.path}/manifest.json');
      final sourceFile = File('${pluginDir.path}/plugin.js');
      final directoryExisted = pluginDir.existsSync();
      final previousManifestSource = manifestFile.existsSync()
          ? manifestFile.readAsStringSync()
          : null;
      final previousSource = sourceFile.existsSync()
          ? sourceFile.readAsStringSync()
          : null;
      final wasLoaded = isPluginLoaded(pluginId);

      pluginDir.createSync(recursive: true);
      final stagedManifest = File('${manifestFile.path}$_stagingSuffix');
      final stagedSource = File('${sourceFile.path}$_stagingSuffix');
      try {
        stagedManifest.writeAsStringSync(jsonEncode(manifestJson));
        stagedSource.writeAsStringSync(pluginJs);
      } catch (e) {
        _deleteQuietly(stagedManifest);
        _deleteQuietly(stagedSource);
        if (!directoryExisted && pluginDir.existsSync()) {
          pluginDir.deleteSync(recursive: true);
        }
        rethrow;
      }

      if (wasLoaded) {
        await _unloadPlugin(pluginId);
      }

      try {
        stagedManifest.renameSync(manifestFile.path);
        stagedSource.renameSync(sourceFile.path);
        _availablePluginsCache[pluginId] = manifest;

        if (wasLoaded) {
          await _queuedLoad(pluginId);
        }
      } catch (e) {
        _log.warning('Rolling back failed update of plugin $pluginId', e);
        _deleteQuietly(stagedManifest);
        _deleteQuietly(stagedSource);
        // Restore settings before the previous version reloads: the reload
        // re-reads reconciled settings under the settings lock.
        await _restorePersistedSettings(pluginId, settingsSnapshot);
        await _restorePluginSource(
          pluginId: pluginId,
          pluginDir: pluginDir,
          directoryExisted: directoryExisted,
          previousManifest: previousManifest,
          previousManifestSource: previousManifestSource,
          previousSource: previousSource,
          reload: wasLoaded,
        );
        rethrow;
      }

      _log.info('Plugin source updated: $pluginId (${manifest.version})');
      return manifest;
    });
  }

  Future<void> _restorePluginSource({
    required String pluginId,
    required Directory pluginDir,
    required bool directoryExisted,
    required PluginManifest? previousManifest,
    required String? previousManifestSource,
    required String? previousSource,
    required bool reload,
  }) async {
    if (!directoryExisted) {
      if (pluginDir.existsSync()) pluginDir.deleteSync(recursive: true);
      _availablePluginsCache.remove(pluginId);
      return;
    }

    _writeOrDelete(
      File('${pluginDir.path}/manifest.json'),
      previousManifestSource,
    );
    _writeOrDelete(File('${pluginDir.path}/plugin.js'), previousSource);

    if (previousManifest == null) {
      _availablePluginsCache.remove(pluginId);
    } else {
      _availablePluginsCache[pluginId] = previousManifest;
    }

    if (!reload || previousManifest == null || previousSource == null) return;
    try {
      await _queuedLoad(pluginId);
    } catch (e) {
      _log.warning('Failed to reload previous version of plugin $pluginId', e);
    }
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  static void _writeOrDelete(File file, String? contents) {
    if (contents == null) {
      if (file.existsSync()) file.deleteSync();
      return;
    }
    file.writeAsStringSync(contents);
  }

  void _ensureNotDowngrade(PluginManifest manifest) {
    final installed = _availablePluginsCache[manifest.id];
    if (installed == null) return;
    if (comparePluginVersions(manifest.version, installed.version) >= 0) return;
    throw PluginDowngradeException(
      'Plugin ${manifest.id} ${installed.version} is installed; '
      'remove it before installing ${manifest.version}',
    );
  }

  Future<void> removePlugin(String pluginId) async {
    if (!isSafePathComponent(pluginId)) {
      throw FormatException(
        'Unsafe plugin id "$pluginId": must be a single safe path component',
      );
    }

    await _withPluginMutationLock(pluginId, () async {
      _ensureActive();
      if (isPluginLoaded(pluginId)) {
        await _unloadPlugin(pluginId);
      }
      await _removePluginState(pluginId);
    });
  }

  Future<void> _removePluginState(String pluginId) async {
    await _withPluginSettingsLock(pluginId, () async {
      await _deleteSecureSettings(pluginId);
      await _prefs.remove('plugin.settings.$pluginId');
      await _prefs.remove('plugin.autoload.$pluginId');
      await _prefs.remove(_loadFailureKey(pluginId));
      if (_prefs.getString(_loadingPluginKey) == pluginId) {
        await _prefs.remove(_loadingPluginKey);
      }

      final pluginDir = Directory('${_pluginsDir.path}/$pluginId');
      if (pluginDir.existsSync()) {
        await pluginDir.delete(recursive: true);
        _log.info('Plugin removed: $pluginId');
      }
      _availablePluginsCache.remove(pluginId);
    });
  }

  Future<void> loadPlugin(String pluginId) {
    _ensureActive();
    return _withPluginMutationLock(pluginId, () => _queuedLoad(pluginId));
  }

  Future<void> _queuedLoad(String pluginId) {
    _ensureActive();
    final load = _pluginLoadQueue.then((_) => _loadPlugin(pluginId));
    _pluginLoadQueue = load.then<void>((_) {}, onError: (_, _) {});
    return load;
  }

  Future<void> _loadPlugin(String pluginId) async {
    _ensureActive();
    if (!_availablePluginsCache.containsKey(pluginId)) {
      throw Exception('Plugin not found: $pluginId');
    }

    final manifest = _availablePluginsCache[pluginId]!;
    final pluginDir = Directory('${_pluginsDir.path}/$pluginId');

    await _prefs.setString(_loadingPluginKey, pluginId);
    try {
      final pluginFile = File('${pluginDir.path}/plugin.js');
      if (!pluginFile.existsSync()) {
        throw Exception('plugin.js not found for plugin: $pluginId');
      }

      final jsCode = await pluginFile.readAsString();
      final settings = await _pluginSettingsForLoad(pluginId);

      await pluginManager
          .loadPlugin(
            id: pluginId,
            manifest: manifest,
            jsCode: jsCode,
            settings: settings,
          )
          .timeout(_loadTimeout);
    } catch (_) {
      await _prefs.remove(_loadingPluginKey);
      await _recordLoadFailure(pluginId);
      rethrow;
    }

    await _prefs.remove(_loadingPluginKey);
    await _prefs.remove(_loadFailureKey(pluginId));
    _log.info('Plugin loaded: $pluginId');
  }

  Future<void> unloadPlugin(String pluginId) {
    _ensureActive();
    return _withPluginMutationLock(pluginId, () => _unloadPlugin(pluginId));
  }

  Future<void> _unloadPlugin(String pluginId) async {
    _ensureActive();
    await pluginManager.unloadPlugin(pluginId);
    _log.info('Plugin unloaded: $pluginId');
  }

  Future<void> reloadPlugin(String pluginId) async {
    _ensureActive();
    return _withPluginMutationLock(pluginId, () async {
      if (!isPluginLoaded(pluginId)) {
        throw Exception('Plugin not loaded: $pluginId');
      }
      await _reloadPluginLocked(pluginId);
    });
  }

  Future<void> _reloadPluginIfLoaded(String pluginId) async {
    return _withPluginMutationLock(pluginId, () async {
      if (!isPluginLoaded(pluginId)) return;
      await _reloadPluginLocked(pluginId);
    });
  }

  Future<void> _reloadPluginLocked(String pluginId) async {
    _log.info('Reloading plugin: $pluginId');
    await _unloadPlugin(pluginId);
    await _queuedLoad(pluginId);
    _log.info('Plugin reloaded: $pluginId');
  }

  Future<void> setPluginAutoLoad(String pluginId, bool enabled) {
    _ensureActive();
    return _withPluginMutationLock(
      pluginId,
      () => _setPluginAutoLoad(pluginId, enabled),
    );
  }

  Future<void> _setPluginAutoLoad(String pluginId, bool enabled) async {
    _ensureActive();
    if (enabled) {
      await _prefs.remove(_loadFailureKey(pluginId));
      if (_prefs.getString(_loadingPluginKey) == pluginId) {
        await _prefs.remove(_loadingPluginKey);
      }
    }
    await _prefs.setBool('plugin.autoload.$pluginId', enabled);
  }

  Future<void> enablePlugin(String pluginId) {
    _ensureActive();
    return _withPluginMutationLock(pluginId, () async {
      _ensureActive();
      final previousAutoLoad = _prefs.getBool('plugin.autoload.$pluginId');
      await _setPluginAutoLoad(pluginId, true);
      if (isPluginLoaded(pluginId)) return;
      try {
        await _queuedLoad(pluginId);
      } catch (_) {
        if (_prefs.getBool('plugin.autoload.$pluginId') ?? false) {
          if (previousAutoLoad == null) {
            await _prefs.remove('plugin.autoload.$pluginId');
          } else {
            await _prefs.setBool('plugin.autoload.$pluginId', previousAutoLoad);
          }
        }
        rethrow;
      }
    });
  }

  Future<void> disablePlugin(String pluginId) {
    _ensureActive();
    return _withPluginMutationLock(pluginId, () async {
      _ensureActive();
      if (isPluginLoaded(pluginId)) {
        await _unloadPlugin(pluginId);
      }
      await _setPluginAutoLoad(pluginId, false);
    });
  }

  Future<bool> shouldAutoLoad(String pluginId) async {
    return _prefs.getBool('plugin.autoload.$pluginId') ?? false;
  }

  Future<Map<String, dynamic>> pluginSettings(String pluginId) =>
      _withPluginSettingsLock(pluginId, () async {
        final manifest = _availablePluginsCache[pluginId];
        if (manifest == null) return {};

        final stored = await _storedSettings(manifest);
        return {
          ...stored.ordinary,
          for (final key in _secureSettingKeys(manifest))
            key: {'isSet': stored.secure.containsKey(key)},
        };
      });

  Future<void> savePluginSettings(
    String pluginId,
    Map<String, dynamic> settings,
  ) async {
    await _withPluginSettingsLock(pluginId, () async {
      _ensureActive();
      final manifest = _availablePluginsCache[pluginId];
      if (manifest == null) {
        throw Exception('Plugin not found: $pluginId');
      }

      _validateSettings(manifest, settings);
      final stored = await _storedSettings(manifest);
      final secureKeys = _secureSettingKeys(manifest);
      final ordinaryPatch = Map.fromEntries(
        settings.entries.where((entry) => !secureKeys.contains(entry.key)),
      );
      var secure = stored.secure;
      for (final entry in settings.entries.where(
        (entry) => secureKeys.contains(entry.key),
      )) {
        if (_isSecureState(entry.value)) continue;
        secure = entry.value == null
            ? Map.fromEntries(
                secure.entries.where((current) => current.key != entry.key),
              )
            : {...secure, entry.key: entry.value};
      }

      final mergedOrdinary = {...stored.ordinary, ...ordinaryPatch};
      for (final entry in ordinaryPatch.entries) {
        if (entry.value == null) mergedOrdinary.remove(entry.key);
      }

      await _writeSecureSettings(pluginId, secure);
      await _writeOrdinarySettings(pluginId, mergedOrdinary);

      _log.fine('Settings saved for plugin: $pluginId');
    });

    // Reload only after the settings lock above is released: the load path
    // re-reads settings under that same lock. The reload-if-loaded decision
    // and the reload itself are one serialized mutation operation, so a
    // concurrent unload cannot fail the save after the settings were
    // persisted.
    await _reloadPluginIfLoaded(pluginId);
  }

  List<PluginManifest> get availablePlugins {
    return _availablePluginsCache.values.toList();
  }

  PluginManifest? getPluginManifest(String pluginId) {
    return _availablePluginsCache[pluginId];
  }

  bool isPluginLoaded(String pluginId) {
    return pluginManager.loadedPlugins.any(
      (plugin) => plugin.pluginId == pluginId,
    );
  }

  String getPluginDirectory(String pluginId) {
    if (!isSafePathComponent(pluginId)) {
      throw FormatException(
        'Unsafe plugin id "$pluginId": must be a single safe path component',
      );
    }
    if (!_availablePluginsCache.containsKey(pluginId)) {
      throw Exception('Plugin not found: $pluginId');
    }
    return '${_pluginsDir.path}/$pluginId';
  }

  Future<bool> isPluginBundled(String pluginId) async {
    final bundledPlugins = await _getBundledPluginPaths();
    for (final pluginPath in bundledPlugins) {
      final pluginName = pluginPath.split('/').last;
      if (pluginName == pluginId) {
        return true;
      }
    }
    return false;
  }

  List<PluginRuntime> get loadedPlugins {
    return pluginManager.loadedPlugins;
  }

  String _loadFailureKey(String pluginId) =>
      'plugin.watchdog.loadFailures.$pluginId';

  String _settingsKey(String pluginId) => 'plugin.settings.$pluginId';

  String _secureSettingsKey(String pluginId) =>
      'plugin.settings.secure.$pluginId';

  Future<T> _withPluginSettingsLock<T>(
    String pluginId,
    Future<T> Function() action,
  ) => _withLock(_pluginSettingsLocks, pluginId, action);

  Future<T> _withPluginMutationLock<T>(
    String pluginId,
    Future<T> Function() action,
  ) => _withLock(_pluginMutationLocks, pluginId, action);

  Future<T> _withLock<T>(
    Map<String, Future<void>> locks,
    String pluginId,
    Future<T> Function() action,
  ) {
    final previous = locks[pluginId] ?? Future<void>.value();
    final next = Completer<void>();
    locks[pluginId] = next.future;
    return previous.then((_) => action()).whenComplete(() {
      next.complete();
      if (identical(locks[pluginId], next.future)) {
        locks.remove(pluginId);
      }
    });
  }

  Set<String> _secureSettingKeys(PluginManifest manifest) => {
    for (final entry in manifest.settings.entries)
      if (entry.value is Map && entry.value['secure'] == true) entry.key,
  };

  bool _isSecureState(dynamic value) =>
      value is Map && value.length == 1 && value['isSet'] is bool;

  Future<Map<String, dynamic>> _pluginSettingsForLoad(String pluginId) =>
      _withPluginSettingsLock(pluginId, () async {
        final manifest = _availablePluginsCache[pluginId];
        if (manifest == null) {
          throw Exception('Plugin not found: $pluginId');
        }
        final stored = await _storedSettings(manifest);
        return {...stored.ordinary, ...stored.secure};
      });

  Future<({Map<String, dynamic> ordinary, Map<String, dynamic> secure})>
  _storedSettings(PluginManifest manifest) async {
    final secureKeys = _secureSettingKeys(manifest);
    final storedSecure = await _readSecureSettings(manifest.id);
    final secureBase = Map.fromEntries(
      storedSecure.entries.where((entry) => secureKeys.contains(entry.key)),
    );

    final storedOrdinary = _readOrdinarySettings(manifest.id);
    final ordinary = _reconcileOrdinarySettings(manifest, storedOrdinary);

    final legacySecure = Map.fromEntries(
      ordinary.entries.where((entry) => secureKeys.contains(entry.key)),
    );
    final secure = _reconcileSecureSettings(manifest, {
      ...legacySecure,
      ...secureBase,
    });

    if (legacySecure.isEmpty) {
      if (!mapEquals(storedSecure, secure)) {
        await _writeSecureSettings(manifest.id, secure);
      }
      if (!mapEquals(storedOrdinary, ordinary)) {
        await _writeOrdinarySettings(manifest.id, ordinary);
      }
      return (ordinary: ordinary, secure: secure);
    }

    final migratedOrdinary = Map.fromEntries(
      ordinary.entries.where((entry) => !secureKeys.contains(entry.key)),
    );
    await _writeSecureSettings(manifest.id, secure);
    await _writeOrdinarySettings(manifest.id, migratedOrdinary);
    return (ordinary: migratedOrdinary, secure: secure);
  }

  Map<String, dynamic> _reconcileOrdinarySettings(
    PluginManifest manifest,
    Map<String, dynamic> ordinary,
  ) {
    final manifestSettings = manifest.settings;
    final secureKeys = _secureSettingKeys(manifest);
    final reconciled = <String, dynamic>{};
    for (final entry in ordinary.entries) {
      if (secureKeys.contains(entry.key)) {
        reconciled[entry.key] = entry.value;
        continue;
      }
      final schema = manifestSettings[entry.key];
      if (schema == null) continue;
      final value = _reconciledPersistedValue(entry.key, schema, entry.value);
      if (value != null) reconciled[entry.key] = value;
    }
    return reconciled;
  }

  Map<String, dynamic> _reconcileSecureSettings(
    PluginManifest manifest,
    Map<String, dynamic> secure,
  ) {
    final manifestSettings = manifest.settings;
    final reconciled = <String, dynamic>{};
    for (final entry in secure.entries) {
      final schema = manifestSettings[entry.key];
      if (schema == null) continue;
      final value = _reconciledPersistedValue(entry.key, schema, entry.value);
      if (value != null) reconciled[entry.key] = value;
    }
    return reconciled;
  }

  dynamic _reconciledPersistedValue(String key, dynamic schema, dynamic value) {
    if (value == null) return null;
    if (schema is! Map) return value;
    if (schema['type'] == 'enum') {
      final enumValues = parsePluginEnumValues(key, schema);
      if (enumValues.contains(value)) return value;
      final defaultValue = schema['default'];
      return enumValues.contains(defaultValue) ? defaultValue : null;
    }
    final compatible = switch (schema['type']) {
      'string' => value is String,
      'number' => value is num,
      'boolean' => value is bool,
      _ => true,
    };
    if (compatible) return value;
    final defaultValue = schema['default'];
    final defaultCompatible = switch (schema['type']) {
      'string' => defaultValue is String,
      'number' => defaultValue is num,
      'boolean' => defaultValue is bool,
      _ => false,
    };
    return defaultCompatible ? defaultValue : null;
  }

  Map<String, dynamic> _readOrdinarySettings(String pluginId) {
    final settingsJson = _prefs.getString(_settingsKey(pluginId));
    if (settingsJson == null) return {};

    try {
      return Map<String, dynamic>.from(jsonDecode(settingsJson));
    } catch (e) {
      _log.warning('Failed to parse settings for plugin $pluginId', e);
      return {};
    }
  }

  Future<Map<String, dynamic>> _readSecureSettings(String pluginId) async {
    if (_credentialStore == null) {
      return Map.from(_volatileSecureSettings[pluginId] ?? {});
    }
    final settingsJson = await _credentialStore.read(
      key: _secureSettingsKey(pluginId),
    );
    if (settingsJson == null) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(settingsJson));
    } catch (_) {
      throw StateError('Secure settings for plugin $pluginId are invalid');
    }
  }

  Future<void> _writeOrdinarySettings(
    String pluginId,
    Map<String, dynamic> settings,
  ) async {
    if (settings.isEmpty) {
      await _prefs.remove(_settingsKey(pluginId));
      if (_prefs.containsKey(_settingsKey(pluginId))) {
        throw StateError('Failed to remove settings for plugin $pluginId');
      }
      return;
    }
    final saved = await _prefs.setString(
      _settingsKey(pluginId),
      jsonEncode(settings),
    );
    if (!saved) {
      throw StateError('Failed to save settings for plugin $pluginId');
    }
  }

  Future<void> _writeSecureSettings(
    String pluginId,
    Map<String, dynamic> settings,
  ) async {
    if (_credentialStore == null) {
      if (settings.isEmpty) {
        _volatileSecureSettings = Map.fromEntries(
          _volatileSecureSettings.entries.where(
            (entry) => entry.key != pluginId,
          ),
        );
      } else {
        _volatileSecureSettings = {
          ..._volatileSecureSettings,
          pluginId: Map.from(settings),
        };
      }
      return;
    }
    if (settings.isEmpty) {
      await _credentialStore.delete(key: _secureSettingsKey(pluginId));
      return;
    }
    await _credentialStore.write(
      key: _secureSettingsKey(pluginId),
      value: jsonEncode(settings),
    );
  }

  Future<({Map<String, dynamic> ordinary, Map<String, dynamic> secure})>
  _capturePersistedSettings(String pluginId) =>
      _withPluginSettingsLock(pluginId, () async {
        return (
          ordinary: _readOrdinarySettings(pluginId),
          secure: await _readSecureSettings(pluginId),
        );
      });

  Future<void> _restorePersistedSettings(
    String pluginId,
    ({Map<String, dynamic> ordinary, Map<String, dynamic> secure}) settings,
  ) => _withPluginSettingsLock(pluginId, () async {
    await _writeOrdinarySettings(pluginId, settings.ordinary);
    await _writeSecureSettings(pluginId, settings.secure);
  });

  Future<void> _deleteSecureSettings(String pluginId) async {
    _volatileSecureSettings = Map.fromEntries(
      _volatileSecureSettings.entries.where((entry) => entry.key != pluginId),
    );
    await _credentialStore?.delete(key: _secureSettingsKey(pluginId));
  }

  Future<void> _recordLoadFailure(String pluginId) async {
    final failureKey = _loadFailureKey(pluginId);
    final failures = (_prefs.getInt(failureKey) ?? 0) + 1;
    await _prefs.setInt(failureKey, failures);
    if (failures < _maxConsecutiveLoadFailures) return;

    await _prefs.setBool('plugin.autoload.$pluginId', false);
    _log.warning(
      'Disabled auto-load for plugin $pluginId after $failures consecutive load failures',
    );
  }

  Future<void> _recoverInterruptedPluginLoad() async {
    final pluginId = _prefs.getString(_loadingPluginKey);
    if (pluginId == null) return;

    await _prefs.setInt(_loadFailureKey(pluginId), _maxConsecutiveLoadFailures);
    await _prefs.setBool('plugin.autoload.$pluginId', false);
    await _prefs.remove(_loadingPluginKey);
    _log.warning(
      'Disabled auto-load for plugin $pluginId after an interrupted load',
    );
  }

  Future<void> _copyBundledPlugins() async {
    final bundledPlugins = await _getBundledPluginPaths();

    for (final pluginPath in bundledPlugins) {
      try {
        final pluginName = pluginPath.split('/').last;
        final destDir = Directory('${_pluginsDir.path}/$pluginName');

        final isNewPlugin = !destDir.existsSync() || destDir.listSync().isEmpty;

        if (isNewPlugin) {
          destDir.createSync(recursive: true);

          final manifestAsset = await rootBundle.loadString(
            '$pluginPath/manifest.json',
          );
          File(
            '${destDir.path}/manifest.json',
          ).writeAsStringSync(manifestAsset);

          final pluginAsset = await rootBundle.loadString(
            '$pluginPath/plugin.js',
          );
          File('${destDir.path}/plugin.js').writeAsStringSync(pluginAsset);

          _log.fine('Copied bundled plugin: $pluginName');
          continue;
        }

        final manifestAsset = await rootBundle.loadString(
          '$pluginPath/manifest.json',
        );
        if (kReleaseMode) {
          final newManifest = PluginManifest.fromJson(
            jsonDecode(manifestAsset),
          );
          final existingManifestFile = File('${destDir.path}/manifest.json');
          final existingManifest = PluginManifest.fromJson(
            jsonDecode(await existingManifestFile.readAsString()),
          );
          if (comparePluginVersions(
                newManifest.version,
                existingManifest.version,
              ) <=
              0) {
            _log.fine(
              "not overriding bundled plugin: [bundled: ${newManifest.version}], [existing: ${existingManifest.version}]",
            );
            continue;
          }
        }
        File('${destDir.path}/manifest.json').writeAsStringSync(manifestAsset);

        final pluginAsset = await rootBundle.loadString(
          '$pluginPath/plugin.js',
        );
        File('${destDir.path}/plugin.js').writeAsStringSync(pluginAsset);

        _log.fine('Updated bundled plugin: $pluginName');
      } catch (e) {
        _log.warning('Failed to copy bundled plugins', e);
      }
    }
  }

  Future<List<String>> _getBundledPluginPaths() async {
    return [
      'assets/plugins/time-to-ready.reaplugin',
      'assets/plugins/visualizer.reaplugin',
      'assets/plugins/settings.reaplugin',
      'assets/plugins/dye2.reaplugin',
      'assets/plugins/decent-profile.reaplugin',
      'assets/plugins/shot-upload.reaplugin',
      'assets/plugins/dcamp.reaplugin',
    ];
  }

  Future<void> _scanAvailablePlugins() async {
    _availablePluginsCache.clear();

    if (!_pluginsDir.existsSync()) {
      return;
    }

    final directories = _pluginsDir.listSync().whereType<Directory>();

    for (final dir in directories) {
      try {
        final manifestFile = File('${dir.path}/manifest.json');
        if (!manifestFile.existsSync()) {
          continue;
        }

        final manifestJson = jsonDecode(await manifestFile.readAsString());
        final manifest = PluginManifest.fromJson(manifestJson);

        if (!isSafePathComponent(manifest.id)) {
          _log.warning(
            'Skipping plugin with unsafe id "${manifest.id}" at ${dir.path}',
          );
          continue;
        }

        _availablePluginsCache[manifest.id] = manifest;
        _log.fine('Found plugin: ${manifest.id}');
      } catch (e) {
        _log.warning('Failed to load plugin manifest from ${dir.path}', e);
      }
    }
  }

  Future<void> _loadAutoLoadPlugins() async {
    await _ensureBundledPluginsAutoLoadEnabled();

    for (final pluginId in _availablePluginsCache.keys) {
      final shouldLoad = await shouldAutoLoad(pluginId);
      if (shouldLoad) {
        try {
          await loadPlugin(pluginId);
        } catch (e) {
          _log.warning('Failed to auto-load plugin $pluginId', e);
        }
      }
    }
  }

  Future<void> _ensureBundledPluginsAutoLoadEnabled() async {
    try {
      final bundledPlugins = await _getBundledPluginPaths();

      for (final pluginPath in bundledPlugins) {
        final pluginName = pluginPath.split('/').last;
        final pluginDir = Directory('${_pluginsDir.path}/$pluginName');

        if (!pluginDir.existsSync()) {
          continue;
        }

        final manifestFile = File('${pluginDir.path}/manifest.json');
        if (!manifestFile.existsSync()) {
          continue;
        }

        final manifestJson = jsonDecode(await manifestFile.readAsString());
        final manifest = PluginManifest.fromJson(manifestJson);

        final autoLoadKey = 'plugin.autoload.${manifest.id}';
        if (!_prefs.containsKey(autoLoadKey)) {
          await _prefs.setBool(autoLoadKey, true);
          _log.info(
            'Set auto-load enabled by default for bundled plugin: ${manifest.id}',
          );
        }
      }
    } catch (e) {
      _log.warning('Failed to ensure bundled plugins auto-load enabled', e);
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await for (final entity in source.list(recursive: false)) {
      if (entity is File) {
        final newFile = File('${destination.path}/${p.basename(entity.path)}');
        await entity.copy(newFile.path);
      } else if (entity is Directory) {
        final newDir = Directory(
          '${destination.path}/${p.basename(entity.path)}',
        );
        newDir.createSync(recursive: true);
        await _copyDirectory(entity, newDir);
      }
    }
  }

  void _validateSettings(
    PluginManifest manifest,
    Map<String, dynamic> settings,
  ) {
    final manifestSettings = manifest.settings;

    if (manifestSettings.isEmpty) {
      return;
    }

    for (final entry in settings.entries) {
      if (!manifestSettings.containsKey(entry.key)) {
        throw PluginSettingsValidationException(
          'Setting "${entry.key}" not defined in plugin manifest',
        );
      }
      if (entry.value == null || _isSecureState(entry.value)) continue;
      final schema = manifestSettings[entry.key];
      final enumValues = parsePluginEnumValues(entry.key, schema);
      if (schema is Map &&
          schema['type'] == 'enum' &&
          !enumValues.contains(entry.value)) {
        throw PluginSettingsValidationException(
          'Setting "${entry.key}" must be one of: ${enumValues.join(', ')}',
        );
      }
    }
  }

  Future<void> reset() async {
    _ensureActive();
    for (var plugin in availablePlugins) {
      final path = getPluginDirectory(plugin.id);
      final dir = Directory(path);
      await dir.delete(recursive: true);
    }
  }

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;

    _lifecycle = PluginLoaderLifecycle.disposing;
    final disposal = _dispose();
    _disposeFuture = disposal;
    return disposal;
  }

  Future<void> _dispose() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> waitFor(String name, Future<void>? work) async {
      if (work == null) return;
      try {
        await work;
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
        _log.warning(
          'Plugin loader disposal failed during $name',
          error,
          stackTrace,
        );
      }
    }

    try {
      await waitFor('initialization', _initialization);
      await waitFor('plugin load queue', _pluginLoadQueue);
      await waitFor('manager disposal', pluginManager.dispose());
    } finally {
      _availablePluginsCache.clear();
      _initialized = false;
      _lifecycle = PluginLoaderLifecycle.disposed;
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }
}
